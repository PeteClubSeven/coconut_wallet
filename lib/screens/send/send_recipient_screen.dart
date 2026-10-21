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
import 'package:coconut_wallet/constants/lottie_path.dart';
import 'package:coconut_wallet/design_system/context/coconut_theme_context_extension.dart';
import 'package:coconut_wallet/enums/fiat_enums.dart';
import 'package:coconut_wallet/extensions/string_extensions.dart';
import 'package:coconut_wallet/localization/strings.g.dart';
import 'package:coconut_wallet/model/ark/ark_board.dart';
import 'package:coconut_wallet/model/ark/move.dart';
import 'package:coconut_wallet/model/utxo/utxo_state.dart';
import 'package:coconut_wallet/providers/ark_provider.dart';
import 'package:coconut_wallet/providers/preferences/preference_provider.dart';
import 'package:coconut_wallet/providers/send_info_provider.dart';
import 'package:coconut_wallet/providers/wallet_provider.dart';
import 'package:coconut_wallet/screens/ark/ark_unlock_flow.dart';
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
import 'package:lottie/lottie.dart';
import 'package:provider/provider.dart';

/// Step 1 of Send for a hot wallet with Ark, and of every Move: who to pay and how much, laid out
/// like Coconut's send screen. Each recipient is a page with the big amount (typed on the system
/// keypad through a hidden field) and the address field; swiping left reaches the dashed "Add
/// Recipient" card, as on the send screen. Under the pages, the balance boxes fill the amount with
/// everything in that balance. A destination can be a Bitcoin or Ark address, a Lightning invoice
/// or address, or a BIP321 code, whose amount fills in and locks. Several recipients are paid
/// on-chain in one transaction, so they need Bitcoin addresses.
///
/// For a move ([move]) the first recipient is the destination, shown as a card instead of the
/// field, and only the source's balance pays; more recipients can follow unless the source is Ark
/// (Ark pays one destination). Step 2 ([AppRouteNames.sendOptions]) chooses how to pay.
class SendRecipientScreen extends StatefulWidget {
  const SendRecipientScreen({
    super.key,
    required this.id,
    required this.sendEntryPoint,
    this.initialInput,
    this.initialAmountSats,
    this.move,
  });

  /// The paying wallet: for a move, the source's (a vault, or the hot wallet).
  final int id;
  final SendEntryPoint sendEntryPoint;

  /// A payment request to start with (a deep link, or one handed back by the on-chain send
  /// screen); with its amount known it goes straight on to step 2.
  final String? initialInput;

  /// An amount already entered for it (handed back by the on-chain send screen).
  final int? initialAmountSats;

  final MoveSelection? move;

  @override
  State<SendRecipientScreen> createState() => _SendRecipientScreenState();
}

/// One recipient: its destination field and its amount, a canonical string in the current unit.
class _RecipientRow {
  final TextEditingController destination = TextEditingController();
  final FocusNode destinationFocus = FocusNode();
  String amount = '';

  /// Everything in this balance, picked with its balance box.
  SendMaxSource? maxSource;

  /// The amount came from the destination (an invoice or code) and can't be edited.
  bool amountLocked = false;

  void dispose() {
    destination.dispose();
    destinationFocus.dispose();
  }
}

class _SendRecipientScreenState extends State<SendRecipientScreen> {
  static const double _pageHeight = 232;
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

  /// The send screen's first-run hint for the hidden "Add Recipient" card.
  bool _isSwipeGuideVisible = false;

  /// A move's destination, once its address is known (a board needs the Ark wallet first).
  MoveDestination? _moveDestination;

  _RecipientRow? get _currentRow => _page < _rows.length ? _rows[_page] : null;

  bool get _isMove => widget.move != null;

  SendFunding get _funding => switch (widget.move?.from.kind) {
    null => SendFunding.any,
    MoveEndpointKind.ark => SendFunding.ark,
    MoveEndpointKind.onchain || MoveEndpointKind.vault => SendFunding.onchain,
  };

  /// Ark pays one destination, so a move out of Ark has no more recipients.
  bool get _canAddRecipients => _funding != SendFunding.ark;

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
    if (_isMove) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _resolveMove(first));
    } else {
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
    if (_canAddRecipients && !context.read<PreferenceProvider>().hasSeenAddRecipientCard) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await Future.delayed(const Duration(milliseconds: 300));
        if (mounted) setState(() => _isSwipeGuideVisible = true);
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

  // --- A move's destination ---

  /// Finds where the move pays: the destination's next receive address, or for a board into Ark
  /// its funding address (the Ark wallet opens for that). Leaves the screen if that fails.
  Future<void> _resolveMove(_RecipientRow first) async {
    final move = widget.move!;
    final MoveDestination destination;
    try {
      if (move.to.kind == MoveEndpointKind.ark) {
        final arkProvider = context.read<ArkProvider>();
        if (!await openArkWalletForSession(context, move.to.walletId, userInitiated: true)) {
          if (mounted) Navigator.pop(context);
          return;
        }
        final funding = await arkProvider.boardFunding(move.to.walletId);
        final terms = await arkProvider.boardTerms(move.to.walletId);
        destination = MoveDestination(
          address: funding.address,
          board: ArkBoardIntent(walletId: move.to.walletId, funding: funding),
          boardTerms: terms,
        );
      } else {
        final address = context.read<WalletProvider>().getReceiveAddress(move.to.walletId).address;
        destination = MoveDestination(address: address);
      }
    } catch (error) {
      if (!mounted) return;
      await showArkError(context, t.ark.move.prepare_failed, '$error');
      if (mounted) Navigator.pop(context);
      return;
    }
    if (!mounted) return;
    setState(() {
      _moveDestination = destination;
      first.destination.text = destination.address;
    });
    _focusAmount();
  }

  // --- Rows and pages ---

  _RecipientRow _addRow() {
    final row = _RecipientRow();
    for (final other in _rows) {
      if (other.maxSource == SendMaxSource.onchain) other.maxSource = null; // only the last takes the rest
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
    if (row == null || _rows.length < 2 || (_isMove && row == _rows.first)) return;
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
    if (page == _rows.length) context.read<PreferenceProvider>().setHasSeenAddRecipientCard();
    setState(() => _page = page);
  }

  void _hideSwipeGuide() {
    if (_isSwipeGuideVisible) setState(() => _isSwipeGuideVisible = false);
  }

  /// Fills in and locks the amount when the destination carries one, and unlocks it when it no
  /// longer does.
  void _applyDestination(_RecipientRow row) {
    final text = row.destination.text.trim();
    final fixed = text.isEmpty ? null : PaymentRequest.parse(text, NetworkType.currentNetworkType).amountSats;
    if (fixed != null) {
      row.amount = SendAmountText.fromSats(fixed, _unit);
      row.amountLocked = true;
      row.maxSource = null;
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

  // --- Send All: everything in one balance ---

  /// Whether row [index] may take everything in [source] (its Send All pill is enabled).
  bool _canUseMax(int index, SendMaxSource source, SendRecipientCheck check, {required int arkAvailable}) {
    if (_rows[index].amountLocked) return false;
    final request = check.request;
    switch (source) {
      case SendMaxSource.onchain:
        if (_funding == SendFunding.ark || _onchainAvailableSats <= 0) return false;
        // On-chain coins pay Bitcoin addresses only, and everything left goes to the last row.
        if (request != null && request.bitcoinAddress == null) return false;
        return index == _rows.length - 1;
      case SendMaxSource.ark:
        if (_funding == SendFunding.onchain || arkAvailable <= 0 || _rows.length > 1) return false;
        if (!_isMove && !context.read<ArkProvider>().supportsArkById(widget.id)) return false;
        return request == null || request.bitcoinAddress != null || request.arkAddress != null;
    }
  }

  /// Send All on [source], or cancels it; the other Send All switches straight over.
  void _toggleMax(int index, SendMaxSource source) {
    final row = _rows[index];
    _clearFocus();
    setState(() {
      if (row.maxSource == source) {
        row.maxSource = null;
        row.amount = '';
      } else {
        row.maxSource = source;
      }
    });
  }

  /// What a row taking everything shows: the balance, less the other rows on-chain. The fee comes
  /// out of it on step 2.
  int _maxAmountSats(_RecipientRow row, {required int arkAvailable}) {
    if (row.maxSource == SendMaxSource.ark) return arkAvailable;
    var others = 0;
    for (final other in _rows) {
      if (other != row) others += SendAmountText.toSats(other.amount, _unit) ?? 0;
    }
    return (_onchainAvailableSats - others).clamp(0, _onchainAvailableSats);
  }

  // --- Amount, typed on the system keypad through a hidden field (as the send screen) ---

  void _focusAmount() {
    final row = _currentRow;
    if (row == null || row.amountLocked) return;
    if (row.maxSource != null) {
      // Typing replaces "everything" with an amount.
      setState(() {
        row.maxSource = null;
        row.amount = '';
      });
    }
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
          maxSource: row.maxSource,
        ),
    ],
    network: NetworkType.currentNetworkType,
    onchainAvailableSats: _onchainAvailableSats,
    arkAvailableSats: arkAvailableSats ?? _arkAvailable(context.read<ArkProvider>()),
    funding: _funding,
  );

  /// The Ark balance that can pay: the source's for a move out of Ark, else this wallet's.
  int _arkAvailable(ArkProvider ark) => ark.balance(widget.move?.from.walletId ?? widget.id)?.spendable ?? 0;

  Future<void> _next() async {
    final check = _check();
    if (!check.canContinue || (_isMove && _moveDestination == null)) return;
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
        maxFromArk: check.maxFromArk,
        sendEntryPoint: widget.sendEntryPoint,
        move: widget.move,
        moveDestination: _moveDestination,
      ),
    );
  }

  // --- Layout ---

  @override
  Widget build(BuildContext context) {
    final colors = context.coconutColors;
    final arkAvailable = context.select<ArkProvider, int>(_arkAvailable);
    final check = _check(arkAvailableSats: arkAvailable);
    final keyboardHeight = MediaQuery.viewInsetsOf(context).bottom;
    final pageCount = _rows.length + (_canAddRecipients ? 1 : 0);
    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: colors.background,
      appBar: _buildAppBar(),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _clearFocus,
        child: Stack(
          children: [
            SingleChildScrollView(
              child: Column(
                children: [
                  _buildInvisibleAmountField(),
                  Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: (_) => _hideSwipeGuide(),
                    onPointerMove: (_) => _hideSwipeGuide(),
                    child: SizedBox(
                      height: _pageHeight,
                      child: Stack(
                        children: [
                          PageView.builder(
                            controller: _pageController,
                            onPageChanged: _onPageChanged,
                            itemCount: pageCount,
                            itemBuilder:
                                (context, index) =>
                                    index == _rows.length
                                        ? _buildAddRecipientCard()
                                        : _buildRecipientPage(
                                          index,
                                          check.checks[index],
                                          exceedsAvailable: check.exceedsAvailable,
                                          arkAvailable: arkAvailable,
                                        ),
                          ),
                          if (_rows.length > 1 && _page < _rows.length) _buildCounter(),
                          _buildSwipeGuide(),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      children: [if (_isMove) _buildSourceBalance(arkAvailable: arkAvailable), _buildTooltips(check)],
                    ),
                  ),
                ],
              ),
            ),
            // Only over the keypad: Back can close it while the amount keeps its focus.
            if (_amountFocusNode.hasFocus && keyboardHeight > 0)
              Positioned(left: 0, right: 0, bottom: keyboardHeight, child: _buildAmountKeyboardToolbar()),
            FixedBottomButton(
              onButtonClicked: _next,
              text: t.next,
              isActive: check.canContinue && (!_isMove || _moveDestination != null),
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

  /// The send screen's app bar with the wallet name; for a move, where it goes.
  PreferredSizeWidget _buildAppBar() {
    final move = widget.move;
    return CoconutAppBar.build(
      context: context,
      title: move == null ? _walletName : t.ark.move.screen_title(destination: moveEndpointText(move.to)),
      isBottom: true,
      backgroundColor: context.coconutColors.background,
    );
  }

  /// A move's source balance, under its destination, so it's clear how much can move. (A send
  /// shows none: its Send All pills fill the amount with a balance.)
  Widget _buildSourceBalance({required int arkAvailable}) {
    final isOffchain = _funding == SendFunding.ark;
    return Row(
      children: [
        Expanded(
          child: ArkBalanceBox(
            label: isOffchain ? t.ark.send.available_offchain : t.ark.send.available_onchain,
            amount: _unit.displayBitcoinAmount(isOffchain ? arkAvailable : _onchainAvailableSats, withUnit: true),
          ),
        ),
      ],
    );
  }

  /// The send screen's "Send All" pill, one per balance, on the last recipient as upstream: it
  /// fills the amount with that balance and becomes "Cancel …". A move offers only its source's.
  Widget _buildSendAllPills(int index, SendRecipientCheck check, {required int arkAvailable}) {
    final row = _rows[index];
    final isLast = index == _rows.length - 1;
    final hasEnglishWordOrder = AppLanguage.fromCode(context.read<PreferenceProvider>().language).hasEnglishWordOrder;
    Widget pill(SendMaxSource source, String text) => SendOptionPill(
      iconPath: FeatureSettingsIconPath.broom,
      label:
          row.maxSource != source
              ? text
              : hasEnglishWordOrder
              ? '${t.cancel} $text'
              : '$text ${t.cancel}',
      isEnabled: _canUseMax(index, source, check, arkAvailable: arkAvailable),
      onPressed: () => _toggleMax(index, source),
    );
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.0)),
      child: IgnorePointer(
        ignoring: !isLast,
        child: Opacity(
          opacity: isLast ? 1 : 0,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_funding != SendFunding.ark) pill(SendMaxSource.onchain, t.ark.send.send_all_onchain),
              if (_funding == SendFunding.any) CoconutLayout.spacing_200w,
              if (_funding != SendFunding.onchain) pill(SendMaxSource.ark, t.ark.send.send_all_offchain),
            ],
          ),
        ),
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

  /// One recipient, as the send screen's recipient page; a move's destination is a fixed card.
  Widget _buildRecipientPage(
    int index,
    SendRecipientCheck check, {
    required bool exceedsAvailable,
    required int arkAvailable,
  }) {
    final row = _rows[index];
    final isMoveDestination = _isMove && index == 0;
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
          child: Container(color: Colors.transparent, width: double.infinity, height: _amountHeight + 60),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 40, left: 16, right: 16),
          child: Column(
            children: [
              IgnorePointer(
                child: SizedBox(
                  height: _amountHeight,
                  child: FittedBox(
                    child: _buildAmount(row, exceedsAvailable: exceedsAvailable, arkAvailable: arkAvailable),
                  ),
                ),
              ),
              CoconutLayout.spacing_200h,
              _buildSendAllPills(index, check, arkAvailable: arkAvailable),
              CoconutLayout.spacing_500h,
              if (isMoveDestination) _buildMoveDestination() else ..._buildDestinationField(row, check),
            ],
          ),
        ),
      ],
    );
  }

  /// The address field and the note under it (what the destination is, or what's wrong).
  List<Widget> _buildDestinationField(_RecipientRow row, SendRecipientCheck check) {
    final colors = context.coconutColors;
    final request = check.request;
    final problem = check.problem == SendRecipientProblem.needsAmount ? null : recipientProblemText(check);
    final note = problem ?? (request == null ? '' : describePaymentRequest(request, _unit));
    return [
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
            _rows.length == 1 && !_isMove ? t.ark.send.destination_placeholder : t.send_screen.address_placeholder,
        isError: problem != null,
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
        child: Row(
          children: [
            Expanded(
              child: Text(
                note,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: CoconutTypography.body3_12.setColor(problem != null ? colors.danger : colors.secondaryText),
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
    ];
  }

  /// A move's destination, as step 2's recipient card but fixed (no edit).
  Widget _buildMoveDestination() {
    final colors = context.coconutColors;
    final destination = _moveDestination;
    return ArkCard(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(t.ark.move.to, style: CoconutTypography.body3_12_Bold.setColor(colors.primaryText)),
              CoconutLayout.spacing_200w,
              ArkChip(moveEndpointText(widget.move!.to)),
            ],
          ),
          CoconutLayout.spacing_200h,
          Text(
            destination == null ? t.ark.move.preparing : shortenMiddle(destination.address, head: 18, tail: 14),
            style: CoconutTypography.body2_14_Number.setColor(colors.secondaryText),
          ),
        ],
      ),
    );
  }

  /// The big amount, coloured as on the send screen.
  Widget _buildAmount(_RecipientRow row, {required bool exceedsAvailable, required int arkAvailable}) {
    final colors = context.coconutColors;
    final maxSats = row.maxSource == null ? null : _maxAmountSats(row, arkAvailable: arkAvailable);
    final amount = maxSats != null ? SendAmountText.fromSats(maxSats, _unit) : row.amount;
    final Color color;
    if (amount.isEmpty) {
      color = colors.inputPlaceholder;
    } else if (exceedsAvailable) {
      color = colors.danger;
    } else {
      color = colors.primaryText;
    }
    final number = amount.isEmpty ? '0' : amount.toBtcDisplayString();
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

  /// The send screen's first-run hint: a hand swiping left to the "Add Recipient" card.
  Widget _buildSwipeGuide() {
    final colors = context.coconutColors;
    return AnimatedOpacity(
      opacity: _isSwipeGuideVisible ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 500),
      child: IgnorePointer(
        child: Container(
          height: _pageHeight,
          width: double.infinity,
          color: colors.background.withValues(alpha: 0.6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Lottie.asset(
                CommonLottiePath.swipeLeft,
                width: 60,
                height: 60,
                delegates: LottieDelegates(
                  values: [
                    ValueDelegate.colorFilter(['**'], value: ColorFilter.mode(colors.primaryText, BlendMode.srcATop)),
                  ],
                ),
              ),
              CoconutLayout.spacing_200h,
              Text(
                t.send_screen.swipe_to_add_address,
                textAlign: TextAlign.center,
                style: CoconutTypography.body2_14.setColor(colors.primaryText),
              ),
            ],
          ),
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

  /// The send screen's tooltips under the recipients: the batch total, and sending everything.
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
        if (check.maxLast || check.maxFromArk)
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
