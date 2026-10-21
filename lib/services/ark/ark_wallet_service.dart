import 'dart:io';

import 'package:bark_bitcoin/bark_bitcoin.dart' as bark;
import 'package:coconut_lib/coconut_lib.dart';
import 'package:coconut_wallet/app.dart';
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

/// Owns the bark (Ark) wallets that belong to hot wallets.
///
/// An Ark wallet is identified by the master fingerprint of its hot wallet's seed (mnemonic +
/// passphrase), because bark's keys (`m/350'/...`) depend only on that seed. Its data lives in
/// `<app support dir>/bark/<fingerprint>/`.
///
/// bark needs the seed for as long as a wallet is open (rounds, refresh, mailbox), so open
/// wallets are kept for the rest of the process once the hot wallet has been unlocked.
class ArkWalletService {
  static final ArkWalletService _instance = ArkWalletService._();
  factory ArkWalletService() => _instance;
  ArkWalletService._();

  final Map<String, bark.Wallet> _openWallets = {};
  Directory? _baseDir;

  bool get isEnabled => CoconutWalletApp.kArkServerUrl.isNotEmpty;

  bark.Wallet? openWallet(String fingerprint) => _openWallets[_key(fingerprint)];

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
    final wallet = openWallet(fingerprint);
    if (wallet == null) return exists(fingerprint);
    return totalSats(await wallet.balance()) > 0;
  }

  static int totalSats(bark.Balance balance) =>
      balance.spendableSats +
      balance.pendingInRoundSats +
      balance.pendingExitSats +
      balance.pendingLightningSendSats +
      balance.claimableLightningReceiveSats +
      balance.pendingBoardSats;

  /// Creates the Ark wallet for a new or restored hot wallet and keeps it open.
  ///
  /// Creation is local (`createWithoutServer`), so it works while the Ark server is down. On
  /// [restore], bark's seed recovery runs during this open when the server is reachable; its
  /// outcome is available from `recoveryStatus()`.
  Future<void> create(String fingerprint, String seedHex, {required bool restore}) async {
    final datadir = await _datadir(fingerprint);
    if (await datadir.exists()) {
      // Left behind by an incomplete lifecycle operation; nothing in it can be relied on.
      await delete(fingerprint);
    }
    await _open(fingerprint, seedHex, create: true, runRecovery: restore);
  }

  /// Opens an existing Ark wallet, e.g. after an app restart.
  Future<void> open(String fingerprint, String seedHex) async {
    if (openWallet(fingerprint) != null) return;
    await _open(fingerprint, seedHex, create: false, runRecovery: false);
  }

  Future<void> delete(String fingerprint) async {
    final wallet = _openWallets.remove(_key(fingerprint));
    if (wallet != null) await _close(wallet);
    final datadir = await _datadir(fingerprint);
    if (await datadir.exists()) await datadir.delete(recursive: true);
  }

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
    for (final wallet in _openWallets.values) {
      await _close(wallet);
    }
    _openWallets.clear();
    final base = await _base();
    if (await base.exists()) await base.delete(recursive: true);
  }

  Future<void> _open(String fingerprint, String seedHex, {required bool create, required bool runRecovery}) async {
    final datadir = await _datadir(fingerprint);
    final stopwatch = Stopwatch()..start();
    final wallet = await bark.Wallet.open(
      network: _network(),
      mnemonicOrSeed: seedHex,
      config: bark.Config(
        serverAddress: CoconutWalletApp.kArkServerUrl,
        esploraAddress: CoconutWalletApp.kArkEsploraUrl.isEmpty ? null : CoconutWalletApp.kArkEsploraUrl,
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

  Future<void> _close(bark.Wallet wallet) async {
    try {
      await wallet.stopDaemon();
    } catch (error) {
      Logger.error('ArkWalletService: failed to stop daemon: $error');
    }
    wallet.dispose();
  }

  bark.Network _network() {
    final network = NetworkType.currentNetworkType;
    if (network == NetworkType.mainnet) return bark.Network.bitcoin;
    if (network == NetworkType.testnet) return bark.Network.testnet;
    return bark.Network.regtest;
  }

  String _key(String fingerprint) => fingerprint.toLowerCase();

  Future<Directory> _base() async {
    return _baseDir ??= Directory('${(await getApplicationSupportDirectory()).path}/bark');
  }

  Future<Directory> _datadir(String fingerprint) async => Directory('${(await _base()).path}/${_key(fingerprint)}');
}
