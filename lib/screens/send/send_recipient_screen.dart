import 'package:coconut_design_system/coconut_design_system.dart' hide CoconutAppBar;
import 'package:coconut_lib/coconut_lib.dart';
import 'package:coconut_wallet/app/router/app_route_names.dart';
import 'package:coconut_wallet/app/router/route_args.dart';
import 'package:coconut_wallet/config/number_format_config.dart';
import 'package:coconut_wallet/design_system/context/coconut_theme_context_extension.dart';
import 'package:coconut_wallet/enums/fiat_enums.dart';
import 'package:coconut_wallet/localization/strings.g.dart';
import 'package:coconut_wallet/model/utxo/utxo_state.dart';
import 'package:coconut_wallet/providers/ark_provider.dart';
import 'package:coconut_wallet/providers/preferences/preference_provider.dart';
import 'package:coconut_wallet/providers/send_info_provider.dart';
import 'package:coconut_wallet/providers/wallet_provider.dart';
import 'package:coconut_wallet/widgets/features/ark/ark_texts.dart';
import 'package:coconut_wallet/ui/coconut/coconut_app_bar.dart';
import 'package:coconut_wallet/utils/address_scan_util.dart';
import 'package:coconut_wallet/utils/balance_format_util.dart';
import 'package:coconut_wallet/utils/payment_request_parser.dart';
import 'package:coconut_wallet/utils/send_recipients.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

/// Step 1 of Send for a hot wallet with Ark: who to pay and how much. Each row takes a
/// destination (a Bitcoin or Ark address, a Lightning invoice or address, or a BIP321 code) and
/// its amount, which an invoice or code fills in and locks. "Add recipient" adds rows; several
/// recipients are paid on-chain in one transaction, so they need Bitcoin addresses. Step 2
/// ([AppRouteNames.sendOptions]) chooses how to pay. Strings are not localized yet (proof of
/// concept).
class SendRecipientScreen extends StatefulWidget {
  const SendRecipientScreen({
    super.key,
    required this.id,
    required this.sendEntryPoint,
    this.initialInput,
    this.initialAmountSats,
  });

  final int id;
  final SendEntryPoint sendEntryPoint;

  /// A payment request to start with (a deep link, or one handed back by the on-chain send
  /// screen); with its amount known it goes straight on to step 2.
  final String? initialInput;

  /// An amount already entered for it (handed back by the on-chain send screen).
  final int? initialAmountSats;

  @override
  State<SendRecipientScreen> createState() => _SendRecipientScreenState();
}

/// The fields of one recipient row.
class _RecipientRow {
  final TextEditingController destination = TextEditingController();
  final TextEditingController amount = TextEditingController();
  final FocusNode destinationFocus = FocusNode();
  final FocusNode amountFocus = FocusNode();
  bool isMax = false;

  /// The amount came from the destination (an invoice or code) and can't be edited.
  bool amountLocked = false;

  void dispose() {
    destination.dispose();
    amount.dispose();
    destinationFocus.dispose();
    amountFocus.dispose();
  }
}

class _SendRecipientScreenState extends State<SendRecipientScreen> {
  final List<_RecipientRow> _rows = [];
  late final String _walletName;
  late final int _onchainAvailableSats;
  late BitcoinUnit _unit;

  @override
  void initState() {
    super.initState();
    final walletProvider = context.read<WalletProvider>();
    _walletName = walletProvider.getWalletById(widget.id).name;
    _onchainAvailableSats = walletProvider
        .getUtxoList(widget.id)
        .where((utxo) => utxo.status == UtxoStatus.unspent)
        .fold(0, (total, utxo) => total + utxo.amount);
    _unit = context.read<PreferenceProvider>().currentUnit;
    final first = _addRow();
    final initial = widget.initialInput?.trim();
    if (initial != null && initial.isNotEmpty) {
      first.destination.text = initial;
      _applyDestination(first);
      final amount = widget.initialAmountSats;
      if (!first.amountLocked && amount != null && amount > 0) first.amount.text = _amountText(amount);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_check().canContinue) {
          _next();
        } else {
          (first.amountLocked ? first.destinationFocus : first.amountFocus).requestFocus();
        }
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) first.destinationFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  // --- Rows ---

  _RecipientRow _addRow() {
    final row = _RecipientRow();
    for (final other in _rows) {
      other.isMax = false; // Max is only for the last row
    }
    row.destination.addListener(() {
      _applyDestination(row);
      if (mounted) setState(() {});
    });
    row.amount.addListener(() {
      if (mounted) setState(() {});
    });
    _rows.add(row);
    return row;
  }

  void _addRecipient() {
    setState(() => _addRow());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _rows.last.destinationFocus.requestFocus();
    });
  }

  void _removeRow(_RecipientRow row) {
    setState(() => _rows.remove(row));
    WidgetsBinding.instance.addPostFrameCallback((_) => row.dispose());
  }

  /// Fills in and locks the amount when the destination carries one, and unlocks it when it no
  /// longer does.
  void _applyDestination(_RecipientRow row) {
    final text = row.destination.text.trim();
    final fixed = text.isEmpty ? null : PaymentRequest.parse(text, NetworkType.currentNetworkType).amountSats;
    if (fixed != null) {
      final fixedText = _amountText(fixed);
      if (row.amount.text != fixedText) row.amount.text = fixedText;
      row.amountLocked = true;
      row.isMax = false;
    } else if (row.amountLocked) {
      row.amountLocked = false;
      row.amount.text = '';
    }
  }

  Future<void> _paste(_RecipientRow row) async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (!mounted || text == null || text.trim().isEmpty) return;
    row.destination.text = text.trim();
    _afterDestinationEntered(row);
  }

  Future<void> _scan(_RecipientRow row) async {
    FocusScope.of(context).unfocus();
    final scanned = await showAddressScannerBottomSheet(context, title: t.send);
    if (!mounted || scanned == null) return;
    row.destination.text = scanned.trim();
    _afterDestinationEntered(row);
  }

  /// After a paste or scan: a single recipient whose amount is known goes straight on; otherwise
  /// the amount is next.
  void _afterDestinationEntered(_RecipientRow row) {
    if (_rows.length == 1 && row.amountLocked && _check().canContinue) {
      _next();
    } else if (!row.amountLocked) {
      row.amountFocus.requestFocus();
    }
  }

  void _toggleMax(_RecipientRow row) {
    FocusScope.of(context).unfocus();
    setState(() => row.isMax = !row.isMax);
  }

  // --- Amounts ---

  String _amountText(int sats) {
    if (_unit.isBasedOnSatoshi) return '$sats';
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

  void _toggleUnit() {
    final amounts = [for (final row in _rows) _parseAmount(row.amount.text)];
    setState(() => _unit = _unit.isBasedOnSatoshi ? BitcoinUnit.btc : BitcoinUnit.sats);
    for (var i = 0; i < _rows.length; i++) {
      final amount = amounts[i];
      _rows[i].amount.text = amount == null ? '' : _amountText(amount);
    }
  }

  // --- Going on ---

  SendRecipientList _check({int? arkAvailableSats}) => SendRecipientList(
    [
      for (final row in _rows)
        SendRecipientRow(row.destination.text, enteredAmountSats: _parseAmount(row.amount.text), isMax: row.isMax),
    ],
    network: NetworkType.currentNetworkType,
    onchainAvailableSats: _onchainAvailableSats,
    arkAvailableSats: arkAvailableSats ?? context.read<ArkProvider>().balance(widget.id)?.spendable ?? 0,
  );

  Future<void> _next() async {
    final check = _check();
    if (!check.canContinue) return;
    FocusScope.of(context).unfocus();
    await Navigator.pushNamed(
      context,
      AppRouteNames.sendOptions,
      arguments: SendOptionsRouteArgs(
        id: widget.id,
        recipients: [
          for (var i = 0; i < _rows.length; i++)
            if (!check.checks[i].isEmpty)
              SendRecipientArg(_rows[i].destination.text.trim(), check.checks[i].amountSats),
        ],
        maxLast: check.maxLast,
        sendEntryPoint: widget.sendEntryPoint,
      ),
    );
  }

  // --- Layout ---

  @override
  Widget build(BuildContext context) {
    final colors = context.coconutColors;
    final arkAvailable = context.select<ArkProvider, int>((ark) => ark.balance(widget.id)?.spendable ?? 0);
    final check = _check(arkAvailableSats: arkAvailable);
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
            Text(
              _rows.length == 1 ? 'Who are you paying?' : 'Recipients',
              style: CoconutTypography.body2_14_Bold.setColor(colors.primaryText),
            ),
            CoconutLayout.spacing_200h,
            for (var i = 0; i < _rows.length; i++) ...[
              _buildRow(i, check.checks[i], isLast: i == _rows.length - 1),
              CoconutLayout.spacing_200h,
            ],
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _addRecipient,
                icon: Icon(Icons.add, size: 18, color: colors.iconPrimary),
                label: Text('Add recipient', style: CoconutTypography.body2_14.setColor(colors.primaryText)),
              ),
            ),
            CoconutLayout.spacing_200h,
            _buildAvailable(arkAvailable),
            if (check.exceedsAvailable) ...[
              CoconutLayout.spacing_200h,
              Text(
                t.ark.recipient_problem.more_than_available,
                style: CoconutTypography.body3_12.setColor(colors.danger),
              ),
            ],
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
              text: t.next,
              isActive: check.canContinue,
              onPressed: check.canContinue ? _next : () {},
              height: 52,
              backgroundColor: colors.primary,
              foregroundColor: colors.background,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRow(int index, SendRecipientCheck check, {required bool isLast}) {
    final colors = context.coconutColors;
    final row = _rows[index];
    final request = check.request;
    // "Enter an amount" is what the empty amount field already says.
    final problem = check.problem == SendRecipientProblem.needsAmount ? null : recipientProblemText(check);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 4, 4, 12),
      decoration: BoxDecoration(color: colors.surface, borderRadius: BorderRadius.circular(CoconutStyles.radius_300)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: row.destination,
                  focusNode: row.destinationFocus,
                  // Addresses and invoices must come through exactly as typed or pasted.
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.visiblePassword,
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) {
                    if (!row.amountLocked) row.amountFocus.requestFocus();
                  },
                  maxLines: 3,
                  minLines: 1,
                  style: CoconutTypography.body2_14.setColor(colors.primaryText),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText:
                        _rows.length == 1
                            ? 'Bitcoin or Ark address, Lightning invoice or address, or payment code'
                            : 'Bitcoin address',
                    hintMaxLines: 2,
                    hintStyle: CoconutTypography.body2_14.setColor(colors.tertiaryText),
                  ),
                ),
              ),
              IconButton(
                onPressed: () => _paste(row),
                icon: Icon(Icons.content_paste, color: colors.iconPrimary, size: 20),
              ),
              IconButton(
                onPressed: () => _scan(row),
                icon: Icon(Icons.qr_code_scanner, color: colors.iconPrimary, size: 20),
              ),
              if (_rows.length > 1)
                IconButton(
                  onPressed: () => _removeRow(row),
                  icon: Icon(Icons.close, color: colors.iconPrimary, size: 20),
                ),
            ],
          ),
          if (request != null) ...[
            Align(alignment: Alignment.centerLeft, child: _chip(describePaymentRequest(request, _unit))),
            if (problem != null) ...[
              CoconutLayout.spacing_100h,
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text(problem, style: CoconutTypography.body3_12.setColor(colors.danger)),
              ),
            ],
          ],
          CoconutLayout.spacing_200h,
          Divider(height: 1, color: colors.surfaceMuted),
          Padding(
            padding: const EdgeInsets.only(top: 4, right: 8),
            child: Row(
              children: [
                Expanded(child: _buildAmountField(row)),
                if (isLast && check.canUseMax) _choice('Max', selected: row.isMax, onTap: () => _toggleMax(row)),
              ],
            ),
          ),
          if (row.amountLocked)
            Text(
              request?.kind == PaymentRequestKind.lightningInvoice ? 'Set by the invoice' : 'Set by the code',
              style: CoconutTypography.body3_12.setColor(colors.secondaryText),
            ),
        ],
      ),
    );
  }

  Widget _buildAmountField(_RecipientRow row) {
    final colors = context.coconutColors;
    if (row.isMax) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text('Everything left', style: CoconutTypography.body1_16_Bold.setColor(colors.primaryText)),
      );
    }
    return TextField(
      controller: row.amount,
      focusNode: row.amountFocus,
      readOnly: row.amountLocked,
      keyboardType: TextInputType.numberWithOptions(decimal: !_unit.isBasedOnSatoshi),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(_unit.isBasedOnSatoshi ? r'[0-9]' : r'[0-9.,]'))],
      style: CoconutTypography.body1_16_Bold.setColor(row.amountLocked ? colors.secondaryText : colors.primaryText),
      decoration: InputDecoration(
        border: InputBorder.none,
        hintText: 'Amount',
        hintStyle: CoconutTypography.body1_16.setColor(colors.tertiaryText),
        suffixText: _unit.symbol,
        suffixStyle: CoconutTypography.body2_14.setColor(colors.secondaryText),
      ),
    );
  }

  Widget _buildAvailable(int arkAvailable) {
    final colors = context.coconutColors;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(color: colors.surface, borderRadius: BorderRadius.circular(CoconutStyles.radius_300)),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _available('Available on-chain', _onchainAvailableSats),
                _available('Available in Ark', arkAvailable),
              ],
            ),
          ),
          _choice(_unit.symbol, selected: false, onTap: _toggleUnit),
        ],
      ),
    );
  }

  Widget _available(String label, int sats) {
    final colors = context.coconutColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: CoconutTypography.body3_12.setColor(colors.secondaryText))),
          Text(
            _unit.displayBitcoinAmount(
              sats,
              withUnit: true,
              shouldCheckZero: true,
              defaultWhenZero: '0 ${_unit.symbol}',
            ),
            style: CoconutTypography.body3_12_Number.setColor(colors.primaryText),
          ),
          CoconutLayout.spacing_200w,
        ],
      ),
    );
  }

  Widget _chip(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: context.coconutColors.surfaceMuted,
      borderRadius: BorderRadius.circular(CoconutStyles.radius_100),
    ),
    child: Text(text, style: CoconutTypography.body3_12.setColor(context.coconutColors.primaryText)),
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
