import 'package:bark_bitcoin/bark_bitcoin.dart' as bark;
import 'package:coconut_lib/coconut_lib.dart';
import 'package:coconut_wallet/model/wallet/hot_wallet_metadata.dart';
import 'package:coconut_wallet/model/wallet/wallet_item_base.dart';
import 'package:coconut_wallet/providers/wallet_provider.dart';
import 'package:coconut_wallet/services/ark/ark_wallet_service.dart';
import 'package:coconut_wallet/services/security/hot_wallet_signing_service.dart';
import 'package:coconut_wallet/utils/logger.dart';
import 'package:flutter/foundation.dart';

enum ArkWalletStatus {
  loading,

  /// The Ark wallet exists but isn't open: the hot wallet must be unlocked first.
  locked,

  /// No Ark wallet on disk, e.g. created before Ark was enabled. Unlocking creates one with
  /// seed recovery.
  missing,
  ready,
  error,
}

/// The hot wallet's Ark (bark) wallet: status, recovery outcome, balance and a receive address.
class ArkWalletViewModel extends ChangeNotifier {
  ArkWalletViewModel(WalletProvider walletProvider, int walletId, {ArkWalletService? arkWalletService})
    : _wallet = walletProvider.getWalletById(walletId),
      _arkWalletService = arkWalletService ?? ArkWalletService();

  final WalletItemBase _wallet;
  final ArkWalletService _arkWalletService;

  ArkWalletStatus _status = ArkWalletStatus.loading;
  String? _errorMessage;
  bark.Balance? _balance;
  bark.RecoveryStatus? _recoveryStatus;
  String? _address;
  bool _isBusy = false;
  bool _hasActivity = false;
  bool _disposed = false;

  ArkWalletStatus get status => _status;
  String? get errorMessage => _errorMessage;
  bark.Balance? get balance => _balance;
  bark.RecoveryStatus? get recoveryStatus => _recoveryStatus;
  String? get address => _address;
  bool get isBusy => _isBusy;
  String get walletName => _wallet.name;
  HotWalletMetadata get metadata => _wallet.hotWalletMetadata!;

  /// Seed recovery can be retried while the Ark wallet has never been used: recreating it then
  /// loses nothing.
  bool get canRetryRecovery =>
      _status == ArkWalletStatus.ready &&
      !_hasActivity &&
      (_recoveryStatus is bark.NotRunRecoveryStatus || _recoveryStatus is bark.FailedRecoveryStatus);

  bark.Wallet? get _openWallet => _arkWalletService.openWallet(metadata.masterFingerprint);

  Future<void> initialize() async {
    if (!_arkWalletService.isEnabled || _wallet.hotWalletMetadata == null) {
      _setError('Ark is not available for this wallet');
      return;
    }
    if (_openWallet != null) {
      _setStatus(ArkWalletStatus.ready);
      await refresh();
    } else if (await _arkWalletService.exists(metadata.masterFingerprint)) {
      _setStatus(ArkWalletStatus.locked);
    } else {
      _setStatus(ArkWalletStatus.missing);
    }
  }

  /// Opens the Ark wallet (or creates it with seed recovery when it's missing) once the screen
  /// has unlocked the hot wallet and derived its Ark seed.
  Future<void> openWithSeed(String seedHex) async {
    await _run(() async {
      final fingerprint = metadata.masterFingerprint;
      if (_status == ArkWalletStatus.missing) {
        await _arkWalletService.create(fingerprint, seedHex, restore: true);
      } else {
        await _arkWalletService.open(fingerprint, seedHex);
      }
      _setStatus(ArkWalletStatus.ready);
      await _load();
    });
  }

  /// Recreates the unused Ark wallet so bark's seed recovery runs again.
  Future<void> retryRecovery(String seedHex) async {
    if (!canRetryRecovery) return;
    await _run(() async {
      _address = null;
      await _arkWalletService.create(metadata.masterFingerprint, seedHex, restore: true);
      await _load();
    });
  }

  Future<void> refresh({bool syncWithServer = false}) async {
    await _run(() async {
      if (syncWithServer) await _openWallet?.sync_();
      await _load();
    });
  }

  /// Checks a passphrase entered for an "enter passphrase when signing" wallet against the hot
  /// wallet's xpub, so a typo can't open or create the wrong Ark wallet.
  Future<bool> validatePassphrase(Uint8List passphrase) {
    final walletBase = _wallet.walletBase as SingleSignatureWallet;
    return HotWalletSigningService().validatePassphrase(
      storageKey: metadata.secureStorageKey,
      passphrase: passphrase,
      addressTypeName: walletBase.addressType.name,
      accountIndex: metadata.accountIndex,
      expectedExtendedPublicKey: walletBase.keyStore.extendedPublicKey.serialize(),
    );
  }

  Future<void> _load() async {
    final wallet = _openWallet;
    if (wallet == null) return;
    _recoveryStatus = wallet.recoveryStatus();
    _balance = await wallet.balance();
    _hasActivity = (await wallet.history()).isNotEmpty || ArkWalletService.totalSats(_balance!) > 0;
    _address ??= await wallet.newAddress();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_isBusy) return;
    _isBusy = true;
    _errorMessage = null;
    _notify();
    try {
      await action();
    } catch (error) {
      Logger.error('ArkWalletViewModel: $error');
      _errorMessage = error.toString();
      if (_status != ArkWalletStatus.ready) _status = ArkWalletStatus.error;
    } finally {
      _isBusy = false;
      _notify();
    }
  }

  void _setStatus(ArkWalletStatus status) {
    _status = status;
    _notify();
  }

  void _setError(String message) {
    _errorMessage = message;
    _setStatus(ArkWalletStatus.error);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
