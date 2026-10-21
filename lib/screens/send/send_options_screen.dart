import 'package:coconut_design_system/coconut_design_system.dart' hide CoconutAppBar, CoconutPopup, CoconutToast;
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
import 'package:coconut_wallet/screens/send/payment_request_labels.dart';
import 'package:coconut_wallet/screens/send/utxo_selection_screen.dart';
import 'package:coconut_wallet/services/ark/ark_wallet_service.dart';
import 'package:coconut_wallet/ui/coconut/coconut_app_bar.dart';
import 'package:coconut_wallet/ui/coconut/coconut_overlays.dart';
import 'package:coconut_wallet/utils/fee_rate_mixin.dart';
import 'package:coconut_wallet/utils/logger.dart';
import 'package:coconut_wallet/utils/payment_request_parser.dart';
import 'package:coconut_wallet/widgets/common/dialogs/dialog.dart';
import 'package:coconut_wallet/widgets/common/overlays/common_bottom_sheets.dart';
import 'package:coconut_wallet/widgets/features/utxo/bottom_sheet/estimated_fee_bottom_sheet.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// Step 2 of Send for a hot wallet with Ark: how to pay the recipients chosen on step 1. One
/// recipient can be paid every way its request allows, each card with its fee: from Ark (Ark,
/// Lightning, on-chain via Ark) or on-chain from the wallet's UTXOs. Several recipients, or Max,
/// go on-chain in one transaction. The on-chain card picks UTXOs and the fee rate before the
/// confirm screen. Strings are not localized yet (proof of concept).
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
  late final String _walletName;
  late final BitcoinUnit _unit;
  bool _isPaying = false;

  @override
  void initState() {
    super.initState();
    final walletProvider = context.read<WalletProvider>();
    _arkProvider = context.read<ArkProvider>();
    _walletName = walletProvider.getWalletById(widget.id).name;
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
      onClosed: _vm.tidyFeeRate,
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => CoconutPopup(
            languageCode: context.read<PreferenceProvider>().language,
            title: 'Pay ${_display(amount)}?',
            description:
                '${sendOptionTitle(option.kind)} to ${shortenDestination(option.destination)}. '
                'The Ark server charges ${_display(fee)}.',
            leftButtonText: t.cancel,
            rightButtonText: t.confirm,
            onTapLeft: () => Navigator.pop(dialogContext, false),
            onTapRight: () => Navigator.pop(dialogContext, true),
          ),
    );
    if (confirmed != true || !mounted) return;
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
      _showResult(movementId, fallbackToast: 'Paid');
    } on ArkMovePendingException {
      if (!mounted) return;
      _showResult(null, fallbackToast: 'Accepted: Ark finishes the payment on a later sync');
    } on ArkPaymentException catch (error) {
      Logger.error('SendOptionsScreen: payment failed: $error');
      if (!mounted) return;
      setState(() => _isPaying = false);
      await showInfoDialog(context, context.read<PreferenceProvider>().language, 'Payment failed', '$error');
      if (mounted && error.movementId != null) _showResult(error.movementId, fallbackToast: null);
    } catch (error) {
      if (!mounted) return;
      setState(() => _isPaying = false);
      await showInfoDialog(context, context.read<PreferenceProvider>().language, 'Payment failed', '$error');
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

  String _display(int sats) =>
      _unit.displayBitcoinAmount(sats, withUnit: true, shouldCheckZero: true, defaultWhenZero: '0 ${_unit.symbol}');

  // --- Layout ---

  @override
  Widget build(BuildContext context) {
    final colors = context.coconutColors;
    return ListenableBuilder(
      listenable: _vm,
      builder: (context, _) {
        final selected = _vm.selected;
        final isOnchain = selected?.kind == SendOptionKind.onchain;
        final canGo = _vm.canProceed && !_isPaying;
        final String? onchainOnlyNote;
        if (_vm.isBatch) {
          onchainOnlyNote = 'Several recipients go out in one on-chain transaction.';
        } else if (_vm.isMaxMode) {
          onchainOnlyNote = 'Max sends everything on-chain.';
        } else {
          onchainOnlyNote = null;
        }
        return Scaffold(
          backgroundColor: colors.background,
          appBar: CoconutAppBar.build(
            context: context,
            title: '${t.send} · $_walletName',
            backgroundColor: colors.background,
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
              children: [
                _buildRecipients(),
                CoconutLayout.spacing_500h,
                _label('Pay with'),
                if (onchainOnlyNote != null) ...[_muted(onchainOnlyNote), CoconutLayout.spacing_200h],
                for (final option in _vm.options) ...[_buildOption(option), CoconutLayout.spacing_200h],
              ],
            ),
          ),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: CoconutButton(
                text: _isPaying ? 'Paying…' : (isOnchain ? t.next : 'Pay'),
                isActive: canGo,
                onPressed: canGo ? (isOnchain ? _nextOnchain : _payFromArk) : () {},
                height: 52,
                backgroundColor: colors.primary,
                foregroundColor: colors.background,
              ),
            ),
          ),
        );
      },
    );
  }

  /// Who gets what; tapping goes back to step 1 to change it.
  Widget _buildRecipients() {
    final colors = context.coconutColors;
    final recipients = _vm.recipients;
    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(CoconutStyles.radius_300),
      child: InkWell(
        borderRadius: BorderRadius.circular(CoconutStyles.radius_300),
        onTap: () => Navigator.pop(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      recipients.length == 1
                          ? describePaymentRequest(_vm.request, _unit)
                          : '${recipients.length} recipients',
                      style: CoconutTypography.body3_12.setColor(colors.secondaryText),
                    ),
                    CoconutLayout.spacing_100h,
                    for (var i = 0; i < recipients.length; i++) _recipientLine(i),
                  ],
                ),
              ),
              CoconutLayout.spacing_200w,
              Icon(Icons.edit_outlined, size: 18, color: colors.iconPrimary),
            ],
          ),
        ),
      ),
    );
  }

  Widget _recipientLine(int index) {
    final colors = context.coconutColors;
    final request = _vm.recipients[index].request;
    final destination =
        request.bitcoinAddress ?? request.arkAddress ?? request.lightningInvoice ?? request.lightningAddress ?? '';
    final amount = _vm.amountOf(index);
    final isMax = _vm.isMaxMode && index == _vm.recipients.length - 1;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              shortenDestination(destination),
              style: CoconutTypography.body2_14_Number.setColor(colors.primaryText),
            ),
          ),
          Text(
            amount == null ? (isMax ? 'Everything left' : '—') : _display(amount),
            style: CoconutTypography.body2_14_NumberBold.setColor(colors.primaryText),
          ),
        ],
      ),
    );
  }

  Widget _buildOption(SendOption option) {
    final colors = context.coconutColors;
    final status = _vm.statusOf(option);
    final isSelected = _vm.selected == option;
    final total = option.kind == SendOptionKind.onchain ? _vm.totalSats : _vm.amountSats;
    final available = option.kind == SendOptionKind.onchain ? _vm.onchainAvailableSats : _vm.arkSpendableSats;
    final String feeText;
    if (status.isEstimating) {
      feeText = 'Estimating…';
    } else if (status.feeSats != null) {
      feeText = '${option.kind == SendOptionKind.onchain ? '≈ ' : ''}fee ${_display(status.feeSats!)}';
    } else {
      feeText = '';
    }
    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(CoconutStyles.radius_300),
      child: InkWell(
        borderRadius: BorderRadius.circular(CoconutStyles.radius_300),
        onTap: () => _vm.select(option),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                    size: 20,
                    color: status.problem == null ? colors.iconPrimary : colors.iconDisabled,
                  ),
                  CoconutLayout.spacing_300w,
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          sendOptionTitle(option.kind),
                          style: CoconutTypography.body2_14_Bold.setColor(colors.primaryText),
                        ),
                        _muted('${sendOptionSource(option.kind)} · ${_display(available)}'),
                      ],
                    ),
                  ),
                  Text(feeText, style: CoconutTypography.body3_12_Number.setColor(colors.primaryText)),
                ],
              ),
              if (status.problem != null) ...[
                CoconutLayout.spacing_200h,
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        status.problem!,
                        style: CoconutTypography.body3_12.setColor(isSelected ? colors.danger : colors.secondaryText),
                      ),
                    ),
                    if (status.canUnlock) TextButton(onPressed: _unlock, child: const Text('Unlock')),
                  ],
                ),
              ] else if (isSelected && status.feeSats != null && total != null) ...[
                CoconutLayout.spacing_200h,
                _row(
                  option.kind == SendOptionKind.onchain ? 'Total from the wallet' : 'Total from Ark',
                  _display(total + status.feeSats!),
                ),
              ],
              if (isSelected && option.kind == SendOptionKind.onchain) _buildOnchainDetails(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOnchainDetails() {
    final colors = context.coconutColors;
    final feeRate = _vm.feeRate;
    final String feeRateText;
    if (feeRate != null) {
      feeRateText = '${feeRate % 1 == 0 ? feeRate.toStringAsFixed(0) : feeRate} sat/vB';
    } else {
      feeRateText = _vm.recommendedFeeFetchStatus == RecommendedFeeFetchStatus.fetching ? 'Loading…' : 'Set';
    }
    final dust = _vm.unintendedDustFee;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CoconutLayout.spacing_300h,
        Divider(height: 1, color: colors.surfaceMuted),
        _tapRow(
          'UTXOs',
          _vm.isUtxoAuto
              ? 'Auto'
              : '${_vm.selectedUtxos.length} UTXO${_vm.selectedUtxos.length == 1 ? '' : 's'} · '
                  '${_display(_vm.onchainAvailableSats)}',
          _pickUtxos,
        ),
        _tapRow('Fee rate', feeRateText, _editFeeRate),
        if (dust != null && dust > 0) _muted('Includes ${_display(dust)} of change too small to keep'),
      ],
    );
  }

  Widget _tapRow(String label, String value, VoidCallback onTap) {
    final colors = context.coconutColors;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Expanded(child: Text(label, style: CoconutTypography.body3_12.setColor(colors.secondaryText))),
            Text(value, style: CoconutTypography.body3_12_Number.setColor(colors.primaryText)),
            Icon(Icons.chevron_right, size: 18, color: colors.iconPrimary),
          ],
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: CoconutTypography.body2_14_Bold.setColor(context.coconutColors.primaryText)),
  );

  Widget _muted(String text) =>
      Text(text, style: CoconutTypography.body3_12.setColor(context.coconutColors.secondaryText));

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Expanded(child: Text(label, style: CoconutTypography.body3_12.setColor(context.coconutColors.secondaryText))),
        Text(value, style: CoconutTypography.body3_12_Number.setColor(context.coconutColors.primaryText)),
      ],
    ),
  );
}
