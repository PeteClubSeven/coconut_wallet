import 'package:coconut_design_system/coconut_design_system.dart'
    hide CoconutAppBar, CoconutPopup, CoconutToast, CoconutOptionPicker, CoconutUnderlinedButton;
import 'package:coconut_lib/coconut_lib.dart';
import 'package:coconut_wallet/analytics/analytics_screen_names.dart';
import 'package:coconut_wallet/app/router/app_route_names.dart';
import 'package:coconut_wallet/app/router/route_args.dart';
import 'package:coconut_wallet/design_system/context/coconut_theme_context_extension.dart';
import 'package:coconut_wallet/enums/fiat_enums.dart';
import 'package:coconut_wallet/localization/strings.g.dart';
import 'package:coconut_wallet/model/ark/ark_board.dart';
import 'package:coconut_wallet/model/ark/ark_payment.dart';
import 'package:coconut_wallet/model/utxo/utxo_state.dart';
import 'package:coconut_wallet/providers/ark_provider.dart';
import 'package:coconut_wallet/providers/preferences/preference_provider.dart';
import 'package:coconut_wallet/providers/send_info_provider.dart';
import 'package:coconut_wallet/providers/view_model/send/send_options_view_model.dart';
import 'package:coconut_wallet/providers/wallet_provider.dart';
import 'package:coconut_wallet/screens/ark/ark_unlock_flow.dart';
import 'package:coconut_wallet/screens/common/flutter_hot_wallet_authenticator.dart';
import 'package:coconut_wallet/screens/send/utxo_selection_screen.dart';
import 'package:coconut_wallet/services/ark/ark_wallet_service.dart';
import 'package:coconut_wallet/ui/coconut/coconut_app_bar.dart';
import 'package:coconut_wallet/ui/coconut/coconut_option_picker.dart';
import 'package:coconut_wallet/ui/coconut/coconut_overlays.dart';
import 'package:coconut_wallet/ui/coconut/coconut_underlined_button.dart';
import 'package:coconut_wallet/utils/fee_rate_mixin.dart';
import 'package:coconut_wallet/utils/logger.dart';
import 'package:coconut_wallet/utils/payment_request_parser.dart';
import 'package:coconut_wallet/widgets/common/buttons/fixed_bottom_button.dart';
import 'package:coconut_wallet/widgets/common/overlays/common_bottom_sheets.dart';
import 'package:coconut_wallet/widgets/features/ark/ark_texts.dart';
import 'package:coconut_wallet/widgets/features/ark/ark_ui.dart';
import 'package:coconut_wallet/widgets/features/send/send_amount_header.dart';
import 'package:coconut_wallet/widgets/features/send/send_output_detail_row.dart';
import 'package:coconut_wallet/widgets/features/utxo/bottom_sheet/estimated_fee_bottom_sheet.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// Step 2 of Send for a hot wallet with Ark: how to pay the recipients chosen on step 1. One
/// recipient can be paid every way its request allows, each card with its fee: from Ark (Ark,
/// Lightning, on-chain via Ark) or on-chain from the wallet's UTXOs. Several recipients, or Send
/// All, go on-chain in one transaction. The on-chain card picks UTXOs and the fee rate before the
/// confirm screen.
class SendOptionsScreen extends StatefulWidget {
  const SendOptionsScreen({
    super.key,
    required this.id,
    required this.recipients,
    required this.sendEntryPoint,
    this.maxLast = false,
  });

  final int id;
  final List<SendRecipientArg> recipients;

  /// The last recipient gets everything left on-chain.
  final bool maxLast;
  final SendEntryPoint sendEntryPoint;

  @override
  State<SendOptionsScreen> createState() => _SendOptionsScreenState();
}

class _SendOptionsScreenState extends State<SendOptionsScreen> {
  late final SendOptionsViewModel _vm;
  late final ArkProvider _arkProvider;
  late BitcoinUnit _unit;
  bool _isPaying = false;
  bool _isFeeSheetOpen = false;

  @override
  void initState() {
    super.initState();
    final walletProvider = context.read<WalletProvider>();
    _arkProvider = context.read<ArkProvider>();
    _unit = context.read<PreferenceProvider>().currentUnit;
    _vm = SendOptionsViewModel(
      recipients: [
        for (final recipient in widget.recipients)
          SendRecipientInput(
            PaymentRequest.parse(recipient.input, NetworkType.currentNetworkType),
            recipient.amountSats,
          ),
      ],
      maxLast: widget.maxLast,
      wallet: walletProvider.getWalletById(widget.id),
      utxos: walletProvider.getUtxoList(widget.id),
      changeDerivationPath: walletProvider.getChangeAddress(widget.id).derivationPath,
      ark: ArkProviderSendAccess(_arkProvider, widget.id),
      sendInfoProvider: context.read<SendInfoProvider>(),
    );
    _arkProvider.addListener(_vm.onArkChanged);
    _vm.refreshRecommendedFees();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // Ark and Lightning requests need the Ark wallet; for a plain address, only ask when the
      // session would anyway (the on-chain option works without it).
      if (_vm.showsArkBalance && !_arkProvider.isOpen(widget.id)) {
        await openArkWalletForSession(context, widget.id, userInitiated: _vm.request.hasArkOrLightning);
        _vm.onArkChanged();
      }
    });
  }

  @override
  void dispose() {
    _arkProvider.removeListener(_vm.onArkChanged);
    _vm.dispose();
    super.dispose();
  }

  void _toggleUnit() => setState(() => _unit = _unit.isBasedOnSatoshi ? BitcoinUnit.btc : BitcoinUnit.sats);

  // --- On-chain choices ---

  Future<void> _pickUtxos() async {
    final result = await CommonBottomSheets.showDraggableBottomSheet<List<UtxoState>>(
      context: context,
      screenName: AnalyticsScreenNames.sendSelectUtxoSheet,
      minChildSize: 0.6,
      maxChildSize: 0.9,
      initialChildSize: 0.9,
      childBuilder:
          (scrollController) => UtxoSelectionScreen(
            selectedUtxoList: _vm.isUtxoAuto ? List<UtxoState>.empty() : _vm.selectedUtxos,
            walletId: widget.id,
            currentUnit: _unit,
            scrollController: scrollController,
            backgroundColor: context.coconutColors.surfaceBottomSheet,
            showSkipButton: false,
          ),
    );
    if (result != null && mounted) _vm.setSelectedUtxos(List<UtxoState>.from(result));
  }

  void _editFeeRate() {
    setState(() => _isFeeSheetOpen = true);
    EstimatedFeeBottomSheet.show(
      context: context,
      listenable: _vm,
      estimatedFeeTextGetter: () {
        final fee = _vm.onchainFeeSats;
        return fee == null ? '-' : _unit.displayBitcoinAmount(fee, withUnit: true);
      },
      feeRateController: _vm.feeRateController,
      feeRateFocusNode: _vm.feeRateFocusNode,
      onFeeRateChanged: _vm.onFeeRateChanged,
      onEditingComplete: () {
        FocusScope.of(context).unfocus();
        Navigator.pop(context);
      },
      recommendedFeeFetchStatusGetter: () => _vm.recommendedFeeFetchStatus,
      feeInfosGetter: () => _vm.feeInfos,
      refreshRecommendedFees: () => _vm.refreshRecommendedFees(),
      onFeeRateSelected: (satsPerVb) {
        _vm.setFeeRateFromRecommendation(satsPerVb);
        FocusScope.of(context).unfocus();
        Navigator.pop(context);
      },
      onClosed: () {
        _vm.tidyFeeRate();
        if (mounted) setState(() => _isFeeSheetOpen = false);
      },
    );
  }

  Future<void> _unlock() async {
    await openArkWalletForSession(context, widget.id, userInitiated: true);
    _vm.onArkChanged();
  }

  // --- Going ahead ---

  void _nextOnchain() {
    _vm.saveOnchainForConfirm(widget.sendEntryPoint);
    Navigator.pushNamed(context, AppRouteNames.sendConfirm, arguments: SendConfirmRouteArgs(currentUnit: _unit));
  }

  bool _isSendStart(Route<dynamic> route) =>
      widget.sendEntryPoint == SendEntryPoint.walletDetail
          ? route.settings.name == AppRouteNames.walletDetail || route.isFirst
          : route.isFirst;

  Future<void> _payFromArk() async {
    final option = _vm.selected!;
    final amount = _vm.amountSats!;
    final fee = _vm.statusOf(option).feeSats ?? 0;
    final confirmed = await confirmArkAction(
      context,
      title: t.ark.send.pay_title(amount: formatSats(_unit, amount)),
      description: t.ark.send.pay_description(
        method: sendOptionTitle(option.kind),
        destination: shortenMiddle(option.destination),
        fee: formatSats(_unit, fee),
      ),
    );
    if (!confirmed || !mounted) return;
    if (!await FlutterHotWalletAuthenticator(context).authenticate() || !mounted) return;
    setState(() => _isPaying = true);
    try {
      final movementId = await _arkProvider.pay(
        widget.id,
        option.rail!,
        destination: option.destination,
        amountSats: amount,
        invoiceHasAmount: option.rail == ArkPaymentRail.lightningInvoice && _vm.request.invoiceAmountSats != null,
      );
      if (!mounted) return;
      _showResult(movementId, fallbackToast: t.ark.send.paid);
    } on ArkMovePendingException {
      if (!mounted) return;
      _showResult(null, fallbackToast: t.ark.send.accepted_later);
    } on ArkPaymentException catch (error) {
      Logger.error('SendOptionsScreen: payment failed: $error');
      if (!mounted) return;
      setState(() => _isPaying = false);
      await showArkError(context, t.ark.send.payment_failed, '$error');
      if (mounted && error.movementId != null) _showResult(error.movementId, fallbackToast: null);
    } catch (error) {
      if (!mounted) return;
      setState(() => _isPaying = false);
      await showArkError(context, t.ark.send.payment_failed, '$error');
    }
  }

  /// Shows the payment's movement (it may still be pending) in place of the Send steps.
  void _showResult(int? movementId, {required String? fallbackToast}) {
    if (movementId == null) {
      if (fallbackToast != null) CoconutToast.showBottomToast(context: context, text: fallbackToast);
      Navigator.popUntil(context, _isSendStart);
      return;
    }
    Navigator.pushNamedAndRemoveUntil(
      context,
      AppRouteNames.arkMovementDetail,
      _isSendStart,
      arguments: ArkMovementDetailRouteArgs(id: widget.id, movementId: movementId),
    );
  }

  // --- Layout ---

  @override
  Widget build(BuildContext context) {
    final colors = context.coconutColors;
    return ListenableBuilder(
      listenable: _vm,
      builder: (context, _) {
        final selected = _vm.selected;
        final isOnchain = selected?.kind == SendOptionKind.onchain;
        final selectedStatus = selected == null ? null : _vm.statusOf(selected);
        final canGo = _vm.canProceed && !_isPaying;
        final total = _vm.totalSats;
        final String? onchainOnlyNote;
        if (_vm.isBatch) {
          onchainOnlyNote = t.ark.send.several_onchain;
        } else if (_vm.isMaxMode) {
          onchainOnlyNote = t.ark.send.max_onchain;
        } else {
          onchainOnlyNote = null;
        }
        return Scaffold(
          backgroundColor: colors.background,
          appBar: CoconutAppBar.build(context: context, title: t.ark.send.pay_with, backgroundColor: colors.background),
          body: SafeArea(
            child: Stack(
              children: [
                ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 160),
                  children: [
                    SendAmountHeader(
                      amountText: total == null ? '-' : _unit.displayBitcoinAmount(total),
                      unit: _unit,
                      satoshiAmount: total ?? 0,
                      totalCostAmountText:
                          total == null || selectedStatus?.feeSats == null
                              ? '-'
                              : _unit.displayBitcoinAmount(total + selectedStatus!.feeSats!),
                      onTap: _toggleUnit,
                      topMargin: 24,
                    ),
                    CoconutLayout.spacing_500h,
                    _buildRecipients(),
                    CoconutLayout.spacing_500h,
                    ArkSectionTitle(t.ark.send.pay_with),
                    if (onchainOnlyNote != null) ...[
                      Text(onchainOnlyNote, style: CoconutTypography.body3_12.setColor(colors.secondaryText)),
                      CoconutLayout.spacing_200h,
                    ],
                    for (final option in _vm.options) ...[_buildOption(option), CoconutLayout.spacing_200h],
                  ],
                ),
                FixedBottomButton(
                  onButtonClicked: isOnchain ? _nextOnchain : _payFromArk,
                  text: _isPaying ? t.ark.send.paying : (isOnchain ? t.next : t.ark.send.pay),
                  isActive: canGo,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Who gets what, as the confirm screen's output details; "Edit" goes back to step 1.
  Widget _buildRecipients() {
    final colors = context.coconutColors;
    final recipients = _vm.recipients;
    return ArkCard(
      child: Column(
        children: [
          Row(
            children: [
              Text(t.ark.send.recipients, style: CoconutTypography.body3_12_Bold.setColor(colors.primaryText)),
              if (recipients.length == 1) ...[
                CoconutLayout.spacing_200w,
                ArkChip(describePaymentRequest(recipients.single.request, _unit)),
              ],
              const Spacer(),
              CoconutUnderlinedButton(
                text: t.edit,
                textStyle: CoconutTypography.body3_12,
                padding: EdgeInsets.zero,
                onTap: () => Navigator.pop(context),
              ),
            ],
          ),
          CoconutLayout.spacing_300h,
          for (var i = 0; i < recipients.length; i++) ...[
            if (i > 0) ...[
              CoconutLayout.spacing_400h,
              Divider(color: colors.divider, height: 1),
              CoconutLayout.spacing_400h,
            ],
            SendOutputDetailRow(
              label: t.ark.send.recipient_n(n: i + 1),
              address: shortenMiddle(requestDestination(recipients[i].request), head: 16, tail: 12),
              amountSats: _vm.amountOf(i) ?? 0,
              isChange: false,
              currentUnit: _unit,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildOption(SendOption option) {
    final colors = context.coconutColors;
    final status = _vm.statusOf(option);
    final isSelected = _vm.selected == option;
    final problem = sendOptionProblemText(status);
    final available = option.kind == SendOptionKind.onchain ? _vm.onchainAvailableSats : _vm.arkSpendableSats;
    final String feeText;
    if (status.isEstimating) {
      feeText = t.ark.send.estimating;
    } else if (status.feeSats != null) {
      final fee = formatSats(_unit, status.feeSats!);
      feeText = option.kind == SendOptionKind.onchain ? t.ark.send.approx_fee(fee: fee) : t.ark.send.fee(fee: fee);
    } else {
      feeText = '';
    }
    return ArkSelectableCard(
      isSelected: isSelected,
      isEnabled: problem == null || isSelected || status.canUnlock,
      onPressed: () => _vm.select(option),
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (problem != null) ...[
            CoconutLayout.spacing_200h,
            Text(
              problem,
              style: CoconutTypography.body3_12.setColor(isSelected ? colors.danger : colors.secondaryText),
            ),
            if (status.canUnlock) ...[
              CoconutLayout.spacing_200h,
              Align(
                alignment: Alignment.centerLeft,
                child: CoconutUnderlinedButton(
                  text: t.ark.send.unlock,
                  textStyle: CoconutTypography.body3_12_Bold,
                  padding: EdgeInsets.zero,
                  onTap: _unlock,
                ),
              ),
            ],
          ],
          if (isSelected && option.kind == SendOptionKind.onchain) _buildOnchainPickers(),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(sendOptionTitle(option.kind), style: CoconutTypography.body2_14_Bold.setColor(colors.primaryText)),
                CoconutLayout.spacing_50h,
                Text(
                  t.ark.send.source_balance(
                    source: sendOptionSource(option.kind),
                    amount: formatSats(_unit, available),
                  ),
                  style: CoconutTypography.body3_12.setColor(colors.secondaryText),
                ),
              ],
            ),
          ),
          Text(feeText, style: CoconutTypography.body3_12_Number.setColor(colors.primaryText)),
        ],
      ),
    );
  }

  /// UTXOs and fee, as the UTXO merge screen's pickers.
  Widget _buildOnchainPickers() {
    final colors = context.coconutColors;
    final fee = _vm.onchainFeeSats;
    final feeRate = _vm.feeRate;
    final dust = _vm.unintendedDustFee;
    final String feeText;
    if (fee != null && feeRate != null) {
      final rate = feeRate % 1 == 0 ? feeRate.toStringAsFixed(0) : '$feeRate';
      feeText = '${formatSats(_unit, fee)} ($rate ${t.send_screen.fee_rate_suffix})';
    } else {
      feeText =
          _vm.recommendedFeeFetchStatus == RecommendedFeeFetchStatus.fetching
              ? t.ark.send.estimating
              : t.merge_utxos_screen.fee_rate_input_placeholder;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CoconutLayout.spacing_300h,
        CoconutOptionPicker(
          label: t.ark.send.utxos,
          text:
              _vm.isUtxoAuto
                  ? t.send_screen.utxo_auto_selection
                  : t.ark.send.utxos_selected(
                    count: _vm.selectedUtxos.length,
                    amount: formatSats(_unit, _vm.onchainAvailableSats),
                  ),
          dividerColor: colors.inputPlaceholder,
          onTap: _pickUtxos,
        ),
        CoconutLayout.spacing_300h,
        CoconutOptionPicker(
          isExpanded: _isFeeSheetOpen,
          label: t.estimated_fee,
          text: feeText,
          textColor: fee == null ? colors.mutedText : colors.primaryText,
          dividerColor: colors.inputPlaceholder,
          onTap: _editFeeRate,
          guideText: dust != null && dust > 0 ? t.ark.send.dust_included(amount: formatSats(_unit, dust)) : null,
        ),
      ],
    );
  }
}
