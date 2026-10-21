import 'package:coconut_design_system/coconut_design_system.dart' hide CoconutAppBar;
import 'package:coconut_wallet/design_system/context/coconut_theme_context_extension.dart';
import 'package:coconut_wallet/model/ark/ark_snapshot.dart';
import 'package:coconut_wallet/providers/ark_provider.dart';
import 'package:coconut_wallet/providers/wallet_provider.dart';
import 'package:coconut_wallet/screens/ark/ark_unlock_flow.dart';
import 'package:coconut_wallet/ui/coconut/coconut_app_bar.dart';
import 'package:coconut_wallet/utils/clipboard_copy_util.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Proof-of-concept screen for a hot wallet's Ark (bark) wallet. Strings are not localized yet.
class ArkWalletScreen extends StatefulWidget {
  const ArkWalletScreen({super.key, required this.id});

  final int id;

  @override
  State<ArkWalletScreen> createState() => _ArkWalletScreenState();
}

class _ArkWalletScreenState extends State<ArkWalletScreen> {
  Future<void> _unlockAndOpen() => openArkWalletForSession(context, widget.id, userInitiated: true);

  Future<void> _unlockAndRetryRecovery() async {
    final wallet = context.read<WalletProvider>().getWalletById(widget.id);
    final arkProvider = context.read<ArkProvider>();
    final seedHex = await unlockArkSeed(context, wallet);
    if (seedHex == null) return;
    await arkProvider.retryRecovery(widget.id, seedHex);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ArkProvider>(
      builder: (context, arkProvider, _) {
        final walletName = context.read<WalletProvider>().getWalletById(widget.id).name;
        final error = arkProvider.syncError(widget.id);
        return Scaffold(
          backgroundColor: context.coconutColors.background,
          appBar: CoconutAppBar.build(
            context: context,
            title: 'Ark',
            backgroundColor: context.coconutColors.background,
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(walletName, style: CoconutTypography.body2_14.setColor(context.coconutColors.secondaryText)),
                CoconutLayout.spacing_300h,
                ..._buildBody(arkProvider),
                if (error != null) ...[
                  CoconutLayout.spacing_400h,
                  Text(error, style: CoconutTypography.body3_12.setColor(context.coconutColors.danger)),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  List<Widget> _buildBody(ArkProvider arkProvider) {
    final isOpen = arkProvider.isOpen(widget.id);
    final isBusy = arkProvider.isOpening(widget.id) || arkProvider.isSyncing(widget.id);
    final snapshot = arkProvider.snapshot(widget.id);
    return [
      if (!isOpen) ...[
        _text('Unlock this hot wallet to open its Ark wallet. Until then this shows the last synced data.'),
        CoconutLayout.spacing_400h,
        _button('Unlock Ark wallet', isBusy ? null : _unlockAndOpen),
        CoconutLayout.spacing_500h,
      ],
      if (snapshot == null)
        _text(isOpen ? 'Syncing…' : 'Nothing synced yet.')
      else
        ..._buildSnapshot(snapshot, canRetryRecovery: isOpen && !isBusy && snapshot.canRetryRecovery),
      if (isOpen) ...[
        CoconutLayout.spacing_500h,
        _button(isBusy ? 'Syncing…' : 'Sync', isBusy ? null : () => arkProvider.syncNow(widget.id)),
      ],
    ];
  }

  List<Widget> _buildSnapshot(ArkSnapshot snapshot, {required bool canRetryRecovery}) {
    final balance = snapshot.balance;
    final address = snapshot.address;
    return [
      _section('Balance'),
      Text(
        '${balance.spendable} sats',
        style: CoconutTypography.heading3_21_NumberBold.setColor(context.coconutColors.primaryText),
      ),
      CoconutLayout.spacing_200h,
      _row('Pending in round', balance.pendingInRound),
      _row('Pending board', balance.pendingBoard),
      _row('Pending exit', balance.pendingExit),
      _row('Pending Lightning send', balance.pendingLightningSend),
      _row('Claimable Lightning receive', balance.claimableLightningReceive),
      CoconutLayout.spacing_500h,
      _section('Recovery'),
      _text(snapshot.recovery.description),
      if (canRetryRecovery) ...[CoconutLayout.spacing_200h, _button('Retry recovery', _unlockAndRetryRecovery)],
      CoconutLayout.spacing_500h,
      _section('Ark address'),
      if (address != null) ...[
        Center(
          child: QrImageView(
            data: address,
            size: 220,
            padding: const EdgeInsets.all(12),
            backgroundColor: CoconutColors.white,
          ),
        ),
        CoconutLayout.spacing_300h,
        SelectableText(address, style: CoconutTypography.body3_12_Number.setColor(context.coconutColors.primaryText)),
        CoconutLayout.spacing_200h,
        _button(
          'Copy address',
          () => ClipboardCopyUtil.copyWithToast(context, text: address, toastMessage: 'Ark address copied'),
        ),
      ],
    ];
  }

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(title, style: CoconutTypography.body2_14_Bold.setColor(context.coconutColors.primaryText)),
  );

  Widget _text(String text) =>
      Text(text, style: CoconutTypography.body2_14.setColor(context.coconutColors.primaryText));

  Widget _row(String label, int sats) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Expanded(child: Text(label, style: CoconutTypography.body3_12.setColor(context.coconutColors.secondaryText))),
        Text('$sats sats', style: CoconutTypography.body3_12_Number.setColor(context.coconutColors.primaryText)),
      ],
    ),
  );

  Widget _button(String text, VoidCallback? onPressed) => CoconutButton(
    text: text,
    isActive: onPressed != null,
    onPressed: onPressed ?? () {},
    height: 48,
    backgroundColor: context.coconutColors.surfaceButton,
    foregroundColor: context.coconutColors.surfaceButtonText,
  );
}
