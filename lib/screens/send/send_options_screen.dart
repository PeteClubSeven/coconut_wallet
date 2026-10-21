import 'package:coconut_design_system/coconut_design_system.dart' hide CoconutAppBar, CoconutPopup, CoconutToast;
import 'package:coconut_lib/coconut_lib.dart';
import 'package:coconut_wallet/analytics/analytics_screen_names.dart';
import 'package:coconut_wallet/app/router/app_route_names.dart';
import 'package:coconut_wallet/app/router/route_args.dart';
import 'package:coconut_wallet/config/number_format_config.dart';
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
import 'package:coconut_wallet/utils/address_scan_util.dart';
import 'package:coconut_wallet/utils/balance_format_util.dart';
import 'package:coconut_wallet/utils/fee_rate_mixin.dart';
import 'package:coconut_wallet/utils/logger.dart';
import 'package:coconut_wallet/utils/payment_request_parser.dart';
import 'package:coconut_wallet/widgets/common/dialogs/dialog.dart';
import 'package:coconut_wallet/widgets/common/overlays/common_bottom_sheets.dart';
import 'package:coconut_wallet/widgets/features/utxo/bottom_sheet/estimated_fee_bottom_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

/// Step 2 of Send for a hot wallet with Ark: how much, and how to pay it. Lists every way the
/// recipient can be paid with its fee: from Ark (Ark, Lightning, on-chain via Ark) or on-chain
/// from the wallet's UTXOs, where the UTXOs, fee rate and extra recipients are chosen here before
/// the confirm screen. Strings are not localized yet (proof of concept).
class SendOptionsScreen extends StatefulWidget {
  const SendOptionsScreen({
    super.key,
    required this.id,
    required this.input,
    required this.sendEntryPoint,
    this.initialAmountSats,
  });

  final int id;

  /// The payment request, as entered on the recipient step.
  final String input;
  final SendEntryPoint sendEntryPoint;
  final int? initialAmountSats;

  @override
  State<SendOptionsScreen> createState() => _SendOptionsScreenState();
}

class _SendOptionsScreenState extends State<SendOptionsScreen> {
  late final SendOptionsViewModel _vm;
  late final ArkProvider _arkProvider;
  late final String _walletName;
  final TextEditingController _amountController = TextEditingController();
  final FocusNode _amountFocusNode = FocusNode();
  late BitcoinUnit _unit;
  bool _isPaying = false;

  @override
  void initState() {
    super.initState();
    final walletProvider = context.read<WalletProvider>();
    _arkProvider = context.read<ArkProvider>();
    _walletName = walletProvider.getWalletById(widget.id).name;
    _unit = context.read<PreferenceProvider>().currentUnit;
    _vm = SendOptionsViewModel(
      request: PaymentRequest.parse(widget.input, NetworkType.currentNetworkType),
      wallet: walletProvider.getWalletById(widget.id),
      utxos: walletProvider.getUtxoList(widget.id),
      changeDerivationPath: walletProvider.getChangeAddress(widget.id).derivationPath,
      ark: ArkProviderSendAccess(_arkProvider, widget.id),
      sendInfoProvider: context.read<SendInfoProvider>(),
    );
    final initialAmount = widget.initialAmountSats;
    if (_vm.fixedAmountSats == null && initialAmount != null && initialAmount > 0) {
      _amountController.text = _amountText(initialAmount, _unit);
      _vm.setEnteredAmount(initialAmount);
    }
    _amountController.addListener(_onAmountTextChanged);
    _arkProvider.addListener(_vm.onArkChanged);
    _vm.refreshRecommendedFees();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (_vm.fixedAmountSats == null && _amountController.text.isEmpty) _amountFocusNode.requestFocus();
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
    _amountController.dispose();
    _amountFocusNode.dispose();
    super.dispose();
  }

  // --- Amount ---

  static String _amountText(int sats, BitcoinUnit unit) {
    if (unit.isBasedOnSatoshi) return '$sats';
    return UnitUtil.convertSatoshiToBitcoinString(sats).replaceAll('.', NumberFormatConfig.instance.decimalSeparator);
  }

  int? _parseAmount(String text) {
    final normalized = normalizeNumTextForNumParsing(text.trim());
    if (normalized.isEmpty) return null;
    final value = double.tryParse(normalized);
    if (value == null || value <= 0) return null;
    final decimals = normalized.contains('.') ? normalized.split('.').last.length : 0;
    if (_unit.isBasedOnSatoshi ? decimals > 0 : decimals > 8) return null;
    return _unit.toSatoshi(value);
  }

  void _onAmountTextChanged() => _vm.setEnteredAmount(_parseAmount(_amountController.text));

  void _toggleUnit() {
    final sats = _parseAmount(_amountController.text);
    setState(() => _unit = _unit.isBasedOnSatoshi ? BitcoinUnit.btc : BitcoinUnit.sats);
    _amountController.text = sats == null ? '' : _amountText(sats, _unit);
  }

  void _toggleMax() {
    FocusScope.of(context).unfocus();
    _vm.setMaxMode(!_vm.isMaxMode);
  }

  // --- On-chain choices ---

  Future<void> _pickUtxos() async {
    FocusScope.of(context).unfocus();
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
    FocusScope.of(context).unfocus();
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

  Future<void> _addRecipient() async {
    FocusScope.of(context).unfocus();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.coconutColors.surfaceBottomSheet,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _AddRecipientSheet(viewModel: _vm, unit: _unit),
    );
  }

  Future<void> _unlock() async {
    await openArkWalletForSession(context, widget.id, userInitiated: true);
    _vm.onArkChanged();
  }

  // --- Going ahead ---

  void _nextOnchain() {
    FocusScope.of(context).unfocus();
    _vm.saveOnchainForConfirm(widget.sendEntryPoint);
    Navigator.pushNamed(context, AppRouteNames.sendConfirm, arguments: SendConfirmRouteArgs(currentUnit: _unit));
  }

  bool _isSendStart(Route<dynamic> route) =>
      widget.sendEntryPoint == SendEntryPoint.walletDetail
          ? route.settings.name == AppRouteNames.walletDetail || route.isFirst
          : route.isFirst;

  Future<void> _payFromArk() async {
    FocusScope.of(context).unfocus();
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
                _buildRecipientHeader(),
                CoconutLayout.spacing_400h,
                _buildAmount(),
                CoconutLayout.spacing_500h,
                _label('Pay with'),
                for (final option in _vm.options) ...[_buildOption(option), CoconutLayout.spacing_200h],
              ],
            ),
          ),
          bottomNavigationBar: Padding(
            // Rides above the keyboard, which a bottom bar otherwise sits behind.
            padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
            child: SafeArea(
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
          ),
        );
      },
    );
  }

  Widget _buildRecipientHeader() {
    final colors = context.coconutColors;
    final request = _vm.request;
    final destination =
        request.bitcoinAddress ?? request.arkAddress ?? request.lightningInvoice ?? request.lightningAddress;
    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(CoconutStyles.radius_300),
      child: InkWell(
        borderRadius: BorderRadius.circular(CoconutStyles.radius_300),
        onTap: () => Navigator.pop(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      describePaymentRequest(request, _unit),
                      style: CoconutTypography.body3_12.setColor(colors.secondaryText),
                    ),
                    if (destination != null)
                      Text(
                        shortenDestination(destination),
                        style: CoconutTypography.body2_14_Number.setColor(colors.primaryText),
                      ),
                  ],
                ),
              ),
              Icon(Icons.edit_outlined, size: 18, color: colors.iconPrimary),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAmount() {
    final colors = context.coconutColors;
    final fixed = _vm.fixedAmountSats;
    final Widget amount;
    if (fixed != null || _vm.isMaxMode) {
      final value = fixed ?? _vm.amountSats;
      amount = Text(
        value == null ? '…' : _display(value),
        style: CoconutTypography.heading4_18_NumberBold.setColor(colors.primaryText),
      );
    } else {
      amount = TextField(
        controller: _amountController,
        focusNode: _amountFocusNode,
        keyboardType: TextInputType.numberWithOptions(decimal: !_unit.isBasedOnSatoshi),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(_unit.isBasedOnSatoshi ? r'[0-9]' : r'[0-9.,]'))],
        style: CoconutTypography.heading4_18_NumberBold.setColor(colors.primaryText),
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          hintText: '0',
          hintStyle: CoconutTypography.heading4_18_NumberBold.setColor(colors.tertiaryText),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: colors.surface, borderRadius: BorderRadius.circular(CoconutStyles.radius_300)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: amount),
              if (fixed == null && !_vm.isMaxMode) _chip(_unit.symbol, selected: false, onTap: _toggleUnit),
              if (_vm.canUseMax) ...[
                CoconutLayout.spacing_200w,
                _chip('Max', selected: _vm.isMaxMode, onTap: _toggleMax),
              ],
            ],
          ),
          if (fixed != null) ...[
            CoconutLayout.spacing_100h,
            _muted(_vm.request.kind == PaymentRequestKind.lightningInvoice ? 'Set by the invoice' : 'Set by the code'),
          ],
          CoconutLayout.spacing_300h,
          if (_vm.showsOnchainBalance) _row('Available on-chain', _display(_vm.onchainAvailableSats)),
          if (_vm.showsArkBalance) _row('Available in Ark', _display(_vm.arkSpendableSats)),
        ],
      ),
    );
  }

  Widget _buildOption(SendOption option) {
    final colors = context.coconutColors;
    final status = _vm.statusOf(option);
    final isSelected = _vm.selected == option;
    final amount = _vm.amountSats;
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
                        _muted(sendOptionSource(option.kind)),
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
                        style: CoconutTypography.body3_12.setColor(
                          isSelected && amount != null ? colors.danger : colors.secondaryText,
                        ),
                      ),
                    ),
                    if (status.canUnlock) TextButton(onPressed: _unlock, child: const Text('Unlock')),
                  ],
                ),
              ] else if (isSelected && status.feeSats != null && amount != null) ...[
                CoconutLayout.spacing_200h,
                _row(
                  option.kind == SendOptionKind.onchain ? 'Total from the wallet' : 'Total from Ark',
                  _display(amount + _extraTotal(option) + status.feeSats!),
                ),
              ],
              if (isSelected && option.kind == SendOptionKind.onchain) _buildOnchainDetails(option),
            ],
          ),
        ),
      ),
    );
  }

  int _extraTotal(SendOption option) =>
      option.kind == SendOptionKind.onchain
          ? _vm.extraRecipients.fold(0, (total, recipient) => total + recipient.amountSats)
          : 0;

  Widget _buildOnchainDetails(SendOption option) {
    final colors = context.coconutColors;
    final feeRate = _vm.feeRate;
    final String feeRateText;
    if (feeRate != null) {
      feeRateText = '${feeRate % 1 == 0 ? feeRate.toStringAsFixed(0) : feeRate} sat/vB';
    } else {
      feeRateText = _vm.recommendedFeeFetchStatus == RecommendedFeeFetchStatus.fetching ? 'Loading…' : 'Set';
    }
    final dust = _vm.unintendedDustFee;
    final amount = _vm.amountSats;
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
        CoconutLayout.spacing_200h,
        _label('Recipients'),
        _recipientRow(option.destination, amount),
        for (final (index, recipient) in _vm.extraRecipients.indexed)
          _recipientRow(recipient.address, recipient.amountSats, onRemove: () => _vm.removeRecipient(index)),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _addRecipient,
            icon: Icon(Icons.add, size: 18, color: colors.iconPrimary),
            label: Text('Add recipient', style: CoconutTypography.body3_12.setColor(colors.primaryText)),
          ),
        ),
      ],
    );
  }

  Widget _recipientRow(String address, int? amountSats, {VoidCallback? onRemove}) {
    final colors = context.coconutColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              shortenDestination(address),
              style: CoconutTypography.body3_12_Number.setColor(colors.secondaryText),
            ),
          ),
          Text(
            amountSats == null ? '—' : _display(amountSats),
            style: CoconutTypography.body3_12_Number.setColor(colors.primaryText),
          ),
          if (onRemove != null)
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: onRemove,
              icon: Icon(Icons.close, size: 16, color: colors.iconPrimary),
            )
          else
            const SizedBox(width: 40),
        ],
      ),
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

  Widget _chip(String text, {required bool selected, required VoidCallback onTap}) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: selected ? context.coconutColors.surfaceMuted : Colors.transparent,
        border: Border.all(color: context.coconutColors.surfaceMuted),
        borderRadius: BorderRadius.circular(CoconutStyles.radius_100),
      ),
      child: Text(text, style: CoconutTypography.body3_12.setColor(context.coconutColors.primaryText)),
    ),
  );
}

/// Adds another on-chain recipient: a Bitcoin address (typed, pasted or scanned; a BIP21 code
/// brings its amount) and an amount.
class _AddRecipientSheet extends StatefulWidget {
  const _AddRecipientSheet({required this.viewModel, required this.unit});

  final SendOptionsViewModel viewModel;
  final BitcoinUnit unit;

  @override
  State<_AddRecipientSheet> createState() => _AddRecipientSheetState();
}

class _AddRecipientSheetState extends State<_AddRecipientSheet> {
  final TextEditingController _addressController = TextEditingController();
  final TextEditingController _amountController = TextEditingController();
  String? _error;

  BitcoinUnit get _unit => widget.unit;

  @override
  void dispose() {
    _addressController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  void _setAddress(String text) {
    _addressController.text = text.trim();
    final request = PaymentRequest.parse(text, NetworkType.currentNetworkType);
    final amount = request.amountSats;
    if (amount != null && _amountController.text.isEmpty) {
      _amountController.text = _SendOptionsScreenState._amountText(amount, _unit);
    }
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text != null && text.trim().isNotEmpty && mounted) setState(() => _setAddress(text));
  }

  Future<void> _scan() async {
    final scanned = await showAddressScannerBottomSheet(context, title: 'Add recipient');
    if (scanned != null && mounted) setState(() => _setAddress(scanned));
  }

  void _add() {
    final normalized = normalizeNumTextForNumParsing(_amountController.text.trim());
    final value = double.tryParse(normalized);
    if (value == null || value <= 0) {
      setState(() => _error = 'Enter an amount');
      return;
    }
    final error = widget.viewModel.addRecipient(_addressController.text, _unit.toSatoshi(value));
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.coconutColors;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Add recipient', style: CoconutTypography.body1_16_Bold.setColor(colors.primaryText)),
          CoconutLayout.spacing_100h,
          Text(
            'Another on-chain payment in the same transaction.',
            style: CoconutTypography.body3_12.setColor(colors.secondaryText),
          ),
          CoconutLayout.spacing_400h,
          Container(
            padding: const EdgeInsets.only(left: 16, right: 4),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(CoconutStyles.radius_300),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _addressController,
                    autofocus: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.visiblePassword,
                    maxLines: 2,
                    minLines: 1,
                    onChanged: (_) => setState(() => _error = null),
                    style: CoconutTypography.body2_14.setColor(colors.primaryText),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      hintText: 'Bitcoin address',
                      hintStyle: CoconutTypography.body2_14.setColor(colors.tertiaryText),
                    ),
                  ),
                ),
                IconButton(onPressed: _paste, icon: Icon(Icons.content_paste, color: colors.iconPrimary, size: 20)),
                IconButton(onPressed: _scan, icon: Icon(Icons.qr_code_scanner, color: colors.iconPrimary, size: 20)),
              ],
            ),
          ),
          CoconutLayout.spacing_200h,
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(CoconutStyles.radius_300),
            ),
            child: TextField(
              controller: _amountController,
              keyboardType: TextInputType.numberWithOptions(decimal: !_unit.isBasedOnSatoshi),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(_unit.isBasedOnSatoshi ? r'[0-9]' : r'[0-9.,]')),
              ],
              onChanged: (_) => setState(() => _error = null),
              style: CoconutTypography.body2_14_Number.setColor(colors.primaryText),
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: 'Amount',
                suffixText: _unit.symbol,
                hintStyle: CoconutTypography.body2_14.setColor(colors.tertiaryText),
              ),
            ),
          ),
          if (_error != null) ...[
            CoconutLayout.spacing_200h,
            Text(_error!, style: CoconutTypography.body3_12.setColor(colors.danger)),
          ],
          CoconutLayout.spacing_400h,
          CoconutButton(
            text: 'Add',
            onPressed: _add,
            height: 52,
            backgroundColor: colors.primary,
            foregroundColor: colors.background,
          ),
        ],
      ),
    );
  }
}
