import 'dart:async';

import 'package:coconut_design_system/coconut_design_system.dart'
    hide CoconutAppBar, CoconutPopup, CoconutToast, CoconutUnderlinedButton, CoconutTextField;
import 'package:coconut_lib/coconut_lib.dart';
import 'package:coconut_wallet/analytics/analytics_screen_names.dart';
import 'package:coconut_wallet/app/router/app_route_names.dart';
import 'package:coconut_wallet/app/router/route_args.dart';
import 'package:coconut_wallet/config/number_format_config.dart';
import 'package:coconut_wallet/constants/icon_path.dart';
import 'package:coconut_wallet/design_system/context/coconut_theme_context_extension.dart';
import 'package:coconut_wallet/enums/fiat_enums.dart';
import 'package:coconut_wallet/extensions/int_extensions.dart';
import 'package:coconut_wallet/localization/strings.g.dart';
import 'package:coconut_wallet/model/ark/ark_payment.dart';
import 'package:coconut_wallet/model/ark/move.dart';
import 'package:coconut_wallet/model/utxo/utxo_state.dart';
import 'package:coconut_wallet/providers/ark_provider.dart';
import 'package:coconut_wallet/providers/preferences/preference_provider.dart';
import 'package:coconut_wallet/providers/send_info_provider.dart';
import 'package:coconut_wallet/providers/view_model/send/send_options_view_model.dart';
import 'package:coconut_wallet/providers/wallet_provider.dart';
import 'package:coconut_wallet/screens/ark/ark_unlock_flow.dart';
import 'package:coconut_wallet/screens/common/flutter_hot_wallet_authenticator.dart';
import 'package:coconut_wallet/screens/send/ark_payment_screen.dart';
import 'package:coconut_wallet/screens/send/utxo_selection_screen.dart';
import 'package:coconut_wallet/ui/coconut/coconut_app_bar.dart';
import 'package:coconut_wallet/ui/coconut/coconut_overlays.dart';
import 'package:coconut_wallet/ui/coconut/coconut_text_field.dart';
import 'package:coconut_wallet/ui/coconut/coconut_underlined_button.dart';
import 'package:coconut_wallet/utils/fee_rate_mixin.dart';
import 'package:coconut_wallet/utils/numeric_input_formatters.dart';
import 'package:coconut_wallet/utils/payment_request_parser.dart';
import 'package:coconut_wallet/utils/send_recipients.dart';
import 'package:coconut_wallet/widgets/common/buttons/fixed_bottom_button.dart';
import 'package:coconut_wallet/widgets/common/buttons/shrink_animation_button.dart';
import 'package:coconut_wallet/widgets/common/effects/ripple_effect.dart';
import 'package:coconut_wallet/widgets/common/overlays/common_bottom_sheets.dart';
import 'package:coconut_wallet/widgets/features/ark/ark_texts.dart';
import 'package:coconut_wallet/widgets/features/ark/ark_ui.dart';
import 'package:coconut_wallet/widgets/features/send/send_amount_header.dart';
import 'package:coconut_wallet/widgets/features/send/send_output_detail_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

/// Step 2 of Send for a hot wallet with Ark, and of every Move: how to pay the recipients chosen
/// on step 1. One recipient can be paid every way its request allows, each card with its fee: from
/// Ark (Ark, Lightning, on-chain via Ark) or on-chain from the wallet's UTXOs. Several recipients,
/// or everything on-chain, go on-chain in one transaction; a move pays from its source only. The
/// on-chain card has the send screen's controls (UTXOs, fee rate, fee taken from the amount)
/// before the confirm screen; paying from Ark runs on [ArkPaymentScreen].
class SendOptionsScreen extends StatefulWidget {
  const SendOptionsScreen({
    super.key,
    required this.id,
    required this.recipients,
    required this.sendEntryPoint,
    this.maxLast = false,
    this.maxFromArk = false,
    this.move,
    this.moveDestination,
  });

  /// The paying wallet: for a move, the source's.
  final int id;
  final List<SendRecipientArg> recipients;

  /// The last recipient gets everything left on-chain.
  final bool maxLast;

  /// The only recipient gets everything in Ark.
  final bool maxFromArk;
  final SendEntryPoint sendEntryPoint;
  final MoveSelection? move;
  final MoveDestination? moveDestination;

  @override
  State<SendOptionsScreen> createState() => _SendOptionsScreenState();
}

class _SendOptionsScreenState extends State<SendOptionsScreen> {
  late final SendOptionsViewModel _vm;
  late final ArkProvider _arkProvider;
  late final String _walletName;
  late BitcoinUnit _unit;

  /// The board fee for the amount the board output gets, once estimated.
  ({int amount, int fee})? _boardFee;
  int? _boardFeeRequestedFor;
  Timer? _boardFeeTimer;

  int get _arkWalletId => widget.move?.from.walletId ?? widget.id;

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
      maxFromArk: widget.maxFromArk,
      funding: switch (widget.move?.from.kind) {
        null => SendFunding.any,
        MoveEndpointKind.ark => SendFunding.ark,
        MoveEndpointKind.onchain || MoveEndpointKind.vault => SendFunding.onchain,
      },
      moveDestination: widget.moveDestination,
      wallet: walletProvider.getWalletById(widget.id),
      utxos: walletProvider.getUtxoList(widget.id),
      changeDerivationPath: walletProvider.getChangeAddress(widget.id).derivationPath,
      ark: ArkProviderSendAccess(_arkProvider, _arkWalletId),
      sendInfoProvider: context.read<SendInfoProvider>(),
    );
    _arkProvider.addListener(_vm.onArkChanged);
    _vm.feeRateFocusNode.addListener(_onFeeRateFocusChanged);
    _vm.refreshRecommendedFees();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // Ark and Lightning requests need the Ark wallet; for a plain address, only ask when the
      // session would anyway (the on-chain option works without it).
      if (_vm.showsArkBalance && !_arkProvider.isOpen(_arkWalletId)) {
        final asked = _vm.request.hasArkOrLightning || widget.maxFromArk || widget.move != null;
        await openArkWalletForSession(context, _arkWalletId, userInitiated: asked);
        _vm.onArkChanged();
      }
    });
  }

  @override
  void dispose() {
    _boardFeeTimer?.cancel();
    _arkProvider.removeListener(_vm.onArkChanged);
    _vm.feeRateFocusNode.removeListener(_onFeeRateFocusChanged);
    _vm.dispose();
    super.dispose();
  }

  void _onFeeRateFocusChanged() {
    if (!_vm.feeRateFocusNode.hasFocus) _vm.tidyFeeRate();
    if (mounted) setState(() {});
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

  void _onFeeRateTyped(String text) {
    if (_vm.onFeeRateChanged(normalizeNumTextForNumParsing(text))) {
      CoconutToast.showToast(context: context, isVisibleIcon: true, text: t.send_screen.fee_rate_too_low, seconds: 1);
    }
  }

  void _clearFocus() => FocusScope.of(context).unfocus();

  Future<void> _unlock() async {
    await openArkWalletForSession(context, _arkWalletId, userInitiated: true);
    _vm.onArkChanged();
  }

  /// The Ark server's board fee for what the board output gets, estimated after typing settles.
  void _scheduleBoardFee(int amount) {
    if (_boardFeeRequestedFor == amount) return;
    _boardFeeRequestedFor = amount;
    _boardFeeTimer?.cancel();
    _boardFeeTimer = Timer(const Duration(milliseconds: 400), () async {
      final board = widget.moveDestination?.board;
      if (board == null) return;
      try {
        final fee = await _arkProvider.estimateBoardFee(board.walletId, amount);
        if (mounted && _boardFeeRequestedFor == amount) setState(() => _boardFee = (amount: amount, fee: fee));
      } catch (_) {
        // The note just leaves the fee out.
      }
    });
  }

  // --- Going ahead ---

  void _nextOnchain() {
    _clearFocus();
    _vm.saveOnchainForConfirm(widget.sendEntryPoint);
    Navigator.pushNamed(context, AppRouteNames.sendConfirm, arguments: SendConfirmRouteArgs(currentUnit: _unit));
  }

  bool _isSendStart(Route<dynamic> route) =>
      widget.sendEntryPoint == SendEntryPoint.walletDetail
          ? route.settings.name == AppRouteNames.walletDetail || route.isFirst
          : route.isFirst;

  /// Pays from Ark on the payment screen, which animates it like an on-chain broadcast.
  Future<void> _payFromArk() async {
    final option = _vm.selected!;
    final amount = _vm.arkPaymentAmountSats;
    final walletId = _arkWalletId;
    final invoiceHasAmount = option.rail == ArkPaymentRail.lightningInvoice && _vm.request.invoiceAmountSats != null;
    if (!await FlutterHotWalletAuthenticator(context).authenticate() || !mounted) return;
    Future<ArkPaymentStart> pay() async {
      if (amount == null) {
        // Everything in Ark to a Bitcoin address: an offboard, its fee taken out of it.
        await _arkProvider.moveOnchain(walletId, option.destination);
        return const ArkPaymentStart(isDone: true);
      }
      final movementId = await _arkProvider.pay(
        walletId,
        option.rail!,
        destination: option.destination,
        amountSats: amount,
        invoiceHasAmount: invoiceHasAmount,
      );
      // Lightning is done when the payment settles; Ark and on-chain when the call returns.
      return ArkPaymentStart(movementId: movementId, isDone: option.kind != SendOptionKind.lightning);
    }

    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        settings: const RouteSettings(name: '/ark-payment'),
        transitionDuration: const Duration(milliseconds: 280),
        pageBuilder: (_, __, ___) => ArkPaymentScreen(walletId: walletId, pay: pay, isSendStart: _isSendStart),
        transitionsBuilder:
            (_, animation, __, child) =>
                FadeTransition(opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic), child: child),
      ),
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
        final total = _vm.totalSats;
        final isEditingFeeRate = _vm.feeRateFocusNode.hasFocus;
        final String? onchainOnlyNote;
        if (_vm.isBatch) {
          onchainOnlyNote = t.ark.send.several_onchain;
        } else if (_vm.maxLast) {
          onchainOnlyNote = t.ark.send.max_onchain;
        } else {
          onchainOnlyNote = null;
        }
        final move = widget.move;
        return Scaffold(
          backgroundColor: colors.background,
          appBar: CoconutAppBar.build(
            context: context,
            // The wallet's name, as on step 1 and the send screen; a move says where it goes.
            title: move == null ? _walletName : t.ark.move.screen_title(destination: moveEndpointText(move.to)),
            backgroundColor: colors.background,
          ),
          body: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _clearFocus,
            child: SafeArea(
              child: Stack(
                children: [
                  Column(
                    children: [
                      Expanded(
                        child: ListView(
                          padding: EdgeInsets.fromLTRB(16, 0, 16, isEditingFeeRate ? 24 : 160),
                          children: [
                            SendAmountHeader(
                              amountText: total == null ? '-' : _unit.displayBitcoinAmount(total),
                              unit: _unit,
                              satoshiAmount: total ?? 0,
                              totalCostAmountText: _totalCostText(total, selected, selectedStatus),
                              onTap: _toggleUnit,
                              topMargin: 24,
                            ),
                            CoconutLayout.spacing_500h,
                            _buildRecipients(),
                            CoconutLayout.spacing_500h,
                            ArkSectionTitle(t.ark.send.send_with),
                            if (onchainOnlyNote != null) ...[
                              Text(onchainOnlyNote, style: CoconutTypography.body3_12.setColor(colors.secondaryText)),
                              CoconutLayout.spacing_200h,
                            ],
                            for (final option in _vm.options) ...[_buildOption(option), CoconutLayout.spacing_200h],
                          ],
                        ),
                      ),
                      // Under the list rather than over it, so the field scrolls into view above it.
                      if (isEditingFeeRate) _buildFeeRateKeyboardToolbar(),
                    ],
                  ),
                  if (!isEditingFeeRate)
                    FixedBottomButton(
                      onButtonClicked: isOnchain ? _nextOnchain : _payFromArk,
                      text: isOnchain ? t.next : (move == null ? t.send : t.ark.move.move),
                      isActive: _vm.canProceed,
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// What leaves the wallet: what the recipients get plus the fee (when the fee comes out of the
  /// amounts, they get that much less).
  String _totalCostText(int? total, SendOption? selected, SendOptionStatus? status) {
    final fee = status?.feeSats;
    if (total == null || fee == null || selected == null) return '-';
    return _unit.displayBitcoinAmount(total + fee);
  }

  /// Who gets what, as the confirm screen's output details; "Edit" goes back to step 1.
  Widget _buildRecipients() {
    final colors = context.coconutColors;
    final recipients = _vm.recipients;
    final move = widget.move;
    return ArkCard(
      child: Column(
        children: [
          Row(
            children: [
              Text(t.ark.send.recipients, style: CoconutTypography.body3_12_Bold.setColor(colors.primaryText)),
              if (recipients.length == 1) ...[
                CoconutLayout.spacing_200w,
                ArkChip(
                  move == null ? describePaymentRequest(recipients.single.request, _unit) : moveEndpointText(move.to),
                ),
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
              label: move != null && i == 0 ? moveEndpointText(move.to) : t.ark.send.recipient_n(n: i + 1),
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
          if (isSelected && option.kind == SendOptionKind.onchain) _buildOnchainControls(),
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
                Text(formatSats(_unit, available), style: CoconutTypography.body3_12.setColor(colors.secondaryText)),
              ],
            ),
          ),
          if (feeText.isNotEmpty) ...[
            CoconutLayout.spacing_300w,
            Text(feeText, style: CoconutTypography.body3_12_Number.setColor(colors.primaryText)),
          ],
        ],
      ),
    );
  }

  /// The send screen's on-chain controls: which UTXOs (a pill opening the selection sheet), then
  /// its fee board (fee rate, estimated total fee, fee taken from the amount).
  Widget _buildOnchainControls() {
    final colors = context.coconutColors;
    final dust = _vm.unintendedDustFee;
    final boardNote = _boardNote();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CoconutLayout.spacing_400h,
        Row(
          children: [
            Text(t.ark.send.utxos, style: CoconutTypography.body2_14.setColor(colors.secondaryText)),
            const Spacer(),
            _buildUtxoPill(),
          ],
        ),
        CoconutLayout.spacing_300h,
        Container(
          padding: const EdgeInsets.only(left: 16, right: 14, top: 12, bottom: 20),
          decoration: BoxDecoration(
            border: Border.all(color: colors.border, width: 1),
            borderRadius: const BorderRadius.all(Radius.circular(12)),
          ),
          child: Column(
            children: [
              _buildFeeRateRow(),
              CoconutLayout.spacing_200h,
              Row(
                children: [
                  _feeLabel(t.send_screen.estimated_fee),
                  CoconutLayout.spacing_200w,
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text(
                        '${_vm.onchainFeeSats?.toThousandsSeparatedString() ?? '-'} sats',
                        style: CoconutTypography.body2_14_NumberBold.setColor(colors.primaryText),
                      ),
                    ),
                  ),
                ],
              ),
              if (!_vm.maxLast) _buildFeeSubtracted(),
            ],
          ),
        ),
        if (dust != null && dust > 0) ...[
          CoconutLayout.spacing_200h,
          Text(
            t.ark.send.dust_included(amount: formatSats(_unit, dust)),
            style: CoconutTypography.body3_12.setColor(colors.secondaryText),
          ),
        ],
        if (boardNote != null) ...[
          CoconutLayout.spacing_300h,
          Text(boardNote, style: CoconutTypography.body3_12.setColor(colors.secondaryText)),
        ],
      ],
    );
  }

  /// For a board: when it lands in Ark, and the Ark server's fee.
  String? _boardNote() {
    final terms = widget.moveDestination?.boardTerms;
    final amount = _vm.boardAmountSats;
    if (terms == null || amount == null || amount <= 0) return null;
    _scheduleBoardFee(amount);
    final fee = _boardFee?.amount == amount ? _boardFee!.fee : null;
    if (fee == 0) return t.ark.send.board_note_free(count: terms.requiredConfirmations);
    return t.ark.send.board_note(count: terms.requiredConfirmations, fee: fee == null ? '-' : formatSats(_unit, fee));
  }

  /// The send screen's UTXO pill: automatic selection, or how many are picked.
  Widget _buildUtxoPill() {
    final colors = context.coconutColors;
    final isAuto = _vm.isUtxoAuto;
    return ShrinkAnimationButton(
      onPressed: _pickUtxos,
      // On the card's surface the send screen's pill colour wouldn't show; the page colour does.
      defaultColor: isAuto ? colors.background : colors.brandAccentBackground,
      pressedOverlayColor: colors.surface,
      pressedOverlayOpacity: 0.8,
      borderRadius: 4,
      borderWidth: 0,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(
          isAuto ? t.ark.send.utxo_auto : t.ark.send.utxo_selected(count: _vm.selectedUtxos.length),
          style: CoconutTypography.body3_12_Number.setColor(
            isAuto ? colors.surfaceButtonText : colors.brandAccentForeground,
          ),
        ),
      ),
    );
  }

  Widget _feeLabel(String label) =>
      Text(label, style: CoconutTypography.body2_14.setColor(context.coconutColors.secondaryText));

  /// The send screen's fee rate field: typed on the keypad, with the recommended rates on a bar
  /// above it.
  Widget _buildFeeRateRow() {
    final colors = context.coconutColors;
    return Row(
      children: [
        Expanded(child: _feeLabel(t.send_screen.fee_rate)),
        SizedBox(
          width: 100,
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.0)),
              child: CoconutTextField(
                placeholderColor: colors.border,
                textInputType: const TextInputType.numberWithOptions(signed: false, decimal: true),
                textInputFormatter: const [RateInputFormatter()],
                enableInteractiveSelection: false,
                textAlign: TextAlign.end,
                controller: _vm.feeRateController,
                focusNode: _vm.feeRateFocusNode,
                backgroundColor: colors.background,
                onEditingComplete: _clearFocus,
                height: 30,
                padding: const EdgeInsets.only(left: 0),
                onChanged: _onFeeRateTyped,
                maxLines: 1,
                fontFamily: 'SpaceGrotesk',
                fontSize: 14,
                fontWeight: FontWeight.bold,
                borderRadius: 8,
                suffix: Align(
                  alignment: Alignment.center,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Text(
                      t.send_screen.fee_rate_suffix,
                      style: CoconutTypography.body2_14_NumberBold.copyWith(color: colors.primaryText, height: 1.0),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFeeSubtracted() {
    final colors = context.coconutColors;
    final isOn = _vm.isFeeSubtractedFromAmount;
    return Column(
      children: [
        CoconutLayout.spacing_400h,
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _feeLabel(t.send_screen.fee_subtracted_from_send_amount),
                  FittedBox(
                    child: Text(
                      isOn
                          ? t.send_screen.fee_subtracted_from_send_amount_enabled_description
                          : t.send_screen.fee_subtracted_from_send_amount_disabled_description,
                      style: CoconutTypography.body3_12.setColor(colors.mutedText),
                      maxLines: 2,
                      softWrap: true,
                    ),
                  ),
                ],
              ),
            ),
            CoconutLayout.spacing_200w,
            CoconutSwitch(
              scale: 0.7,
              isOn: isOn,
              activeTrackColor: colors.switchActiveTrack,
              activeThumbColor: colors.switchActiveThumb,
              inactiveTrackColor: colors.switchInactiveTrack,
              inactiveThumbColor: colors.switchInactiveThumb,
              onChanged: _vm.setFeeSubtracted,
            ),
          ],
        ),
      ],
    );
  }

  /// The send screen's bar above the keypad while the fee rate is typed: the recommended rates.
  Widget _buildFeeRateKeyboardToolbar() {
    final colors = context.coconutColors;
    final status = _vm.recommendedFeeFetchStatus;
    return GestureDetector(
      onTap: () {},
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
        color: colors.surface,
        child: Row(
          children:
              status == RecommendedFeeFetchStatus.failed
                  ? [
                    SvgPicture.asset(
                      CommonStateIconPath.triangleWarning,
                      colorFilter: ColorFilter.mode(colors.primaryText, BlendMode.srcIn),
                      width: 20,
                    ),
                    CoconutLayout.spacing_200w,
                    Expanded(
                      child: Text(
                        t.send_screen.recommended_fee_unavailable,
                        style: CoconutTypography.body2_14_Bold.setColor(colors.primaryText),
                      ),
                    ),
                  ]
                  : [
                    _buildFeeItem(FeatureTransactionIconPath.feeRateLow, _vm.feeInfos[2].satsPerVb, status),
                    CoconutLayout.spacing_150w,
                    _buildFeeItem(FeatureTransactionIconPath.feeRateMedium, _vm.feeInfos[1].satsPerVb, status),
                    CoconutLayout.spacing_150w,
                    _buildFeeItem(FeatureTransactionIconPath.feeRateHigh, _vm.feeInfos[0].satsPerVb, status),
                  ],
        ),
      ),
    );
  }

  Widget _buildFeeItem(String iconPath, double? satsPerVb, RecommendedFeeFetchStatus status) {
    final colors = context.coconutColors;
    final isFetching = status == RecommendedFeeFetchStatus.fetching;
    final rateText =
        satsPerVb == null
            ? '-'
            : satsPerVb.toStringAsFixed(1).replaceAll('.', NumberFormatConfig.instance.decimalSeparator);
    return Expanded(
      child: RippleEffect(
        borderRadius: 8,
        onTap: () {
          if (isFetching || satsPerVb == null) return;
          _vm.setFeeRateFromRecommendation(satsPerVb);
          _clearFocus();
        },
        child: Opacity(
          opacity: isFetching ? 0.4 : 1,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              border: Border.all(width: 1, color: colors.border),
              borderRadius: const BorderRadius.all(Radius.circular(8)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SvgPicture.asset(
                  iconPath,
                  height: 12,
                  colorFilter: ColorFilter.mode(colors.primaryText, BlendMode.srcIn),
                ),
                CoconutLayout.spacing_100w,
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '$rateText ${t.send_screen.fee_rate_suffix}',
                    style: CoconutTypography.body2_14.setColor(colors.primaryText),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
