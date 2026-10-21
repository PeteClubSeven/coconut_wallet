import 'package:coconut_design_system/coconut_design_system.dart'
    hide CoconutAppBar, CoconutTextField, CoconutTextFieldStyle;
import 'package:coconut_lib/coconut_lib.dart';
import 'package:coconut_wallet/app/router/app_route_names.dart';
import 'package:coconut_wallet/app/router/route_args.dart';
import 'package:coconut_wallet/config/number_format_config.dart';
import 'package:coconut_wallet/constants/icon_path.dart';
import 'package:coconut_wallet/design_system/context/coconut_theme_context_extension.dart';
import 'package:coconut_wallet/enums/fiat_enums.dart';
import 'package:coconut_wallet/extensions/string_extensions.dart';
import 'package:coconut_wallet/localization/strings.g.dart';
import 'package:coconut_wallet/model/utxo/utxo_state.dart';
import 'package:coconut_wallet/providers/ark_provider.dart';
import 'package:coconut_wallet/providers/preferences/preference_provider.dart';
import 'package:coconut_wallet/providers/send_info_provider.dart';
import 'package:coconut_wallet/providers/wallet_provider.dart';
import 'package:coconut_wallet/ui/coconut/coconut_app_bar.dart';
import 'package:coconut_wallet/ui/coconut/coconut_text_field.dart';
import 'package:coconut_wallet/utils/address_scan_util.dart';
import 'package:coconut_wallet/utils/balance_format_util.dart';
import 'package:coconut_wallet/utils/dashed_border_painter.dart';
import 'package:coconut_wallet/utils/numeric_input_formatters.dart';
import 'package:coconut_wallet/utils/payment_request_parser.dart';
import 'package:coconut_wallet/utils/send_recipients.dart';
import 'package:coconut_wallet/widgets/common/buttons/fixed_bottom_button.dart';
import 'package:coconut_wallet/widgets/common/buttons/shrink_animation_button.dart';
import 'package:coconut_wallet/widgets/features/ark/ark_texts.dart';
import 'package:coconut_wallet/widgets/features/ark/ark_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

/// Step 1 of Send for a hot wallet with Ark: who to pay and how much. Each recipient card takes a
/// destination (a Bitcoin or Ark address, a Lightning invoice or address, or a BIP321 code) and its
/// amount, which an invoice or code fills in and locks. "Add recipient" adds cards; several
/// recipients are paid on-chain in one transaction, so they need Bitcoin addresses. Step 2
/// ([AppRouteNames.sendOptions]) chooses how to pay.
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

/// The fields of one recipient card.
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
      other.isMax = false; // Send All is only for the last recipient
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

  Future<void> _scan(_RecipientRow row) async {
    FocusScope.of(context).unfocus();
    final scanned = await showAddressScannerBottomSheet(context, title: t.send);
    if (!mounted || scanned == null) return;
    row.destination.text = scanned.trim();
    // A single recipient whose amount is known goes straight on; otherwise the amount is next.
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
    if (_unit.isBasedOnSatoshi) {
      return formatIntWithGroupingSeparator('$sats', NumberFormatConfig.instance.groupingSeparator);
    }
    return UnitUtil.convertSatoshiToBitcoinString(sats).replaceAll('.', NumberFormatConfig.instance.decimalSeparator);
  }

  int? _parseAmount(String text) {
    final value = text.trim().toDoubleSafe();
    if (value == null || value <= 0) return null;
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
      resizeToAvoidBottomInset: false,
      appBar: CoconutAppBar.build(
        context: context,
        title: _walletName,
        isBottom: true,
        backgroundColor: colors.background,
      ),
      body: SafeArea(
        child: Stack(
          children: [
            ListView(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 160 + MediaQuery.viewInsetsOf(context).bottom),
              children: [
                for (var i = 0; i < _rows.length; i++) ...[
                  _buildRecipientCard(i, check.checks[i], isLast: i == _rows.length - 1),
                  CoconutLayout.spacing_300h,
                ],
                _buildAddRecipient(),
                CoconutLayout.spacing_500h,
                _buildAvailable(arkAvailable),
              ],
            ),
            FixedBottomButton(
              onButtonClicked: _next,
              text: t.next,
              isActive: check.canContinue,
              subWidget:
                  check.exceedsAvailable
                      ? Text(
                        t.ark.recipient_problem.more_than_available,
                        style: CoconutTypography.body3_12.setColor(colors.danger),
                      )
                      : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecipientCard(int index, SendRecipientCheck check, {required bool isLast}) {
    final colors = context.coconutColors;
    final row = _rows[index];
    final request = check.request;
    // "Enter an amount" is what the empty amount field already says.
    final problem = check.problem == SendRecipientProblem.needsAmount ? null : recipientProblemText(check);
    return ArkCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_rows.length > 1) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    t.ark.send.recipient_n(n: index + 1),
                    style: CoconutTypography.body3_12_Bold.setColor(colors.secondaryText),
                  ),
                ),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _removeRow(row),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: SvgPicture.asset(
                      CommonActionIconPath.close,
                      width: 14,
                      height: 14,
                      colorFilter: ColorFilter.mode(colors.iconSecondary, BlendMode.srcIn),
                    ),
                  ),
                ),
              ],
            ),
            CoconutLayout.spacing_200h,
          ],
          CoconutTextField(
            controller: row.destination,
            focusNode: row.destinationFocus,
            backgroundColor: colors.surface,
            padding: const EdgeInsets.only(left: 16, right: 0),
            onChanged: (_) {},
            maxLines: 1,
            // Addresses and invoices must come through exactly as typed or pasted.
            autocorrect: false,
            enableSuggestions: false,
            textInputType: TextInputType.visiblePassword,
            textInputAction: TextInputAction.next,
            onEditingComplete: () => row.amountLocked ? row.destinationFocus.unfocus() : row.amountFocus.requestFocus(),
            clearButtonVisibility: CoconutTextFieldClearButtonVisibility.whenNotEmpty,
            onClear: row.destination.clear,
            suffixIconAsset: CommonActionIconPath.scan,
            suffixIconColor: colors.primaryText,
            suffixIconSize: 18,
            onSuffixPressed: () => _scan(row),
            placeholderText:
                _rows.length == 1 ? t.ark.send.destination_placeholder : t.ark.send.bitcoin_address_placeholder,
            isError: problem != null,
          ),
          if (request != null) ...[
            CoconutLayout.spacing_200h,
            Wrap(children: [ArkChip(describePaymentRequest(request, _unit))]),
          ],
          if (problem != null) ...[
            CoconutLayout.spacing_100h,
            Text(problem, style: CoconutTypography.body3_12.setColor(colors.danger)),
          ],
          CoconutLayout.spacing_300h,
          _buildAmount(row, request),
          if (isLast && check.canUseMax) ...[
            CoconutLayout.spacing_200h,
            Align(
              alignment: Alignment.centerLeft,
              child: SendOptionPill(
                label: t.send_screen.input_maximum_amount,
                iconPath: FeatureSettingsIconPath.broom,
                isSelected: row.isMax,
                onPressed: () => _toggleMax(row),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAmount(_RecipientRow row, PaymentRequest? request) {
    final colors = context.coconutColors;
    final unit = GestureDetector(
      onTap: _toggleUnit,
      child: Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Text(_unit.symbol, style: CoconutTypography.heading4_18_Bold.setColor(colors.primaryText)),
      ),
    );
    if (row.isMax) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Text(
          t.ark.send.everything_left,
          style: CoconutTypography.heading4_18_NumberBold.setColor(colors.secondaryText),
        ),
      );
    }
    return CoconutTextField(
      controller: row.amount,
      focusNode: row.amountFocus,
      style: CoconutTextFieldStyle.underline,
      underlineSpacing: CoconutTextFieldUnderlineSpacing.standard,
      backgroundColor: colors.surface,
      fontSize: 18,
      fontFamily: CoconutTypography.kNumberFontFamily,
      letterSpacing: -0.04,
      fontWeight: FontWeight.bold,
      readOnly: row.amountLocked,
      onChanged: (_) {},
      onEditingComplete: () => row.amountFocus.unfocus(),
      textInputAction: TextInputAction.done,
      textInputType: _unit.isBtcUnit ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.number,
      textInputFormatter: [_unit.isBtcUnit ? const BtcAmountInputFormatter() : const SatoshiAmountInputFormatter()],
      placeholderText: t.ark.send.amount_placeholder,
      descriptionText:
          row.amountLocked
              ? (request?.kind == PaymentRequestKind.lightningInvoice
                  ? t.ark.send.set_by_invoice
                  : t.ark.send.set_by_code)
              : null,
      maxLines: 1,
      suffix: unit,
    );
  }

  /// The dashed "Add Recipient" card from the send screen, here always in view.
  Widget _buildAddRecipient() {
    final colors = context.coconutColors;
    return ShrinkAnimationButton(
      onPressed: _addRecipient,
      defaultColor: colors.background,
      pressedOverlayColor: colors.surfacePressOverlay,
      pressedOverlayOpacity: colors.surfacePressOverlayOpacity,
      borderRadius: CoconutStyles.radius_400,
      borderWidth: 0,
      child: CustomPaint(
        painter: DashedBorderPainter(dashSpace: 4.0, dashWidth: 4.0, color: colors.border),
        child: SizedBox(
          height: 56,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SvgPicture.asset(
                CommonActionIconPath.plus,
                colorFilter: ColorFilter.mode(colors.primaryText, BlendMode.srcIn),
              ),
              CoconutLayout.spacing_100w,
              Text(t.send_screen.add_recipient, style: CoconutTypography.body2_14.setColor(colors.primaryText)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAvailable(int arkAvailable) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggleUnit,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          children: [
            ArkInfoRow(label: t.ark.send.available_onchain, value: formatSats(_unit, _onchainAvailableSats)),
            ArkInfoRow(label: t.ark.send.available_ark, value: formatSats(_unit, arkAvailable)),
          ],
        ),
      ),
    );
  }
}
