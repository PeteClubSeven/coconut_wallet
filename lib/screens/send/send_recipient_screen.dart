import 'package:coconut_design_system/coconut_design_system.dart' hide CoconutAppBar;
import 'package:coconut_lib/coconut_lib.dart';
import 'package:coconut_wallet/app/router/app_route_names.dart';
import 'package:coconut_wallet/app/router/route_args.dart';
import 'package:coconut_wallet/design_system/context/coconut_theme_context_extension.dart';
import 'package:coconut_wallet/enums/fiat_enums.dart';
import 'package:coconut_wallet/localization/strings.g.dart';
import 'package:coconut_wallet/providers/preferences/preference_provider.dart';
import 'package:coconut_wallet/providers/send_info_provider.dart';
import 'package:coconut_wallet/providers/wallet_provider.dart';
import 'package:coconut_wallet/screens/send/payment_request_labels.dart';
import 'package:coconut_wallet/ui/coconut/coconut_app_bar.dart';
import 'package:coconut_wallet/utils/address_scan_util.dart';
import 'package:coconut_wallet/utils/payment_request_parser.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

/// Step 1 of Send for a hot wallet with Ark: who to pay. Takes a Bitcoin address, an Ark address,
/// a Lightning invoice or address, or a BIP321 code, says what it is, and goes on to the ways to
/// pay it ([AppRouteNames.sendOptions]). Strings are not localized yet (proof of concept).
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
  /// screen); a payable one goes straight on to the next step.
  final String? initialInput;

  /// An amount already entered for it (handed back by the on-chain send screen).
  final int? initialAmountSats;

  @override
  State<SendRecipientScreen> createState() => _SendRecipientScreenState();
}

class _SendRecipientScreenState extends State<SendRecipientScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  late final String _walletName;
  PaymentRequest? _request;

  @override
  void initState() {
    super.initState();
    _walletName = context.read<WalletProvider>().getWalletById(widget.id).name;
    final initial = widget.initialInput;
    if (initial != null && initial.trim().isNotEmpty) {
      _controller.text = initial.trim();
      _request = PaymentRequest.parse(_controller.text, NetworkType.currentNetworkType);
      WidgetsBinding.instance.addPostFrameCallback((_) => _nextIfPayable(amountSats: widget.initialAmountSats));
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
    _controller.addListener(_parse);
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _parse() {
    final text = _controller.text;
    final request = text.trim().isEmpty ? null : PaymentRequest.parse(text, NetworkType.currentNetworkType);
    if (request?.raw == _request?.raw && (request == null) == (_request == null)) return;
    setState(() => _request = request);
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (!mounted || text == null || text.trim().isEmpty) return;
    _controller.text = text.trim();
    _nextIfPayable();
  }

  Future<void> _scan() async {
    _focusNode.unfocus();
    final scanned = await showAddressScannerBottomSheet(context, title: t.send);
    if (!mounted || scanned == null) return;
    _controller.text = scanned.trim();
    _nextIfPayable();
  }

  void _nextIfPayable({int? amountSats}) {
    final request = _request;
    if (mounted && request != null && isPayable(request)) _next(amountSats: amountSats);
  }

  Future<void> _next({int? amountSats}) async {
    _focusNode.unfocus();
    await Navigator.pushNamed(
      context,
      AppRouteNames.sendOptions,
      arguments: SendOptionsRouteArgs(
        id: widget.id,
        input: _controller.text.trim(),
        sendEntryPoint: widget.sendEntryPoint,
        initialAmountSats: amountSats,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final unit = context.select<PreferenceProvider, BitcoinUnit>((provider) => provider.currentUnit);
    final colors = context.coconutColors;
    final request = _request;
    final payable = request != null && isPayable(request);
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
            Text('Who are you paying?', style: CoconutTypography.body2_14_Bold.setColor(colors.primaryText)),
            CoconutLayout.spacing_200h,
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
                      controller: _controller,
                      focusNode: _focusNode,
                      // Addresses and invoices must come through exactly as typed or pasted.
                      autocorrect: false,
                      enableSuggestions: false,
                      keyboardType: TextInputType.visiblePassword,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _nextIfPayable(),
                      maxLines: 4,
                      minLines: 1,
                      style: CoconutTypography.body2_14.setColor(colors.primaryText),
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        hintText: 'Bitcoin or Ark address, Lightning invoice or address, or payment code',
                        hintMaxLines: 2,
                        hintStyle: CoconutTypography.body2_14.setColor(colors.tertiaryText),
                      ),
                    ),
                  ),
                  IconButton(onPressed: _paste, icon: Icon(Icons.content_paste, color: colors.iconPrimary, size: 20)),
                  IconButton(onPressed: _scan, icon: Icon(Icons.qr_code_scanner, color: colors.iconPrimary, size: 20)),
                ],
              ),
            ),
            if (request != null) ...[
              CoconutLayout.spacing_300h,
              Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: colors.surfaceMuted,
                    borderRadius: BorderRadius.circular(CoconutStyles.radius_100),
                  ),
                  child: Text(
                    describePaymentRequest(request, unit),
                    style: CoconutTypography.body3_12.setColor(colors.primaryText),
                  ),
                ),
              ),
              if (!payable && request.problem != null) ...[
                CoconutLayout.spacing_200h,
                Text(request.problem!, style: CoconutTypography.body3_12.setColor(colors.danger)),
              ],
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
              isActive: payable,
              onPressed: payable ? () => _next() : () {},
              height: 52,
              backgroundColor: colors.primary,
              foregroundColor: colors.background,
            ),
          ),
        ),
      ),
    );
  }
}
