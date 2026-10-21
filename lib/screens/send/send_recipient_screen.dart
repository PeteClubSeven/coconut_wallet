import 'package:coconut_design_system/coconut_design_system.dart'
    hide
        CoconutAppBar,
        CoconutTextField,
        CoconutToolTip,
        CoconutTooltipType,
        CoconutTooltipState,
        CoconutToast,
        CoconutToastLevel,
        CoconutPopup,
        CoconutUnderlinedButton;
import 'package:coconut_lib/coconut_lib.dart';
import 'package:coconut_wallet/app/router/app_route_names.dart';
import 'package:coconut_wallet/app/router/route_args.dart';
import 'package:coconut_wallet/config/number_format_config.dart';
import 'package:coconut_wallet/constants/app_language.dart';
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
import 'package:coconut_wallet/ui/coconut/coconut_overlays.dart';
import 'package:coconut_wallet/ui/coconut/coconut_text_field.dart';
import 'package:coconut_wallet/ui/coconut/coconut_underlined_button.dart';
import 'package:coconut_wallet/utils/address_scan_util.dart';
import 'package:coconut_wallet/utils/dashed_border_painter.dart';
import 'package:coconut_wallet/utils/numeric_input_formatters.dart';
import 'package:coconut_wallet/utils/payment_request_parser.dart';
import 'package:coconut_wallet/utils/send_amount_text.dart';
import 'package:coconut_wallet/utils/send_recipients.dart';
import 'package:coconut_wallet/widgets/common/buttons/fixed_bottom_button.dart';
import 'package:coconut_wallet/widgets/common/buttons/shrink_animation_button.dart';
import 'package:coconut_wallet/widgets/features/ark/ark_texts.dart';
import 'package:coconut_wallet/widgets/features/ark/ark_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

/// Step 1 of Send for a hot wallet with Ark: who to pay and how much, laid out like Coconut's
/// send screen. Each recipient is a page with the big amount (typed on the system keypad through a
/// hidden field), the "Send All" and "Add recipient" pills and the address field; the last page is
/// the dashed "Add Recipient" card. A destination can be a Bitcoin or Ark address, a Lightning
/// invoice or address, or a BIP321 code, whose amount fills in and locks. Several recipients are
/// paid on-chain in one transaction, so they need Bitcoin addresses. Step 2
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

/// One recipient: its destination field and its amount, a canonical string in the current unit.
class _RecipientRow {
  final TextEditingController destination = TextEditingController();
  final FocusNode destinationFocus = FocusNode();
  String amount = '';
  bool isMax = false;

  /// The amount came from the destination (an invoice or code) and can't be edited.
  bool amountLocked = false;

  void dispose() {
    destination.dispose();
    destinationFocus.dispose();
  }
}

class _SendRecipientScreenState extends State<SendRecipientScreen> {
  static const double _appBarHeight = 60;
  static const double _pageHeight = 226;
  static const double _amountHeight = 34;

  final List<_RecipientRow> _rows = [];
  final PageController _pageController = PageController();
  final TextEditingController _amountController = TextEditingController();
  final FocusNode _amountFocusNode = FocusNode();
  String _previousAmountText = '';
  int _page = 0;
  late final String _walletName;
  late final int _onchainAvailableSats;
  late BitcoinUnit _unit;

  _RecipientRow? get _currentRow => _page < _rows.length ? _rows[_page] : null;

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
    _amountController.addListener(_onAmountKey);
    _amountFocusNode.addListener(() {
      if (mounted) setState(() {});
    });
    final first = _addRow();
    final initial = widget.initialInput?.trim();
    if (initial != null && initial.isNotEmpty) {
      first.destination.text = initial;
      _applyDestination(first);
      final amount = widget.initialAmountSats;
      if (!first.amountLocked && amount != null && amount > 0) first.amount = SendAmountText.fromSats(amount, _unit);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_check().canContinue) {
          _next();
        } else if (first.amountLocked) {
          first.destinationFocus.requestFocus();
        } else {
          _focusAmount();
        }
      });
    }
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    _pageController.dispose();
    _amountController.dispose();
    _amountFocusNode.dispose();
    super.dispose();
  }

  // --- Rows and pages ---

  _RecipientRow _addRow() {
    final row = _RecipientRow();
    for (final other in _rows) {
      other.isMax = false; // Send All is only for the last recipient
    }
    row.destination.addListener(() {
      _applyDestination(row);
      if (mounted) setState(() {});
    });
    _rows.add(row);
    return row;
  }

  void _addRecipient() {
    _clearFocus();
    setState(() => _addRow());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _pageController.animateToPage(
        _rows.length - 1,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  void _deleteCurrent() {
    final row = _currentRow;
    if (row == null || _rows.length < 2) return;
    _clearFocus();
    setState(() {
      _rows.remove(row);
      _page = _page.clamp(0, _rows.length - 1);
    });
    _pageController.jumpToPage(_page);
    WidgetsBinding.instance.addPostFrameCallback((_) => row.dispose());
  }

  void _onPageChanged(int page) {
    _clearFocus();
    setState(() => _page = page);
  }

  /// Fills in and locks the amount when the destination carries one, and unlocks it when it no
  /// longer does.
  void _applyDestination(_RecipientRow row) {
    final text = row.destination.text.trim();
    final fixed = text.isEmpty ? null : PaymentRequest.parse(text, NetworkType.currentNetworkType).amountSats;
    if (fixed != null) {
      row.amount = SendAmountText.fromSats(fixed, _unit);
      row.amountLocked = true;
      row.isMax = false;
    } else if (row.amountLocked) {
      row.amountLocked = false;
      row.amount = '';
    }
  }

  Future<void> _scan(_RecipientRow row) async {
    _clearFocus();
    final scanned = await showAddressScannerBottomSheet(context, title: t.send);
    if (!mounted || scanned == null) return;
    row.destination.text = scanned.trim();
    // A single recipient whose amount is known goes straight on; otherwise the amount is next.
    if (_rows.length == 1 && row.amountLocked && _check().canContinue) {
      _next();
    } else if (!row.amountLocked && row.amount.isEmpty) {
      _focusAmount();
    }
  }

  void _toggleMax(_RecipientRow row) {
    _clearFocus();
    setState(() => row.isMax = !row.isMax);
  }

  // --- Amount, typed on the system keypad through a hidden field (as the send screen) ---

  void _focusAmount() {
    final row = _currentRow;
    if (row == null || row.amountLocked || row.isMax) return;
    _syncAmountField(row.amount);
    _amountFocusNode.requestFocus();
  }

  void _syncAmountField(String amount) {
    final text = amount.replaceAll('.', NumberFormatConfig.instance.decimalSeparator);
    _previousAmountText = text;
    if (_amountController.text != text) _amountController.text = text;
  }

  void _onAmountKey() {
    final row = _currentRow;
    final current = _amountController.text;
    if (row == null || current == _previousAmountText) return;
    final key = resolveAmountKeyInput(_previousAmountText, current);
    if (key != null) {
      row.amount =
          key == '<'
              ? SendAmountText.apply(row.amount, '<', isSats: _unit.isBasedOnSatoshi)
              : SendAmountText.applyAll(row.amount, key, isSats: _unit.isBasedOnSatoshi);
    }
    _syncAmountField(row.amount);
    setState(() {});
  }

  void _toggleUnit() {
    final next = _unit.isBasedOnSatoshi ? BitcoinUnit.btc : BitcoinUnit.sats;
    setState(() {
      for (final row in _rows) {
        final sats = SendAmountText.toSats(row.amount, _unit);
        row.amount = sats == null ? '' : SendAmountText.fromSats(sats, next);
      }
      _unit = next;
    });
    final row = _currentRow;
    if (row != null) _syncAmountField(row.amount);
  }

  void _clearFocus() {
    final row = _currentRow;
    if (row != null && row.amount.endsWith('.')) row.amount = row.amount.substring(0, row.amount.length - 1);
    FocusScope.of(context).unfocus();
  }

  // --- Going on ---

  SendRecipientList _check({int? arkAvailableSats}) => SendRecipientList(
    [
      for (final row in _rows)
        SendRecipientRow(
          row.destination.text,
          enteredAmountSats: SendAmountText.toSats(row.amount, _unit),
          isMax: row.isMax,
        ),
    ],
    network: NetworkType.currentNetworkType,
    onchainAvailableSats: _onchainAvailableSats,
    arkAvailableSats: arkAvailableSats ?? context.read<ArkProvider>().balance(widget.id)?.spendable ?? 0,
  );

  Future<void> _next() async {
    final check = _check();
    if (!check.canContinue) return;
    _clearFocus();
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
    final keyboardHeight = MediaQuery.viewInsetsOf(context).bottom;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: colors.background,
      appBar: _buildAppBar(arkAvailable),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _clearFocus,
        child: Stack(
          children: [
            SingleChildScrollView(
              child: Column(
                children: [
                  _buildInvisibleAmountField(),
                  SizedBox(
                    height: _pageHeight,
                    child: Stack(
                      children: [
                        PageView.builder(
                          controller: _pageController,
                          onPageChanged: _onPageChanged,
                          itemCount: _rows.length + 1,
                          itemBuilder:
                              (context, index) =>
                                  index == _rows.length
                                      ? _buildAddRecipientCard()
                                      : _buildRecipientPage(
                                        index,
                                        check.checks[index],
                                        isLast: index == _rows.length - 1,
                                        exceedsAvailable: check.exceedsAvailable,
                                      ),
                        ),
                        if (_rows.length > 1 && _page < _rows.length) _buildCounter(),
                      ],
                    ),
                  ),
                  Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: _buildTooltips(check)),
                ],
              ),
            ),
            if (_amountFocusNode.hasFocus)
              Positioned(left: 0, right: 0, bottom: keyboardHeight, child: _buildAmountKeyboardToolbar()),
            FixedBottomButton(
              onButtonClicked: _next,
              text: t.next,
              isActive: check.canContinue,
              showSurroundings: false,
              isVisibleAboveKeyboard: false,
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

  /// The send screen's app bar: the wallet name and, in the pill under it, what's available.
  PreferredSizeWidget _buildAppBar(int arkAvailable) {
    final colors = context.coconutColors;
    return CoconutAppBar.build(
      context: context,
      height: _appBarHeight,
      isBottom: true,
      backgroundColor: colors.background,
      customTitle: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_walletName, style: CoconutTypography.body1_16.setColor(colors.primaryText)),
          CoconutLayout.spacing_50h,
          // Both balances must stay readable, so the pill shrinks rather than cut them off.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2.5),
              decoration: BoxDecoration(color: colors.surfaceButton, borderRadius: BorderRadius.circular(4)),
              child: Text(
                // The unit once at the end, unless it's a prefix symbol (BIP-177).
                t.ark.send
                    .available_pill(
                      onchain: _unit.displayBitcoinAmount(_onchainAvailableSats, withUnit: _unit.isPrefixSymbol),
                      ark: _unit.displayBitcoinAmount(arkAvailable, withUnit: _unit.isPrefixSymbol),
                      unit: _unit.isPrefixSymbol ? '' : _unit.symbol,
                    )
                    .trim(),
                style: CoconutTypography.body3_12_Number.setColor(colors.surfaceButtonText),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInvisibleAmountField() {
    return SizedBox(
      width: 0,
      height: 0,
      child: TextField(
        controller: _amountController,
        focusNode: _amountFocusNode,
        showCursor: false,
        enableInteractiveSelection: false,
        keyboardType: TextInputType.numberWithOptions(signed: false, decimal: !_unit.isBasedOnSatoshi),
        inputFormatters: [
          _unit.isBasedOnSatoshi ? FilteringTextInputFormatter.digitsOnly : const BtcAmountInputFormatter(),
        ],
        onEditingComplete: _clearFocus,
      ),
    );
  }

  /// One recipient, as the send screen's recipient page.
  Widget _buildRecipientPage(
    int index,
    SendRecipientCheck check, {
    required bool isLast,
    required bool exceedsAvailable,
  }) {
    final colors = context.coconutColors;
    final row = _rows[index];
    final request = check.request;
    final problem = check.problem == SendRecipientProblem.needsAmount ? null : recipientProblemText(check);
    final String note;
    if (problem != null) {
      note = problem;
    } else if (request == null) {
      note = '';
    } else if (row.amountLocked) {
      final setBy =
          request.kind == PaymentRequestKind.lightningInvoice ? t.ark.send.set_by_invoice : t.ark.send.set_by_code;
      note = '${describePaymentRequest(request, _unit)} · $setBy';
    } else {
      note = describePaymentRequest(request, _unit);
    }
    return Stack(
      children: [
        GestureDetector(
          onTap: () {
            if (MediaQuery.viewInsetsOf(context).bottom > 0) {
              _clearFocus();
            } else {
              _focusAmount();
            }
          },
          child: Container(color: Colors.transparent, width: double.infinity, height: _amountHeight + 80),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 40, left: 16, right: 16),
          child: Column(
            children: [
              IgnorePointer(
                child: SizedBox(
                  height: _amountHeight,
                  child: FittedBox(child: _buildAmount(row, exceedsAvailable: exceedsAvailable)),
                ),
              ),
              CoconutLayout.spacing_200h,
              _buildPills(row, check, isLast: isLast),
              CoconutLayout.spacing_500h,
              CoconutTextField(
                controller: row.destination,
                focusNode: row.destinationFocus,
                backgroundColor: colors.background,
                padding: const EdgeInsets.only(left: 16, right: 0),
                onChanged: (_) {},
                maxLines: 1,
                // Addresses and invoices must come through exactly as typed or pasted.
                autocorrect: false,
                enableSuggestions: false,
                textInputType: TextInputType.visiblePassword,
                clearButtonVisibility: CoconutTextFieldClearButtonVisibility.whenNotEmpty,
                onClear: row.destination.clear,
                suffixIconAsset: CommonActionIconPath.scan,
                suffixIconColor: colors.primaryText,
                suffixIconSize: 18,
                onSuffixPressed: () => _scan(row),
                placeholderText:
                    _rows.length == 1 ? t.ark.send.destination_placeholder : t.send_screen.address_placeholder,
                isError: problem != null,
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          note,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: CoconutTypography.body3_12.setColor(
                            problem != null ? colors.danger : colors.secondaryText,
                          ),
                        ),
                      ),
                      if (_rows.length > 1)
                        CoconutUnderlinedButton(
                          text: t.send_screen.delete,
                          textStyle: CoconutTypography.body3_12.setColor(colors.secondaryText),
                          padding: EdgeInsets.zero,
                          onTap: _deleteCurrent,
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// The big amount, coloured as on the send screen.
  Widget _buildAmount(_RecipientRow row, {required bool exceedsAvailable}) {
    final colors = context.coconutColors;
    if (row.isMax) {
      return Text(
        t.ark.send.everything_left,
        style: CoconutTypography.heading2_28_NumberBold.setColor(colors.secondaryText),
      );
    }
    final Color color;
    if (row.amount.isEmpty) {
      color = colors.inputPlaceholder;
    } else if (exceedsAvailable) {
      color = colors.danger;
    } else {
      color = colors.primaryText;
    }
    final number = row.amount.isEmpty ? '0' : row.amount.toBtcDisplayString();
    final numberText = Text(number, style: CoconutTypography.heading2_28_NumberBold.setColor(color));
    final unitText = Text(_unit.symbol, style: CoconutTypography.heading4_18_Number.setColor(color));
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: _unit.isPrefixSymbol ? CrossAxisAlignment.center : CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children:
          _unit.isPrefixSymbol
              ? [unitText, CoconutLayout.spacing_100w, numberText]
              : [numberText, CoconutLayout.spacing_100w, unitText],
    );
  }

  /// "Send All" (the last recipient, on-chain) and "Add recipient", as the send screen's pills.
  Widget _buildPills(_RecipientRow row, SendRecipientCheck check, {required bool isLast}) {
    final language = AppLanguage.fromCode(context.read<PreferenceProvider>().language);
    final sendAll = t.send_screen.input_maximum_amount;
    final sendAllText =
        row.isMax ? (language.hasEnglishWordOrder ? '${t.cancel} $sendAll' : '$sendAll ${t.cancel}') : sendAll;
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.0)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (isLast && check.canUseMax) ...[
            SendOptionPill(
              label: sendAllText,
              iconPath: FeatureSettingsIconPath.broom,
              onPressed: () => _toggleMax(row),
            ),
            CoconutLayout.spacing_200w,
          ],
          SendOptionPill(
            label: t.send_screen.add_recipient,
            iconPath: CommonActionIconPath.plus,
            onPressed: _addRecipient,
          ),
        ],
      ),
    );
  }

  Widget _buildCounter() {
    final colors = context.coconutColors;
    return Positioned(
      left: 16,
      top: 8,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), color: colors.surfaceInfoChip),
        child: Row(
          children: [
            Text('${_page + 1} ', style: CoconutTypography.body3_12.setColor(colors.primaryText)),
            Text('/ ${_rows.length}', style: CoconutTypography.body3_12.setColor(colors.secondaryText)),
          ],
        ),
      ),
    );
  }

  /// The send screen's dashed "Add Recipient" card, the last page.
  Widget _buildAddRecipientCard() {
    final colors = context.coconutColors;
    return Padding(
      padding: const EdgeInsets.only(top: 40, left: 16, right: 16, bottom: 25),
      child: ShrinkAnimationButton(
        defaultColor: colors.surface,
        onPressed: _addRecipient,
        child: CustomPaint(
          painter: DashedBorderPainter(dashSpace: 4.0, dashWidth: 4.0, color: colors.border),
          child: SizedBox.expand(
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
      ),
    );
  }

  /// The send screen's tooltips under the recipients: the batch total, and Send All.
  Widget _buildTooltips(SendRecipientList check) {
    final total = check.recipients.fold<int>(0, (sum, recipient) => sum + (recipient.amountSats ?? 0));
    return Column(
      children: [
        CoconutLayout.spacing_300h,
        if (check.recipients.length > 1) ...[
          _buildTooltip(
            iconPath: FeatureTransactionIconPath.receipt,
            text: t.send_screen.tooltip_text(
              count: check.recipients.length,
              amount: _unit.displayBitcoinAmount(total, withUnit: true),
            ),
          ),
          const SizedBox(height: 5),
        ],
        if (check.maxLast)
          _buildTooltip(iconPath: FeatureSettingsIconPath.broom, text: t.send_screen.tooltip_max_mode_text),
      ],
    );
  }

  Widget _buildTooltip({required String iconPath, required String text}) {
    final colors = context.coconutColors;
    return CoconutToolTip(
      backgroundColor: colors.surface,
      borderColor: colors.surface,
      borderRadius: 12,
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      icon: Transform.translate(
        offset: const Offset(0, 3),
        child: SvgPicture.asset(iconPath, colorFilter: ColorFilter.mode(colors.secondaryText, BlendMode.srcIn)),
      ),
      tooltipType: CoconutTooltipType.fixed,
      richText: RichText(
        text: TextSpan(text: text, style: CoconutTypography.body2_14_Bold.setColor(colors.secondaryText)),
      ),
    );
  }

  /// The send screen's bar on the keypad: the unit, tap to switch.
  Widget _buildAmountKeyboardToolbar() {
    final colors = context.coconutColors;
    return GestureDetector(
      onTap: () {},
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
        color: colors.surface,
        child: Row(
          children: [
            const Spacer(),
            GestureDetector(
              onTap: _toggleUnit,
              child: Container(
                color: Colors.transparent,
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
                child: Row(
                  children: [
                    SvgPicture.asset(
                      CommonActionIconPath.check,
                      width: 10,
                      height: 10,
                      colorFilter: ColorFilter.mode(colors.primaryText, BlendMode.srcIn),
                    ),
                    CoconutLayout.spacing_200w,
                    Text(_unit.symbol, style: CoconutTypography.body2_14.setColor(colors.primaryText)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
