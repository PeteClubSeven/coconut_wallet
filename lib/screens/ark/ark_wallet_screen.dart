import 'package:bark_bitcoin/bark_bitcoin.dart' as bark;
import 'package:coconut_design_system/coconut_design_system.dart' hide CoconutAppBar;
import 'package:coconut_wallet/app/router/app_route_names.dart';
import 'package:coconut_wallet/app_guard.dart';
import 'package:coconut_wallet/design_system/context/coconut_theme_context_extension.dart';
import 'package:coconut_wallet/model/wallet/hot_wallet_secret.dart';
import 'package:coconut_wallet/providers/auth_provider.dart';
import 'package:coconut_wallet/providers/view_model/ark/ark_wallet_view_model.dart';
import 'package:coconut_wallet/providers/wallet_provider.dart';
import 'package:coconut_wallet/repository/secure_storage/hot_wallet_secret_repository.dart';
import 'package:coconut_wallet/screens/common/flutter_hot_wallet_authenticator.dart';
import 'package:coconut_wallet/screens/send/hot_wallet_passphrase_input_sheet.dart';
import 'package:coconut_wallet/services/ark/ark_wallet_service.dart';
import 'package:coconut_wallet/services/security/hot_wallet_unlock_service.dart';
import 'package:coconut_wallet/ui/coconut/coconut_app_bar.dart';
import 'package:coconut_wallet/utils/clipboard_copy_util.dart';
import 'package:coconut_wallet/utils/nfkd_util.dart';
import 'package:coconut_wallet/widgets/common/overlays/common_bottom_sheets.dart';
import 'package:flutter/foundation.dart';
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
  late final ArkWalletViewModel _viewModel;

  @override
  void initState() {
    super.initState();
    _viewModel = ArkWalletViewModel(context.read<WalletProvider>(), widget.id);
    _viewModel.initialize();
  }

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  /// Unlocks the hot wallet (authentication, plus the passphrase for "enter when signing"
  /// wallets) and derives the Ark seed. Returns null when the user cancels.
  Future<String?> _unlockArkSeed() async {
    final metadata = _viewModel.metadata;
    HotWalletPlaintext? plaintext;
    Uint8List? passphrase;
    try {
      if (metadata.enterPassphraseWhenSigning) {
        final requiresAuthentication = context.read<AuthProvider>().isAuthEnabled;
        var showIncorrectError = false;
        while (true) {
          if (!mounted) return null;
          final entered = await CommonBottomSheets.showBottomSheet<Uint8List>(
            context: context,
            title: 'Enter passphrase',
            screenName: '${AppRouteNames.arkWallet}/passphrase',
            showCloseButton: true,
            showDragHandle: true,
            backgroundColor: context.coconutColors.surfaceBottomSheet,
            child: HotWalletPassphraseInputSheet(
              requiresAuthentication: requiresAuthentication,
              showIncorrectError: showIncorrectError,
              onAuthenticationStarted: () async {},
              onPassphraseInputResumed: () {},
            ),
          );
          if (entered == null) return null;
          final isCorrect = await AppGuard.runWithoutPrivacyScreen(() => _viewModel.validatePassphrase(entered));
          if (isCorrect) {
            passphrase = NfkdUtil.normalizeNfkdUtf8(entered);
            entered.fillRange(0, entered.length, 0);
            break;
          }
          entered.fillRange(0, entered.length, 0);
          showIncorrectError = true;
        }
        // The passphrase sheet has already authenticated the user.
        final unlocked = await AppGuard.runWithoutPrivacyScreen(
          () => HotWalletSecretRepository().unlockAfterAuthentication(metadata.secureStorageKey),
        );
        plaintext = unlocked;
        return await ArkWalletService().seedForHotWallet(unlocked.mnemonic, passphrase);
      } else {
        final unlockService = HotWalletUnlockService(authenticator: FlutterHotWalletAuthenticator(context));
        plaintext = await AppGuard.runWithoutPrivacyScreen(() => unlockService.unlock(metadata.secureStorageKey));
        if (plaintext == null) return null;
        final unlocked = plaintext;
        passphrase = Uint8List.fromList(unlocked.passphrase);
        return await ArkWalletService().seedForHotWallet(unlocked.mnemonic, passphrase);
      }
    } finally {
      plaintext?.wipe();
      passphrase?.fillRange(0, passphrase.length, 0);
    }
  }

  Future<void> _unlockAndOpen() async {
    final seedHex = await _unlockArkSeed();
    if (seedHex == null) return;
    await _viewModel.openWithSeed(seedHex);
  }

  Future<void> _unlockAndRetryRecovery() async {
    final seedHex = await _unlockArkSeed();
    if (seedHex == null) return;
    await _viewModel.retryRecovery(seedHex);
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<ArkWalletViewModel>.value(
      value: _viewModel,
      child: Consumer<ArkWalletViewModel>(
        builder: (context, viewModel, _) {
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
                  Text(
                    viewModel.walletName,
                    style: CoconutTypography.body2_14.setColor(context.coconutColors.secondaryText),
                  ),
                  CoconutLayout.spacing_300h,
                  ..._buildBody(viewModel),
                  if (viewModel.errorMessage != null) ...[
                    CoconutLayout.spacing_400h,
                    Text(
                      viewModel.errorMessage!,
                      style: CoconutTypography.body3_12.setColor(context.coconutColors.danger),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  List<Widget> _buildBody(ArkWalletViewModel viewModel) {
    switch (viewModel.status) {
      case ArkWalletStatus.loading:
        return [const Center(child: CircularProgressIndicator())];
      case ArkWalletStatus.error:
        return [_text('Ark wallet unavailable.')];
      case ArkWalletStatus.locked:
        return [
          _text('Unlock this hot wallet to open its Ark wallet.'),
          CoconutLayout.spacing_400h,
          _button('Unlock Ark wallet', viewModel.isBusy ? null : _unlockAndOpen),
        ];
      case ArkWalletStatus.missing:
        return [
          _text('This hot wallet has no Ark wallet yet. Setting one up recovers any Ark funds for this seed.'),
          CoconutLayout.spacing_400h,
          _button('Set up Ark wallet', viewModel.isBusy ? null : _unlockAndOpen),
        ];
      case ArkWalletStatus.ready:
        return _buildReady(viewModel);
    }
  }

  List<Widget> _buildReady(ArkWalletViewModel viewModel) {
    final balance = viewModel.balance;
    final address = viewModel.address;
    return [
      _section('Balance'),
      if (balance == null)
        _text('—')
      else ...[
        Text(
          '${balance.spendableSats} sats',
          style: CoconutTypography.heading3_21_NumberBold.setColor(context.coconutColors.primaryText),
        ),
        CoconutLayout.spacing_200h,
        _row('Pending in round', balance.pendingInRoundSats),
        _row('Pending board', balance.pendingBoardSats),
        _row('Pending exit', balance.pendingExitSats),
        _row('Pending Lightning send', balance.pendingLightningSendSats),
        _row('Claimable Lightning receive', balance.claimableLightningReceiveSats),
      ],
      CoconutLayout.spacing_500h,
      _section('Recovery'),
      _text(_describeRecovery(viewModel.recoveryStatus)),
      if (viewModel.canRetryRecovery) ...[
        CoconutLayout.spacing_200h,
        _button('Retry recovery', viewModel.isBusy ? null : _unlockAndRetryRecovery),
      ],
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
      CoconutLayout.spacing_500h,
      _button(
        viewModel.isBusy ? 'Syncing…' : 'Sync',
        viewModel.isBusy ? null : () => viewModel.refresh(syncWithServer: true),
      ),
    ];
  }

  String _describeRecovery(bark.RecoveryStatus? status) {
    if (status is bark.CompletedRecoveryStatus) {
      final report = status.report;
      return 'Completed${report.isComplete ? '' : ' (partial)'}: '
          '${report.recovered.vtxoIds.length} VTXOs recovered (${report.recovered.totalSats} sats), '
          '${report.failed.vtxoIds.length} failed, ${report.exited.vtxoIds.length} exited.';
    }
    if (status is bark.FailedRecoveryStatus) return 'Failed: ${status.message}';
    return 'Not run (new wallet, or the Ark server was unreachable).';
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
