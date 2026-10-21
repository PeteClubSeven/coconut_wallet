import 'dart:async';

import 'package:coconut_wallet/model/ark/ark_balance.dart';
import 'package:coconut_wallet/model/ark/ark_board.dart';
import 'package:coconut_wallet/model/ark/ark_lightning_invoice.dart';
import 'package:coconut_wallet/model/ark/ark_movement.dart';
import 'package:coconut_wallet/model/ark/ark_snapshot.dart';
import 'package:coconut_wallet/model/wallet/wallet_item_base.dart';
import 'package:coconut_wallet/providers/wallet_provider.dart';
import 'package:coconut_wallet/repository/realm/ark_repository.dart';
import 'package:coconut_wallet/services/ark/ark_wallet_service.dart';
import 'package:coconut_wallet/utils/logger.dart';
import 'package:flutter/foundation.dart';

/// The Ark (bark) side of hot wallets, for the UI.
///
/// - Screens read the Realm cache ([snapshot]), so balances, VTXOs and history show while a hot
///   wallet is locked.
/// - A hot wallet's Ark wallet is opened once per app session ([open]), after the UI has unlocked
///   its seed, and stays open until the process ends. Wallets created or restored this session
///   are already open.
/// - While the app is in the foreground, open wallets are synced with delegated maintenance every
///   [maintenanceInterval], or with a light sync every [fastSyncInterval] while a screen waits
///   for a payment ([setFastSync]), and the cache is refreshed from each sync.
class ArkProvider extends ChangeNotifier {
  ArkProvider(
    this._walletProvider,
    this._arkRepository, {
    ArkWalletService? arkWalletService,
    this.maintenanceInterval = const Duration(seconds: 60),
    this.fastSyncInterval = const Duration(seconds: 5),
    bool startTimer = true,
  }) : _arkWalletService = arkWalletService ?? ArkWalletService() {
    _walletProvider.walletItemListNotifier.addListener(_onWalletListChanged);
    _walletProvider.setOffchainBalanceSource(totalSats);
    if (startTimer && isEnabled) _startTimer();
  }

  final WalletProvider _walletProvider;
  final ArkRepository _arkRepository;
  final ArkWalletService _arkWalletService;
  final Duration maintenanceInterval;
  final Duration fastSyncInterval;

  /// Bumped whenever cached Ark data changes, for screens that show balances or history. Unlike
  /// [notifyListeners], it doesn't fire for sync progress.
  final ValueNotifier<int> cacheRevision = ValueNotifier(0);

  final Map<int, ArkSnapshot?> _snapshots = {};
  final Map<int, Future<bool>> _opening = {};
  final Map<int, DateTime> _lastMaintenance = {};
  final Map<int, String> _syncErrors = {};
  final Set<int> _declined = {};
  final Set<int> _syncing = {};
  final Set<int> _syncAgain = {};
  final Map<int, ArkBoardFunding> _boardFunding = {};
  ArkBoardTerms? _boardTerms;
  final Map<int, int> _fastSync = {};
  Timer? _timer;
  bool _isForeground = true;
  bool _disposed = false;

  bool get isEnabled => _arkWalletService.isEnabled;

  bool supportsArk(WalletItemBase wallet) => isEnabled && wallet.hasLocalKey && wallet.hotWalletMetadata != null;

  bool supportsArkById(int walletId) {
    final wallet = _findWallet(walletId);
    return wallet != null && supportsArk(wallet);
  }

  /// The cached Ark data of [walletId], or null if it has never synced (or isn't a hot wallet).
  ArkSnapshot? snapshot(int walletId) {
    if (!supportsArkById(walletId)) return null;
    return _snapshots.putIfAbsent(walletId, () => _arkRepository.getSnapshot(walletId));
  }

  ArkBalance? balance(int walletId) => snapshot(walletId)?.balance;

  /// The Ark part of the wallet's total balance, 0 without Ark.
  int totalSats(int walletId) => balance(walletId)?.total ?? 0;

  bool get hasHotWalletWithArkFunds => _walletProvider.walletItemList.any((wallet) => totalSats(wallet.id) > 0);

  bool isOpen(int walletId) {
    final fingerprint = _fingerprint(walletId);
    return fingerprint != null && _arkWalletService.isOpen(fingerprint);
  }

  bool isOpening(int walletId) => _opening.containsKey(walletId);
  bool isSyncing(int walletId) => _syncing.contains(walletId);
  String? syncError(int walletId) => _syncErrors[walletId];

  /// Whether entering [walletId] should prompt to unlock its Ark wallet: not when it is open or
  /// opening, nor after the user declined once this session.
  bool shouldAutoUnlock(int walletId) =>
      supportsArkById(walletId) && !isOpen(walletId) && !isOpening(walletId) && !_declined.contains(walletId);

  /// Opens the Ark wallet of [walletId] with the seed [unlockSeed] returns (null = the user
  /// cancelled), creating it with seed recovery if it has no data on disk yet. Returns whether
  /// the wallet is open afterwards. Concurrent calls share one attempt.
  Future<bool> open(int walletId, Future<String?> Function() unlockSeed) {
    if (isOpen(walletId)) return Future.value(true);
    return _opening[walletId] ??= _open(walletId, unlockSeed).whenComplete(() {
      _opening.remove(walletId);
      _notify();
    });
  }

  Future<bool> _open(int walletId, Future<String?> Function() unlockSeed) async {
    _notify();
    final seedHex = await unlockSeed();
    if (seedHex == null) {
      _declined.add(walletId);
      return false;
    }
    _declined.remove(walletId);
    // Only bark's open runs under the lifecycle lock, never the unlock prompt: a delete must not
    // wait behind a PIN sheet.
    final opened = await _walletProvider.runHotWalletLifecycleOperation(() async {
      final fingerprint = _fingerprint(walletId);
      if (fingerprint == null) return false; // Deleted while the prompt was up.
      if (await _arkWalletService.exists(fingerprint)) {
        await _arkWalletService.open(fingerprint, seedHex);
      } else {
        // Added before Ark was enabled: set one up, recovering any Ark funds of this seed.
        await _arkWalletService.create(fingerprint, seedHex, restore: true);
      }
      return true;
    });
    if (opened) unawaited(syncNow(walletId));
    return opened;
  }

  /// Recreates the unused Ark wallet so bark's seed recovery runs again.
  Future<void> retryRecovery(int walletId, String seedHex) async {
    if (!(snapshot(walletId)?.canRetryRecovery ?? false)) return;
    await _walletProvider.runHotWalletLifecycleOperation(() async {
      final fingerprint = _fingerprint(walletId);
      if (fingerprint == null) return;
      await _arkWalletService.create(fingerprint, seedHex, restore: true);
    });
    await syncNow(walletId);
  }

  /// Syncs [walletId] and refreshes its cache. With [maintenance], bark may also schedule
  /// delegated refreshes. Skipped when the wallet is locked or already syncing.
  Future<void> syncNow(int walletId, {bool maintenance = true}) async {
    final fingerprint = _fingerprint(walletId);
    if (fingerprint == null || !_arkWalletService.isOpen(fingerprint)) return;
    if (_syncing.contains(walletId)) {
      // Whatever asked (e.g. a move just made) must see a sync that starts after it.
      _syncAgain.add(walletId);
      return;
    }
    _syncing.add(walletId);
    _notify();
    try {
      try {
        if (maintenance) {
          await _arkWalletService.maintenance(fingerprint);
          _lastMaintenance[walletId] = DateTime.now();
        } else {
          await _arkWalletService.sync(fingerprint);
        }
        _syncErrors.remove(walletId);
      } catch (error) {
        // Offline or the server is down: still refresh the cache from bark's local state.
        Logger.error('ArkProvider: sync of wallet $walletId failed: $error');
        _syncErrors[walletId] = error.toString();
      }
      final previous = snapshot(walletId);
      final next = await _arkWalletService.snapshot(
        fingerprint,
        address: previous?.address,
        addressIndex: previous?.addressIndex,
      );
      if (previous != null && previous.hasSameContent(next)) return;
      if (await _arkRepository.saveSnapshot(walletId, next)) {
        _snapshots[walletId] = next;
        cacheRevision.value++;
      }
    } catch (error) {
      Logger.error('ArkProvider: failed to refresh the Ark cache of wallet $walletId: $error');
      _syncErrors[walletId] = error.toString();
    } finally {
      _syncing.remove(walletId);
      _notify();
      if (_syncAgain.remove(walletId)) unawaited(syncNow(walletId, maintenance: false));
    }
  }

  /// Whether [txid] funds a board into one of the hot wallets' Ark wallets. Such a transaction
  /// must not be replaced (RBF): bark only tracks the txid the board was registered with.
  bool fundsBoard(String txid) => _walletProvider.walletItemList.any(
    (wallet) =>
        snapshot(
          wallet.id,
        )?.movements.any((movement) => movement.kind == ArkMovementKind.board && movement.linkedTxid == txid) ??
        false,
  );

  /// The Ark server's board limits (cached for the session).
  Future<ArkBoardTerms> boardTerms(int walletId) async {
    final cached = _boardTerms;
    if (cached != null) return cached;
    final info = await _arkWalletService.arkInfo(_requireFingerprint(walletId));
    if (info == null) throw StateError('The Ark server is not reachable');
    return _boardTerms = ArkBoardTerms(
      minAmountSats: info.minBoardAmountSats,
      maxAmountSats: info.maxVtxoAmountSats,
      requiredConfirmations: info.requiredBoardConfirmations,
    );
  }

  /// The address to fund a board into [walletId]'s Ark wallet. The same one is returned until a
  /// board succeeds: each new one uses up a key of the Ark keychain.
  Future<ArkBoardFunding> boardFunding(int walletId) async {
    final cached = _boardFunding[walletId];
    if (cached != null) return cached;
    final info = await _arkWalletService.boardFundingAddress(_requireFingerprint(walletId));
    return _boardFunding[walletId] = ArkBoardFunding(
      address: info.address,
      expiryHeight: info.expiryHeight,
      keypairIndex: info.keypairIndex,
    );
  }

  Future<int> estimateBoardFee(int walletId, int amountSats) async =>
      (await _arkWalletService.estimateBoardFee(_requireFingerprint(walletId), amountSats)).feeSats;

  /// Registers a board of [funding]'s address with the Ark server. [unsignedPsbtBase64] is the
  /// funding transaction before signing: bark then leaves broadcasting it to the caller and
  /// watches for it on-chain. Its txid is final from here on, so it must not be replaced (RBF).
  Future<void> board(int walletId, {required String unsignedPsbtBase64, required ArkBoardFunding funding}) async {
    await _arkWalletService.boardPsbt(
      _requireFingerprint(walletId),
      psbtBase64: unsignedPsbtBase64,
      keypairIndex: funding.keypairIndex,
      expiryHeight: funding.expiryHeight,
    );
    _boardFunding.remove(walletId);
    unawaited(syncNow(walletId, maintenance: false));
  }

  /// Broadcasts a raw transaction through bark's chain source, as a fallback for Coconut's own.
  Future<String> broadcastTx(int walletId, String txHex) =>
      _arkWalletService.broadcastTx(_requireFingerprint(walletId), txHex);

  /// The fee to move Ark funds to [address]: everything when [amountSats] is null (taken out of
  /// it), or [amountSats] (on top).
  Future<int> estimateMoveOnchainFee(int walletId, String address, {int? amountSats}) async {
    final fingerprint = _requireFingerprint(walletId);
    final estimate =
        amountSats == null
            ? await _arkWalletService.estimateOffboardAllFee(fingerprint, address)
            : await _arkWalletService.estimateSendOnchainFee(fingerprint, address, amountSats);
    return estimate.feeSats;
  }

  /// Moves Ark funds to [address] on-chain: everything (an offboard) when [amountSats] is null,
  /// else that amount with the rest staying in Ark. Returns the txid. Throws
  /// [ArkMovePendingException] when bark accepted the move but has to finish it on a later sync.
  Future<String> moveOnchain(int walletId, String address, {int? amountSats}) async {
    final fingerprint = _requireFingerprint(walletId);
    try {
      return amountSats == null
          ? await _arkWalletService.offboardAll(fingerprint, address)
          : await _arkWalletService.sendOnchain(fingerprint, address, amountSats);
    } catch (error) {
      if (error.toString().contains('remains pending')) throw ArkMovePendingException(error.toString());
      rethrow;
    } finally {
      unawaited(syncNow(walletId, maintenance: false));
    }
  }

  /// Creates a BOLT11 invoice for [amountSats] (bark can't make amountless ones). The payment is
  /// claimed by the wallet's next sync, so keep [setFastSync] on while waiting for it.
  Future<ArkLightningInvoice> createLightningInvoice(int walletId, int amountSats) async {
    final fingerprint = _requireFingerprint(walletId);
    final fee = await _arkWalletService.estimateLightningReceiveFee(fingerprint, amountSats);
    final invoice = await _arkWalletService.createLightningInvoice(fingerprint, amountSats);
    return ArkLightningInvoice(
      invoice: invoice.invoice,
      paymentHash: invoice.paymentHash,
      amountSats: invoice.amountSats,
      feeSats: fee.feeSats,
    );
  }

  /// VTXOs bark wants refreshed now (close to expiry, or past the server's chain-depth limit).
  Future<List<String>> vtxoIdsToRefresh(int walletId) =>
      _arkWalletService.vtxoIdsToRefresh(_requireFingerprint(walletId));

  /// The block height by which some VTXO must be refreshed, if any.
  Future<int?> nextRequiredRefreshHeight(int walletId) =>
      _arkWalletService.nextRequiredRefreshHeight(_requireFingerprint(walletId));

  Future<int> estimateRefreshFee(int walletId, List<String> vtxoIds) async =>
      (await _arkWalletService.estimateRefreshFee(_requireFingerprint(walletId), vtxoIds)).feeSats;

  /// Refreshes [vtxoIds] in a delegated round: the server completes it without the app staying
  /// online, and the new VTXOs arrive with a later sync.
  Future<void> refreshDelegated(int walletId, List<String> vtxoIds) async {
    await _arkWalletService.refreshDelegated(_requireFingerprint(walletId), vtxoIds);
    await syncNow(walletId, maintenance: false);
  }

  /// Syncs every few seconds while a screen waits for a payment to [walletId] (e.g. a Lightning
  /// invoice on the receive screen). Calls nest; each `true` needs a matching `false`.
  void setFastSync(int walletId, bool enabled) {
    final count = (_fastSync[walletId] ?? 0) + (enabled ? 1 : -1);
    if (count > 0) {
      _fastSync[walletId] = count;
    } else {
      _fastSync.remove(walletId);
    }
  }

  void onPause() {
    _isForeground = false;
    _timer?.cancel();
    _timer = null;
  }

  void onResume() {
    if (_isForeground && _timer != null) return;
    _isForeground = true;
    if (!isEnabled || _disposed) return;
    // Unlock prompts briefly pause the app too; the tick below only syncs what is due.
    _startTimer();
    _tick();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(fastSyncInterval, (_) => _tick());
  }

  void _tick() {
    if (!_isForeground || _disposed) return;
    final now = DateTime.now();
    for (final wallet in _walletProvider.walletItemList) {
      if (!supportsArk(wallet) || !isOpen(wallet.id) || _syncing.contains(wallet.id)) continue;
      final last = _lastMaintenance[wallet.id];
      if (last == null || now.difference(last) >= maintenanceInterval) {
        unawaited(syncNow(wallet.id));
      } else if (_fastSync.containsKey(wallet.id)) {
        unawaited(syncNow(wallet.id, maintenance: false));
      }
    }
  }

  void _onWalletListChanged() {
    final ids = _walletProvider.walletItemList.map((wallet) => wallet.id).toSet();
    _snapshots.removeWhere((id, _) => !ids.contains(id));
    _lastMaintenance.removeWhere((id, _) => !ids.contains(id));
    _declined.removeWhere((id) => !ids.contains(id));
    // A wallet created or restored just now is open but has nothing cached yet.
    if (_isForeground) _tick();
    _notify();
  }

  WalletItemBase? _findWallet(int walletId) {
    for (final wallet in _walletProvider.walletItemList) {
      if (wallet.id == walletId) return wallet;
    }
    return null;
  }

  String _requireFingerprint(int walletId) {
    final fingerprint = _fingerprint(walletId);
    if (fingerprint == null) throw StateError('Wallet $walletId has no Ark wallet');
    return fingerprint;
  }

  String? _fingerprint(int walletId) {
    final wallet = _findWallet(walletId);
    if (wallet == null || !supportsArk(wallet)) return null;
    return wallet.hotWalletMetadata!.masterFingerprint;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _walletProvider.walletItemListNotifier.removeListener(_onWalletListChanged);
    _walletProvider.setOffchainBalanceSource(null);
    cacheRevision.dispose();
    super.dispose();
  }
}
