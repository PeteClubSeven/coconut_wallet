import 'dart:async';

import 'package:coconut_design_system/coconut_design_system.dart'
    hide CoconutAppBar, CoconutPopup, CoconutToast, CoconutOptionPicker;
import 'package:coconut_wallet/constants/icon_path.dart';
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
import 'package:coconut_wallet/ui/coconut/coconut_option_picker.dart';
import 'package:coconut_wallet/ui/coconut/coconut_overlays.dart';
import 'package:coconut_wallet/utils/logger.dart';
import 'package:coconut_wallet/widgets/common/buttons/fixed_bottom_button.dart';
import 'package:coconut_wallet/widgets/features/ark/ark_texts.dart';
import 'package:coconut_wallet/widgets/features/ark/ark_ui.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// Moves a hot wallet's Ark funds on-chain: to the wallet's own next receive address, or to
/// another wallet's (a vault). All of it is an offboard; an amount is an on-chain payment from
/// Ark with the rest staying there. Laid out like the UTXO merge screen.
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
  late BitcoinUnit _unit;

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
    _unit = context.read<PreferenceProvider>().currentUnit;
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
    if (_spendable <= 0) return t.ark.move.nothing_in_ark;
    final received = _received;
    if (received != null && received <= ArkBoardTerms.dustLimitSats) return t.ark.move.too_small;
    final totalOut = _totalOut;
    if (totalOut != null && totalOut > _spendable) return t.ark.move.not_enough;
    return null;
  }

  // The fee estimate waits for the amount to settle: it goes through bark under the wallet lock.
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
        if (mounted && amount == _amountSats) setState(() => _error = t.ark.move.estimate_failed(error: '$error'));
      } finally {
        if (mounted && amount == _amountSats) setState(() => _isEstimating = false);
      }
    });
  }

  Future<void> _editAmount() async {
    final result = await Bip21AmountBottomSheet.show(
      context: context,
      currentUnit: _unit,
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

  void _useEverything() {
    if (_amountSats == null) return;
    setState(() {
      _amountSats = null;
      _feeSats = null;
    });
    _scheduleEstimate();
  }

  Future<void> _move() async {
    final fee = formatSats(_unit, _feeSats ?? 0);
    final confirmed = await confirmArkAction(
      context,
      title:
          _amountSats == null
              ? t.ark.move.confirm_title_all
              : t.ark.move.confirm_title(amount: formatSats(_unit, _amountSats!)),
      description:
          _amountSats == null
              ? t.ark.move.confirm_fee_from_amount(destination: _destinationName, fee: fee)
              : t.ark.move.confirm_fee_on_top(destination: _destinationName, fee: fee),
    );
    if (!confirmed || !mounted) return;
    if (!await FlutterHotWalletAuthenticator(context).authenticate() || !mounted) return;
    setState(() => _isMoving = true);
    try {
      final txid = await _arkProvider.moveOnchain(widget.id, _address, amountSats: _amountSats);
      Logger.log('ArkToOnchainScreen: moved Ark funds on-chain in $txid');
      if (!mounted) return;
      CoconutToast.showBottomToast(context: context, text: t.ark.move.moved(name: _destinationName));
      Navigator.pop(context);
    } on ArkMovePendingException {
      if (!mounted) return;
      CoconutToast.showBottomToast(context: context, text: t.ark.move.accepted_later);
      Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      setState(() => _isMoving = false);
      await showArkError(context, t.ark.move.failed, '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.coconutColors;
    return Consumer<ArkProvider>(
      builder: (context, arkProvider, _) {
        final feeKnown = _feeSats != null && _feeFor == _amountSats;
        final problem = _error ?? _problem;
        final canMove = feeKnown && problem == null && !_isMoving && !_isEstimating;
        const dash = '-';
        return Scaffold(
          backgroundColor: colors.background,
          appBar: CoconutAppBar.build(
            context: context,
            title: _toOwnWallet ? t.ark.move.to_onchain_title : t.ark.move.to_wallet_title(name: _destinationName),
            backgroundColor: colors.background,
          ),
          body: SafeArea(
            child: Stack(
              children: [
                ListView(
                  padding: const EdgeInsets.fromLTRB(16, 32, 16, 160),
                  children: [
                    Text(t.ark.move.question, style: CoconutTypography.heading4_18_Bold.setColor(colors.primaryText)),
                    CoconutLayout.spacing_500h,
                    CoconutOptionPicker(
                      label: t.ark.move.amount,
                      text: _amountSats == null ? t.ark.move.everything : formatSats(_unit, _amountSats!),
                      dividerColor: colors.inputPlaceholder,
                      onTap: _editAmount,
                    ),
                    CoconutLayout.spacing_200h,
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SendOptionPill(
                        label: t.send_screen.input_maximum_amount,
                        iconPath: FeatureSettingsIconPath.broom,
                        isSelected: _amountSats == null,
                        onPressed: _useEverything,
                      ),
                    ),
                    CoconutLayout.spacing_500h,
                    CoconutOptionPicker(
                      label: t.ark.move.destination,
                      text:
                          '${_toOwnWallet ? t.ark.move.onchain(name: _walletName) : _destinationName} · '
                          '${shortenMiddle(_address, head: 10, tail: 8)}',
                      dividerColor: colors.inputPlaceholder,
                      enabled: false,
                      onTap: () {},
                    ),
                    CoconutLayout.spacing_500h,
                    ArkCard(
                      child: Column(
                        children: [
                          ArkInfoRow(label: t.ark.send.available_ark, value: formatSats(_unit, _spendable)),
                          ArkInfoRow(
                            label: t.ark.move.ark_fee,
                            value:
                                feeKnown
                                    ? formatSats(_unit, _feeSats!)
                                    : (_isEstimating ? t.ark.send.estimating : dash),
                          ),
                          ArkInfoRow(
                            label: t.ark.move.leaves_ark,
                            value: feeKnown && _totalOut != null ? formatSats(_unit, _totalOut!) : dash,
                          ),
                          ArkInfoRow(
                            label: t.ark.move.arrives_onchain,
                            value: feeKnown && _received != null ? formatSats(_unit, _received!) : dash,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                FixedBottomButton(
                  onButtonClicked: _move,
                  text: _isMoving ? t.ark.move.moving : t.ark.move.move,
                  isActive: canMove,
                  subWidget:
                      problem == null ? null : Text(problem, style: CoconutTypography.body3_12.setColor(colors.danger)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
