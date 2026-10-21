import 'dart:async';

import 'package:coconut_design_system/coconut_design_system.dart' hide CoconutAppBar, CoconutPopup, CoconutToast;
import 'package:coconut_wallet/design_system/context/coconut_theme_context_extension.dart';
import 'package:coconut_wallet/enums/fiat_enums.dart';
import 'package:coconut_wallet/localization/strings.g.dart';
import 'package:coconut_wallet/model/ark/ark_board.dart';
import 'package:coconut_wallet/providers/ark_provider.dart';
import 'package:coconut_wallet/providers/preferences/preference_provider.dart';
import 'package:coconut_wallet/providers/wallet_provider.dart';
import 'package:coconut_wallet/screens/ark/ark_unlock_flow.dart';
import 'package:coconut_wallet/screens/common/bip21_amount_bottom_sheet.dart';
import 'package:coconut_wallet/screens/common/flutter_hot_wallet_authenticator.dart';
import 'package:coconut_wallet/ui/coconut/coconut_app_bar.dart';
import 'package:coconut_wallet/ui/coconut/coconut_overlays.dart';
import 'package:coconut_wallet/utils/logger.dart';
import 'package:coconut_wallet/widgets/common/dialogs/dialog.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// Moves a hot wallet's Ark funds on-chain: to the wallet's own next receive address, or to
/// another wallet's (a vault). All of it is an offboard; an amount is an on-chain payment from
/// Ark with the rest staying there. Strings are not localized yet (proof of concept).
class ArkToOnchainScreen extends StatefulWidget {
  const ArkToOnchainScreen({super.key, required this.id, required this.destinationWalletId});

  /// The hot wallet whose Ark funds move.
  final int id;

  /// Where they go: [id] itself (its on-chain balance) or a vault.
  final int destinationWalletId;

  @override
  State<ArkToOnchainScreen> createState() => _ArkToOnchainScreenState();
}

class _ArkToOnchainScreenState extends State<ArkToOnchainScreen> {
  late final ArkProvider _arkProvider;
  late final String _walletName;
  late final String _destinationName;
  late final String _address;

  /// Null means everything (an offboard).
  int? _amountSats;
  int? _feeSats;
  int? _feeFor;
  bool _isEstimating = false;
  bool _isMoving = false;
  String? _error;
  Timer? _estimateTimer;

  bool get _toOwnWallet => widget.destinationWalletId == widget.id;

  @override
  void initState() {
    super.initState();
    final walletProvider = context.read<WalletProvider>();
    _arkProvider = context.read<ArkProvider>();
    _walletName = walletProvider.getWalletById(widget.id).name;
    _destinationName = walletProvider.getWalletById(widget.destinationWalletId).name;
    _address = walletProvider.getReceiveAddress(widget.destinationWalletId).address;
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
    _estimateTimer?.cancel();
    super.dispose();
  }

  int get _spendable => _arkProvider.balance(widget.id)?.spendable ?? 0;

  /// What leaves Ark: everything, or the amount plus the fee.
  int? get _totalOut => _amountSats == null ? _spendable : (_feeSats == null ? null : _amountSats! + _feeSats!);

  /// What arrives on-chain: everything minus the fee, or the amount.
  int? get _received => _amountSats ?? (_feeSats == null ? null : _spendable - _feeSats!);

  String? get _problem {
    if (_spendable <= 0) return 'There is nothing to move in Ark';
    final received = _received;
    if (received != null && received <= ArkBoardTerms.dustLimitSats) return 'The amount is too small to send on-chain';
    final totalOut = _totalOut;
    if (totalOut != null && totalOut > _spendable) return 'Not enough in Ark to cover the amount and fee';
    return null;
  }

  void _scheduleEstimate() {
    _estimateTimer?.cancel();
    final amount = _amountSats;
    setState(() {
      _isEstimating = true;
      _error = null;
    });
    _estimateTimer = Timer(const Duration(milliseconds: 300), () async {
      try {
        final fee = await _arkProvider.estimateMoveOnchainFee(widget.id, _address, amountSats: amount);
        if (!mounted || amount != _amountSats) return;
        setState(() {
          _feeSats = fee;
          _feeFor = amount;
        });
      } catch (error) {
        if (mounted && amount == _amountSats) setState(() => _error = 'Could not estimate the fee: $error');
      } finally {
        if (mounted && amount == _amountSats) setState(() => _isEstimating = false);
      }
    });
  }

  Future<void> _editAmount() async {
    final result = await Bip21AmountBottomSheet.show(
      context: context,
      currentUnit: context.read<PreferenceProvider>().currentUnit,
      initialAmountSats: _amountSats,
      screenName: 'ark_to_onchain/amount',
    );
    if (!mounted || result == null || !result.didEdit) return;
    setState(() {
      _amountSats = result.amountInSats;
      _feeSats = null;
    });
    _scheduleEstimate();
  }

  void _useMax() {
    if (_amountSats == null) return;
    setState(() {
      _amountSats = null;
      _feeSats = null;
    });
    _scheduleEstimate();
  }

  Future<void> _move(BitcoinUnit unit) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => CoconutPopup(
            languageCode: context.read<PreferenceProvider>().language,
            title: 'Move ${_amountSats == null ? 'all Ark funds' : _amount(unit, _amountSats!)}?',
            description:
                'To $_destinationName on-chain. The Ark server charges ${_amount(unit, _feeSats ?? 0)}, '
                '${_amountSats == null ? 'taken out of the amount' : 'on top of the amount'}.',
            leftButtonText: t.cancel,
            rightButtonText: t.confirm,
            onTapLeft: () => Navigator.pop(dialogContext, false),
            onTapRight: () => Navigator.pop(dialogContext, true),
          ),
    );
    if (confirmed != true || !mounted) return;
    if (!await FlutterHotWalletAuthenticator(context).authenticate() || !mounted) return;
    setState(() => _isMoving = true);
    try {
      final txid = await _arkProvider.moveOnchain(widget.id, _address, amountSats: _amountSats);
      Logger.log('ArkToOnchainScreen: moved Ark funds on-chain in $txid');
      if (!mounted) return;
      CoconutToast.showBottomToast(context: context, text: 'Moved to $_destinationName');
      Navigator.pop(context);
    } on ArkMovePendingException {
      if (!mounted) return;
      CoconutToast.showBottomToast(context: context, text: 'Accepted: Ark finishes the move on a later sync');
      Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      setState(() => _isMoving = false);
      await showInfoDialog(context, context.read<PreferenceProvider>().language, 'Move failed', '$error');
    }
  }

  static String _amount(BitcoinUnit unit, int sats) =>
      unit.displayBitcoinAmount(sats, withUnit: true, shouldCheckZero: true, defaultWhenZero: '0 ${unit.symbol}');

  @override
  Widget build(BuildContext context) {
    final unit = context.select<PreferenceProvider, BitcoinUnit>((provider) => provider.currentUnit);
    return Consumer<ArkProvider>(
      builder: (context, arkProvider, _) {
        final feeKnown = _feeSats != null && _feeFor == _amountSats;
        final problem = _problem;
        final canMove = feeKnown && problem == null && _error == null && !_isMoving && !_isEstimating;
        return Scaffold(
          backgroundColor: context.coconutColors.background,
          appBar: CoconutAppBar.build(
            context: context,
            title: _toOwnWallet ? 'Move to on-chain' : 'Move to $_destinationName',
            backgroundColor: context.coconutColors.background,
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
              children: [
                _card([
                  _row('From', 'Ark · $_walletName'),
                  _row('Available in Ark', _amount(unit, _spendable)),
                  _row('To', _toOwnWallet ? 'On-chain · $_walletName' : _destinationName),
                  _row('Address', '${_address.substring(0, 12)}…${_address.substring(_address.length - 8)}'),
                ]),
                CoconutLayout.spacing_400h,
                _card([
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _amountSats == null ? 'Everything' : _amount(unit, _amountSats!),
                          style: CoconutTypography.heading4_18_NumberBold.setColor(context.coconutColors.primaryText),
                        ),
                      ),
                      _chip('Max', selected: _amountSats == null, onTap: _useMax),
                      CoconutLayout.spacing_200w,
                      _chip('Amount', selected: _amountSats != null, onTap: _editAmount),
                    ],
                  ),
                  CoconutLayout.spacing_300h,
                  _row('Ark fee', feeKnown ? _amount(unit, _feeSats!) : (_isEstimating ? 'Estimating…' : '—')),
                  _row('Leaves Ark', feeKnown && _totalOut != null ? _amount(unit, _totalOut!) : '—'),
                  _row('Arrives on-chain', feeKnown && _received != null ? _amount(unit, _received!) : '—'),
                ]),
                if (problem != null || _error != null) ...[
                  CoconutLayout.spacing_300h,
                  Text(_error ?? problem!, style: CoconutTypography.body3_12.setColor(context.coconutColors.danger)),
                ],
              ],
            ),
          ),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: CoconutButton(
                text: _isMoving ? 'Moving…' : 'Move',
                isActive: canMove,
                onPressed: canMove ? () => _move(unit) : () {},
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

  Widget _card(List<Widget> children) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: context.coconutColors.surface,
      borderRadius: BorderRadius.circular(CoconutStyles.radius_400),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
  );

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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: selected ? context.coconutColors.surfaceMuted : Colors.transparent,
        border: Border.all(color: context.coconutColors.surfaceMuted),
        borderRadius: BorderRadius.circular(CoconutStyles.radius_100),
      ),
      child: Text(text, style: CoconutTypography.body3_12.setColor(context.coconutColors.primaryText)),
    ),
  );
}
