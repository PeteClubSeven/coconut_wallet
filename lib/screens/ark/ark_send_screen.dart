import 'dart:async';

import 'package:coconut_design_system/coconut_design_system.dart' hide CoconutAppBar, CoconutPopup, CoconutToast;
import 'package:coconut_lib/coconut_lib.dart';
import 'package:coconut_wallet/app/router/app_route_names.dart';
import 'package:coconut_wallet/app/router/route_args.dart';
import 'package:coconut_wallet/design_system/context/coconut_theme_context_extension.dart';
import 'package:coconut_wallet/enums/fiat_enums.dart';
import 'package:coconut_wallet/localization/strings.g.dart';
import 'package:coconut_wallet/model/ark/ark_board.dart';
import 'package:coconut_wallet/model/ark/ark_payment.dart';
import 'package:coconut_wallet/providers/ark_provider.dart';
import 'package:coconut_wallet/providers/preferences/preference_provider.dart';
import 'package:coconut_wallet/providers/send_info_provider.dart';
import 'package:coconut_wallet/providers/wallet_provider.dart';
import 'package:coconut_wallet/screens/ark/ark_unlock_flow.dart';
import 'package:coconut_wallet/screens/common/bip21_amount_bottom_sheet.dart';
import 'package:coconut_wallet/screens/common/flutter_hot_wallet_authenticator.dart';
import 'package:coconut_wallet/services/ark/ark_wallet_service.dart';
import 'package:coconut_wallet/ui/coconut/coconut_app_bar.dart';
import 'package:coconut_wallet/ui/coconut/coconut_overlays.dart';
import 'package:coconut_wallet/utils/address_scan_util.dart';
import 'package:coconut_wallet/utils/address_util.dart';
import 'package:coconut_wallet/utils/logger.dart';
import 'package:coconut_wallet/utils/payment_request_parser.dart';
import 'package:coconut_wallet/widgets/common/dialogs/dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

/// Pays from a hot wallet's Ark balance: an Ark address, a Lightning invoice or address, a
/// BIP321 code (Ark first, then Lightning, then on-chain), or a plain Bitcoin address (an
/// on-chain payment from Ark). Strings are not localized yet (proof of concept).
class ArkSendScreen extends StatefulWidget {
  const ArkSendScreen({super.key, required this.id, this.initialInput});

  final int id;

  /// A payment request handed over, e.g. by Coconut's send screen.
  final String? initialInput;

  @override
  State<ArkSendScreen> createState() => _ArkSendScreenState();
}

class _ArkSendScreenState extends State<ArkSendScreen> {
  final TextEditingController _inputController = TextEditingController();
  late final ArkProvider _arkProvider;
  late final String _walletName;
  PaymentRequest? _request;
  ArkPaymentOption? _option;
  int? _enteredAmountSats;
  int? _feeSats;
  String? _feeKey;
  String? _problem;
  bool _isEstimating = false;
  bool _isPaying = false;
  Timer? _parseTimer;
  Timer? _estimateTimer;

  @override
  void initState() {
    super.initState();
    _arkProvider = context.read<ArkProvider>();
    _walletName = context.read<WalletProvider>().getWalletById(widget.id).name;
    _inputController.addListener(_onInputChanged);
    if (widget.initialInput != null) _inputController.text = widget.initialInput!;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!await openArkWalletForSession(context, widget.id, userInitiated: true)) {
        if (mounted) Navigator.pop(context);
        return;
      }
      _scheduleEstimate();
    });
  }

  @override
  void dispose() {
    _parseTimer?.cancel();
    _estimateTimer?.cancel();
    _inputController.dispose();
    super.dispose();
  }

  void _onInputChanged() {
    _parseTimer?.cancel();
    _parseTimer = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      final text = _inputController.text;
      final request = text.trim().isEmpty ? null : PaymentRequest.parse(text, NetworkType.currentNetworkType);
      if (request?.raw == _request?.raw && _request != null) return;
      setState(() {
        _request = request;
        _option = request?.arkOptions.firstOrNull;
        _enteredAmountSats = null;
        _feeSats = null;
        _problem = null;
      });
      _scheduleEstimate();
    });
  }

  /// The amount is the request's when it carries one (an invoice, a BIP321 amount); otherwise the
  /// one entered.
  int? get _fixedAmountSats {
    final request = _request;
    final option = _option;
    if (request == null || option == null) return null;
    if (option.rail == ArkPaymentRail.lightningInvoice) return request.invoiceAmountSats;
    return request.amountSats;
  }

  int? get _amountSats => _fixedAmountSats ?? _enteredAmountSats;

  int get _spendable => _arkProvider.balance(widget.id)?.spendable ?? 0;

  String? get _blockingProblem {
    final request = _request;
    if (request == null) return null;
    if (request.problem != null) return request.problem;
    if (_option == null) return 'Nothing in it can be paid from Ark';
    if (_problem != null) return _problem;
    final amount = _amountSats;
    if (amount == null) return null;
    if (amount <= 0) return 'Enter an amount';
    if (_option!.rail == ArkPaymentRail.onchain && amount <= ArkBoardTerms.dustLimitSats) {
      return 'The amount is too small to send on-chain';
    }
    final fee = _feeSats;
    if (fee != null && amount + fee > _spendable) return 'Not enough in Ark to cover the amount and fee';
    return null;
  }

  void _scheduleEstimate() {
    _estimateTimer?.cancel();
    final option = _option;
    final amount = _amountSats;
    if (option == null || amount == null || amount <= 0 || !_arkProvider.isOpen(widget.id)) {
      setState(() => _isEstimating = false);
      return;
    }
    final key = '${option.rail.name}:${option.destination}:$amount';
    setState(() => _isEstimating = true);
    _estimateTimer = Timer(const Duration(milliseconds: 300), () async {
      String? problem;
      int? fee;
      try {
        if (option.rail == ArkPaymentRail.ark &&
            !await _arkProvider.validateArkAddress(widget.id, option.destination)) {
          problem = 'bark doesn\'t accept this Ark address (another Ark server or network?)';
        } else {
          fee = await _arkProvider.estimatePaymentFee(
            widget.id,
            option.rail,
            destination: option.destination,
            amountSats: amount,
          );
        }
      } catch (error) {
        problem = 'Could not estimate the fee: $error';
      }
      if (!mounted || key != '${_option?.rail.name}:${_option?.destination}:$_amountSats') return;
      setState(() {
        _feeSats = fee;
        _feeKey = key;
        _problem = problem;
        _isEstimating = false;
      });
    });
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text != null && text.trim().isNotEmpty) _inputController.text = text.trim();
    _unfocus();
  }

  Future<void> _scan() async {
    _unfocus();
    final scanned = await showAddressScannerBottomSheet(context, title: 'Pay from Ark');
    if (scanned != null && mounted) _inputController.text = scanned.trim();
  }

  // Sheets hand focus back to the recipient field when they close, and its keyboard would then
  // cover the Pay button.
  void _unfocus() {
    if (mounted) FocusScope.of(context).unfocus();
  }

  Future<void> _editAmount() async {
    _unfocus();
    final result = await Bip21AmountBottomSheet.show(
      context: context,
      currentUnit: context.read<PreferenceProvider>().currentUnit,
      initialAmountSats: _enteredAmountSats,
      screenName: 'ark_send/amount',
    );
    _unfocus();
    if (!mounted || result == null || !result.didEdit) return;
    setState(() {
      _enteredAmountSats = result.amountInSats;
      _feeSats = null;
      _problem = null;
    });
    _scheduleEstimate();
  }

  void _selectOption(ArkPaymentOption option) {
    setState(() {
      _option = option;
      _feeSats = null;
      _problem = null;
    });
    _scheduleEstimate();
  }

  /// Hands a request with an on-chain address over to Coconut's on-chain send, without the Ark
  /// and Lightning parts (so it doesn't come straight back here).
  void _payOnchainInstead() {
    final request = _request!;
    final uri = buildBip21Uri(request.bitcoinAddress!, amount: request.amountSats);
    Navigator.pushReplacementNamed(
      context,
      AppRouteNames.send,
      arguments: SendRouteArgs(id: widget.id, sendEntryPoint: SendEntryPoint.walletDetail, initialBitcoinUri: uri),
    );
  }

  Future<void> _pay(BitcoinUnit unit) async {
    final option = _option!;
    final amount = _amountSats!;
    final fee = _feeSats ?? 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => CoconutPopup(
            languageCode: context.read<PreferenceProvider>().language,
            title: 'Pay ${_amount(unit, amount)}?',
            description:
                '${_railLabel(option.rail)} to ${_shorten(option.destination)}. '
                'The Ark server charges ${_amount(unit, fee)}.',
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
        option.rail,
        destination: option.destination,
        amountSats: amount,
        invoiceHasAmount: option.rail == ArkPaymentRail.lightningInvoice && _request!.invoiceAmountSats != null,
      );
      if (!mounted) return;
      _openResult(movementId, fallbackToast: 'Paid');
    } on ArkMovePendingException {
      if (!mounted) return;
      _openResult(null, fallbackToast: 'Accepted: Ark finishes the payment on a later sync');
    } on ArkPaymentException catch (error) {
      Logger.error('ArkSendScreen: payment failed: $error');
      if (!mounted) return;
      setState(() => _isPaying = false);
      await showInfoDialog(context, context.read<PreferenceProvider>().language, 'Payment failed', '$error');
      if (mounted && error.movementId != null) _openResult(error.movementId, fallbackToast: null);
    } catch (error) {
      if (!mounted) return;
      setState(() => _isPaying = false);
      await showInfoDialog(context, context.read<PreferenceProvider>().language, 'Payment failed', '$error');
    }
  }

  /// Shows the payment's movement (it may still be pending) in place of this screen.
  void _openResult(int? movementId, {required String? fallbackToast}) {
    if (movementId == null) {
      if (fallbackToast != null) CoconutToast.showBottomToast(context: context, text: fallbackToast);
      Navigator.pop(context);
      return;
    }
    Navigator.pushReplacementNamed(
      context,
      AppRouteNames.arkMovementDetail,
      arguments: ArkMovementDetailRouteArgs(id: widget.id, movementId: movementId),
    );
  }

  static String _amount(BitcoinUnit unit, int sats) =>
      unit.displayBitcoinAmount(sats, withUnit: true, shouldCheckZero: true, defaultWhenZero: '0 ${unit.symbol}');

  static String _shorten(String value) =>
      value.length <= 32 ? value : '${value.substring(0, 16)}…${value.substring(value.length - 10)}';

  static String _railLabel(ArkPaymentRail rail) => switch (rail) {
    ArkPaymentRail.ark => 'Ark payment',
    ArkPaymentRail.lightningInvoice => 'Lightning invoice',
    ArkPaymentRail.lightningAddress => 'Lightning address',
    ArkPaymentRail.onchain => 'On-chain from Ark',
  };

  String _requestLabel(PaymentRequest request) => switch (request.kind) {
    PaymentRequestKind.arkAddress => 'Ark address',
    PaymentRequestKind.lightningInvoice =>
      request.invoiceAmountSats == null ? 'Lightning invoice (no amount)' : 'Lightning invoice',
    PaymentRequestKind.lightningAddress => 'Lightning address',
    PaymentRequestKind.bitcoinAddress => 'Bitcoin address: paid on-chain from Ark',
    PaymentRequestKind.bip321 => 'Payment code (BIP321)',
    PaymentRequestKind.unsupported || PaymentRequestKind.unknown => 'Can\'t pay this',
  };

  @override
  Widget build(BuildContext context) {
    final unit = context.select<PreferenceProvider, BitcoinUnit>((provider) => provider.currentUnit);
    return Consumer<ArkProvider>(
      builder: (context, arkProvider, _) {
        final request = _request;
        final option = _option;
        final amount = _amountSats;
        final feeKnown =
            _feeSats != null && option != null && _feeKey == '${option.rail.name}:${option.destination}:$amount';
        final problem = _blockingProblem;
        final canPay =
            request != null &&
            option != null &&
            amount != null &&
            feeKnown &&
            problem == null &&
            !_isEstimating &&
            !_isPaying &&
            arkProvider.isOpen(widget.id);
        return Scaffold(
          backgroundColor: context.coconutColors.background,
          appBar: CoconutAppBar.build(
            context: context,
            title: 'Pay from Ark',
            backgroundColor: context.coconutColors.background,
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
              children: [
                _muted('From Ark · $_walletName · ${_amount(unit, _spendable)} available'),
                CoconutLayout.spacing_300h,
                _buildInput(),
                if (request != null) ...[
                  CoconutLayout.spacing_300h,
                  _chip(_requestLabel(request)),
                  if (request.arkOptions.length > 1) ...[
                    CoconutLayout.spacing_300h,
                    _label('Pay with'),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final candidate in request.arkOptions)
                          _choice(
                            _railLabel(candidate.rail),
                            selected: candidate.rail == option?.rail,
                            onTap: () => _selectOption(candidate),
                          ),
                      ],
                    ),
                  ],
                  if (option != null) ...[
                    CoconutLayout.spacing_400h,
                    _card([
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              amount == null ? 'Set an amount' : _amount(unit, amount),
                              style: CoconutTypography.heading4_18_NumberBold.setColor(
                                context.coconutColors.primaryText,
                              ),
                            ),
                          ),
                          if (_fixedAmountSats == null) _choice('Amount', selected: false, onTap: _editAmount),
                        ],
                      ),
                      CoconutLayout.spacing_300h,
                      _row('To', _shorten(option.destination)),
                      _row('Ark fee', feeKnown ? _amount(unit, _feeSats!) : (_isEstimating ? 'Estimating…' : '—')),
                      _row('Total from Ark', feeKnown && amount != null ? _amount(unit, amount + _feeSats!) : '—'),
                    ]),
                  ],
                  if (problem != null) ...[
                    CoconutLayout.spacing_300h,
                    Text(problem, style: CoconutTypography.body3_12.setColor(context.coconutColors.danger)),
                  ],
                  if (request.bitcoinAddress != null && request.kind == PaymentRequestKind.bip321) ...[
                    CoconutLayout.spacing_400h,
                    TextButton(onPressed: _payOnchainInstead, child: const Text('Pay on-chain instead')),
                  ],
                ],
              ],
            ),
          ),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: CoconutButton(
                text: _isPaying ? 'Paying…' : 'Pay',
                isActive: canPay,
                onPressed: canPay ? () => _pay(unit) : () {},
                height: 52,
                backgroundColor: context.coconutColors.primary,
                foregroundColor: context.coconutColors.background,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildInput() {
    final colors = context.coconutColors;
    return Container(
      padding: const EdgeInsets.only(left: 16, right: 4),
      decoration: BoxDecoration(color: colors.surface, borderRadius: BorderRadius.circular(CoconutStyles.radius_300)),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _inputController,
              // Addresses and invoices must come through exactly as typed or pasted.
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.visiblePassword,
              maxLines: 3,
              minLines: 1,
              style: CoconutTypography.body2_14.setColor(colors.primaryText),
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: 'Ark address, Lightning invoice or address, or payment code',
                hintStyle: CoconutTypography.body2_14.setColor(colors.tertiaryText),
              ),
            ),
          ),
          IconButton(onPressed: _paste, icon: Icon(Icons.content_paste, color: colors.iconPrimary, size: 20)),
          IconButton(onPressed: _scan, icon: Icon(Icons.qr_code_scanner, color: colors.iconPrimary, size: 20)),
        ],
      ),
    );
  }

  Widget _card(List<Widget> children) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: context.coconutColors.surface,
      borderRadius: BorderRadius.circular(CoconutStyles.radius_400),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
  );

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
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

  Widget _chip(String text) => Align(
    alignment: Alignment.centerLeft,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: context.coconutColors.surfaceMuted,
        borderRadius: BorderRadius.circular(CoconutStyles.radius_100),
      ),
      child: Text(text, style: CoconutTypography.body3_12.setColor(context.coconutColors.primaryText)),
    ),
  );

  Widget _choice(String text, {required bool selected, required VoidCallback onTap}) => GestureDetector(
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
