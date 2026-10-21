import 'dart:io';

import 'package:bark_bitcoin/bark_bitcoin.dart' as bark;
import 'package:coconut_lib/coconut_lib.dart';
import 'package:coconut_wallet/app.dart';
import 'package:coconut_wallet/model/ark/ark_balance.dart';
import 'package:coconut_wallet/model/ark/ark_movement.dart';
import 'package:coconut_wallet/model/ark/ark_snapshot.dart';
import 'package:coconut_wallet/model/ark/ark_vtxo.dart';
import 'package:coconut_wallet/services/security/hot_wallet_lifecycle_lock.dart';
import 'package:coconut_wallet/utils/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Derives the 64-byte BIP39 seed (mnemonic + passphrase) that bark derives its keys from,
/// hex-encoded for `bark.Wallet.open(mnemonicOrSeed:)`. Run it with `compute`: PBKDF2 is slow.
///
/// bark's own mnemonic path always uses an empty passphrase, so passing the seed is what keeps
/// passphrase hot wallets and their Ark wallets in step.
String deriveArkSeedHex(({Uint8List mnemonic, Uint8List passphrase}) input) {
  Seed? seed;
  try {
    seed = Seed.fromMnemonic(input.mnemonic, passphrase: input.passphrase);
    final rootSeed = seed.rootSeed;
    final hex = rootSeed.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    rootSeed.fillRange(0, rootSeed.length, 0);
    return hex;
  } finally {
    seed?.wipe();
    input.mnemonic.fillRange(0, input.mnemonic.length, 0);
    input.passphrase.fillRange(0, input.passphrase.length, 0);
  }
}

/// Thrown when an operation needs an Ark wallet that isn't open (its hot wallet is locked).
class ArkWalletLockedException implements Exception {
  ArkWalletLockedException(this.fingerprint);

  final String fingerprint;

  @override
  String toString() => 'Ark wallet $fingerprint is not open';
}

/// Owns the bark (Ark) wallets that belong to hot wallets.
///
/// An Ark wallet is identified by the master fingerprint of its hot wallet's seed (mnemonic +
/// passphrase), because bark's keys (`m/350'/...`) depend only on that seed. Its data lives in
/// `<app support dir>/bark/<fingerprint>/`.
///
/// bark needs the seed for as long as a wallet is open (rounds, refresh, mailbox), so open
/// wallets are kept for the rest of the process once the hot wallet has been unlocked.
///
/// Every call into a wallet runs under that wallet's lock: bark's Dart objects crash the process
/// if used after `dispose`, and the periodic sync must not interleave with user actions.
class ArkWalletService {
  static final ArkWalletService _instance = ArkWalletService._();
  factory ArkWalletService() => _instance;
  ArkWalletService._();

  final Map<String, bark.Wallet> _openWallets = {};
  final Map<String, HotWalletLifecycleLock> _locks = {};
  Directory? _baseDir;

  bool get isEnabled => CoconutWalletApp.kArkServerUrl.isNotEmpty;

  bool isOpen(String fingerprint) => _openWallets.containsKey(_key(fingerprint));

  /// The Ark seed for a hot wallet being added, or null while Ark is disabled. Works on copies.
  Future<String?> seedForHotWallet(Uint8List mnemonic, Uint8List passphrase) async {
    if (!isEnabled) return null;
    return compute(deriveArkSeedHex, (
      mnemonic: Uint8List.fromList(mnemonic),
      passphrase: Uint8List.fromList(passphrase),
    ));
  }

  Future<bool> exists(String fingerprint) async => (await _datadir(fingerprint)).exists();

  /// Whether the Ark wallet may hold funds. A locked (not open) wallet counts as possibly funded,
  /// since its balance can't be read without the seed.
  Future<bool> mayHoldFunds(String fingerprint) async {
    if (!isOpen(fingerprint)) return exists(fingerprint);
    return withWallet(fingerprint, (wallet) async => ArkBalance.fromBark(await wallet.balance()).total > 0);
  }

  /// Runs [action] on the open Ark wallet under its lock.
  Future<T> withWallet<T>(String fingerprint, Future<T> Function(bark.Wallet wallet) action) {
    return _lock(fingerprint).synchronized(() async {
      final wallet = _openWallets[_key(fingerprint)];
      if (wallet == null) throw ArkWalletLockedException(fingerprint);
      return action(wallet);
    });
  }

  /// Creates the Ark wallet for a new or restored hot wallet and keeps it open.
  ///
  /// Creation is local (`createWithoutServer`), so it works while the Ark server is down. On
  /// [restore], bark's seed recovery runs during this open when the server is reachable; its
  /// outcome is available from `recoveryStatus()`.
  Future<void> create(String fingerprint, String seedHex, {required bool restore}) {
    return _lock(fingerprint).synchronized(() async {
      final datadir = await _datadir(fingerprint);
      if (await datadir.exists()) {
        // Left behind by an incomplete lifecycle operation, or recreated to retry recovery.
        await _deleteLocked(fingerprint);
      }
      await _open(fingerprint, seedHex, create: true, runRecovery: restore);
    });
  }

  /// Opens an existing Ark wallet, e.g. after an app restart.
  Future<void> open(String fingerprint, String seedHex) {
    return _lock(fingerprint).synchronized(() async {
      if (isOpen(fingerprint)) return;
      await _open(fingerprint, seedHex, create: false, runRecovery: false);
    });
  }

  Future<void> delete(String fingerprint) => _lock(fingerprint).synchronized(() => _deleteLocked(fingerprint));

  /// Fingerprints of every Ark wallet with data on disk.
  Future<List<String>> listFingerprints() async {
    final base = await _base();
    if (!await base.exists()) return [];
    return [
      await for (final entity in base.list())
        if (entity is Directory) entity.uri.pathSegments.where((s) => s.isNotEmpty).last,
    ];
  }

  Future<void> wipeAll() async {
    for (final fingerprint in _openWallets.keys.toList()) {
      await _lock(fingerprint).synchronized(() async {
        final wallet = _openWallets.remove(fingerprint);
        if (wallet != null) await _close(wallet);
      });
    }
    final base = await _base();
    if (await base.exists()) await base.delete(recursive: true);
  }

  /// Syncs with the Ark server and the chain (mailbox, rounds, Lightning claims, boards) and lets
  /// bark schedule delegated refreshes for VTXOs nearing expiry.
  ///
  /// Delegated maintenance may spend refresh fees without asking; it is the only automatic
  /// refresh, since the daemon's own (interactive) one is disabled in [_open].
  Future<void> maintenance(String fingerprint) => withWallet(fingerprint, (wallet) => wallet.maintenanceDelegated());

  /// A lighter sync without refresh scheduling, e.g. while waiting for a Lightning payment.
  Future<void> sync(String fingerprint) => withWallet(fingerprint, (wallet) => wallet.sync_());

  /// Reads everything Coconut caches. Keeps [address] (the one already shown to the user) until
  /// a movement has received on it, and only then derives a new one, so restores stay inside
  /// bark's key gap limit.
  Future<ArkSnapshot> snapshot(String fingerprint, {String? address, int? addressIndex}) {
    return withWallet(fingerprint, (wallet) async {
      final balance = ArkBalance.fromBark(await wallet.balance());
      final vtxos = (await wallet.vtxos()).map(ArkVtxo.fromBark).toList();
      final movements = (await wallet.history()).map(ArkMovement.fromBark).toList();
      final recovery = _describeRecovery(wallet.recoveryStatus());

      var currentAddress = address;
      var currentIndex = addressIndex;
      if (currentAddress == null || _hasReceivedOn(movements, currentAddress)) {
        final next = await wallet.newAddressWithIndex();
        currentAddress = next.address;
        currentIndex = next.index;
      }

      return ArkSnapshot(
        balance: balance,
        vtxos: vtxos,
        movements: movements,
        recovery: recovery,
        syncedAt: DateTime.now(),
        address: currentAddress,
        addressIndex: currentIndex,
      );
    });
  }

  Future<bark.LightningInvoice> createLightningInvoice(String fingerprint, int amountSats) =>
      withWallet(fingerprint, (wallet) => wallet.bolt11Invoice(amountSats: amountSats, description: null, token: null));

  Future<void> cancelLightningReceive(String fingerprint, String paymentHash) =>
      withWallet(fingerprint, (wallet) => wallet.cancelLightningReceive(paymentHash: paymentHash));

  Future<bark.FeeEstimate> estimateLightningReceiveFee(String fingerprint, int amountSats) =>
      withWallet(fingerprint, (wallet) => wallet.estimateLightningReceiveFee(amountSats: amountSats));

  Future<List<String>> vtxoIdsToRefresh(String fingerprint) =>
      withWallet(fingerprint, (wallet) async => (await wallet.getVtxosToRefresh()).map((vtxo) => vtxo.id).toList());

  Future<int?> nextRequiredRefreshHeight(String fingerprint) =>
      withWallet(fingerprint, (wallet) => wallet.getNextRequiredRefreshBlockheight());

  Future<bark.FeeEstimate> estimateRefreshFee(String fingerprint, List<String> vtxoIds) =>
      withWallet(fingerprint, (wallet) => wallet.estimateRefreshFee(vtxoIds: vtxoIds));

  /// Hands the refresh to the server (a delegated round), so the app needn't stay online for it.
  Future<void> refreshDelegated(String fingerprint, List<String> vtxoIds) =>
      withWallet(fingerprint, (wallet) async => wallet.refreshVtxosDelegated(vtxoIds: vtxoIds));

  Future<bark.ArkInfo?> arkInfo(String fingerprint) => withWallet(fingerprint, (wallet) => wallet.arkInfo());

  /// A new address to fund a board to. Each call derives and stores a new key from the same
  /// keychain as Ark addresses, so callers should reuse it until a board succeeds.
  Future<bark.BoardFundingInfo> boardFundingAddress(String fingerprint) =>
      withWallet(fingerprint, (wallet) => wallet.boardFundingAddress());

  Future<bark.FeeEstimate> estimateBoardFee(String fingerprint, int amountSats) =>
      withWallet(fingerprint, (wallet) => wallet.estimateBoardFee(amountSats: amountSats));

  /// Registers a board funded by [psbtBase64] (cosigned by the server). bark broadcasts the
  /// funding transaction only if the PSBT is finalized; otherwise it waits to see it on-chain.
  Future<bark.PendingBoard> boardPsbt(
    String fingerprint, {
    required String psbtBase64,
    required int keypairIndex,
    required int expiryHeight,
  }) => withWallet(
    fingerprint,
    (wallet) => wallet.boardPsbt(psbtBase64: psbtBase64, keypairIndex: keypairIndex, expiryHeight: expiryHeight),
  );

  /// Broadcasts a raw transaction through bark's chain source; returns its txid.
  Future<String> broadcastTx(String fingerprint, String txHex) =>
      withWallet(fingerprint, (wallet) => wallet.broadcastTx(txHex: txHex));

  /// Offboards every VTXO to [address]; the fee is taken out of the amount. Returns the txid.
  Future<String> offboardAll(String fingerprint, String address) =>
      withWallet(fingerprint, (wallet) async => (await wallet.offboardAll(bitcoinAddress: address)).txid);

  Future<bark.FeeEstimate> estimateOffboardAllFee(String fingerprint, String address) =>
      withWallet(fingerprint, (wallet) => wallet.estimateOffboardAllFee(address: address));

  /// Pays [amountSats] to [address] on-chain from the Ark balance; the fee comes on top. Returns
  /// the txid.
  Future<String> sendOnchain(String fingerprint, String address, int amountSats) =>
      withWallet(fingerprint, (wallet) => wallet.sendOnchain(address: address, amountSats: amountSats));

  Future<bark.FeeEstimate> estimateSendOnchainFee(String fingerprint, String address, int amountSats) =>
      withWallet(fingerprint, (wallet) => wallet.estimateSendOnchainFee(address: address, amountSats: amountSats));

  Future<void> _open(String fingerprint, String seedHex, {required bool create, required bool runRecovery}) async {
    final datadir = await _datadir(fingerprint);
    final stopwatch = Stopwatch()..start();
    final wallet = await bark.Wallet.open(
      network: _network(),
      mnemonicOrSeed: seedHex,
      config: bark.Config(
        serverAddress: CoconutWalletApp.kArkServerUrl,
        esploraAddress: CoconutWalletApp.kArkEsploraUrl.isEmpty ? null : CoconutWalletApp.kArkEsploraUrl,
        // The daemon refreshes VTXOs by joining rounds interactively, which a phone can't be
        // relied on to finish. With manual sync it only keeps the server connection alive; the
        // app drives syncing and delegated refreshes through [maintenance].
        daemonManualSync: true,
      ),
      args: bark.WalletOpenArgs(
        datadir: datadir.path,
        createIfNotExists: create,
        createWithoutServer: create,
        skipRecovery: !runRecovery,
      ),
    );
    _openWallets[_key(fingerprint)] = wallet;
    Logger.log(
      'ArkWalletService: ${create ? 'created' : 'opened'} Ark wallet $fingerprint in ${stopwatch.elapsedMilliseconds} ms',
    );
  }

  Future<void> _deleteLocked(String fingerprint) async {
    final wallet = _openWallets.remove(_key(fingerprint));
    if (wallet != null) await _close(wallet);
    final datadir = await _datadir(fingerprint);
    if (await datadir.exists()) await datadir.delete(recursive: true);
  }

  Future<void> _close(bark.Wallet wallet) async {
    try {
      await wallet.stopDaemonWait();
    } catch (error) {
      Logger.error('ArkWalletService: failed to stop daemon: $error');
    }
    wallet.dispose();
  }

  static bool _hasReceivedOn(List<ArkMovement> movements, String address) {
    final normalized = address.toLowerCase();
    return movements.any(
      (movement) => movement.receivedOnDestinations.any((destination) => destination.value.toLowerCase() == normalized),
    );
  }

  static ArkRecovery _describeRecovery(bark.RecoveryStatus status) {
    if (status is bark.CompletedRecoveryStatus) {
      final report = status.report;
      return ArkRecovery(
        ArkRecoveryState.completed,
        'Completed${report.isComplete ? '' : ' (partial)'}: '
        '${report.recovered.vtxoIds.length} VTXOs recovered (${report.recovered.totalSats} sats), '
        '${report.failed.vtxoIds.length} failed, ${report.exited.vtxoIds.length} exited.',
      );
    }
    if (status is bark.FailedRecoveryStatus) return ArkRecovery(ArkRecoveryState.failed, 'Failed: ${status.message}');
    return ArkRecovery.notRun;
  }

  bark.Network _network() {
    final network = NetworkType.currentNetworkType;
    if (network == NetworkType.mainnet) return bark.Network.bitcoin;
    if (network == NetworkType.testnet) return bark.Network.testnet;
    return bark.Network.regtest;
  }

  String _key(String fingerprint) => fingerprint.toLowerCase();

  HotWalletLifecycleLock _lock(String fingerprint) => _locks.putIfAbsent(_key(fingerprint), HotWalletLifecycleLock.new);

  Future<Directory> _base() async {
    return _baseDir ??= Directory('${(await getApplicationSupportDirectory()).path}/bark');
  }

  Future<Directory> _datadir(String fingerprint) async => Directory('${(await _base()).path}/${_key(fingerprint)}');
}
