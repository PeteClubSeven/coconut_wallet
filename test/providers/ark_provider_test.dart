import 'package:coconut_wallet/enums/wallet_enums.dart';
import 'package:coconut_wallet/model/ark/ark_snapshot.dart';
import 'package:coconut_wallet/model/wallet/hot_wallet_metadata.dart';
import 'package:coconut_wallet/model/wallet/singlesig_wallet_item.dart';
import 'package:coconut_wallet/model/wallet/wallet_item_base.dart';
import 'package:coconut_wallet/providers/ark_provider.dart';
import 'package:coconut_wallet/providers/wallet_provider.dart';
import 'package:coconut_wallet/repository/realm/ark_repository.dart';
import 'package:coconut_wallet/repository/realm/model/coconut_wallet_model.dart';
import 'package:coconut_wallet/repository/shared_preference/shared_prefs_repository.dart';
import 'package:coconut_wallet/services/ark/ark_wallet_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../mock/ark/ark_fixtures.dart';
import '../repository/realm/test_realm_manager.dart';

const _descriptor =
    "wpkh([D45AA182/84'/1'/0']vpub5YtEovN9MqeUZxWqdpUKngsiaLCPFY34KpWGQVk9Tjq8G5SYcRFj9s5aCKeAQYGunG7LrFkA5obtH8kPJiv92JtWHfRvnir6PDvhd4p93Pp/<0;1>/*)#rcn2hj6y";
const _fingerprint = 'D45AA182';

class _FakeWalletProvider extends Fake implements WalletProvider {
  _FakeWalletProvider(List<WalletItemBase> wallets) : walletItemListNotifier = ValueNotifier(wallets);

  @override
  final ValueNotifier<List<WalletItemBase>> walletItemListNotifier;

  @override
  List<WalletItemBase> get walletItemList => walletItemListNotifier.value;

  @override
  Future<T> runHotWalletLifecycleOperation<T>(Future<T> Function() operation) => operation();

  @override
  void setOffchainBalanceSource(int Function(int walletId)? offchainBalanceOf) {}
}

class _FakeArkWalletService extends Fake implements ArkWalletService {
  final Set<String> openWallets = {};
  final Set<String> onDisk = {};
  final List<String> calls = [];
  ArkSnapshot nextSnapshot = createArkSnapshot();
  Object? maintenanceError;

  @override
  bool get isEnabled => true;

  @override
  bool isOpen(String fingerprint) => openWallets.contains(fingerprint.toLowerCase());

  @override
  Future<bool> exists(String fingerprint) async => onDisk.contains(fingerprint.toLowerCase());

  @override
  Future<void> open(String fingerprint, String seedHex) async {
    calls.add('open');
    openWallets.add(fingerprint.toLowerCase());
  }

  @override
  Future<void> create(String fingerprint, String seedHex, {required bool restore}) async {
    calls.add('create(restore: $restore)');
    openWallets.add(fingerprint.toLowerCase());
    onDisk.add(fingerprint.toLowerCase());
  }

  @override
  Future<void> maintenance(String fingerprint) async {
    calls.add('maintenance');
    if (maintenanceError != null) throw maintenanceError!;
  }

  @override
  Future<void> sync(String fingerprint) async => calls.add('sync');

  @override
  Future<ArkSnapshot> snapshot(String fingerprint, {String? address, int? addressIndex}) async {
    calls.add('snapshot(address: $address)');
    return nextSnapshot;
  }
}

SinglesigWalletItem _hotWallet(int id) => SinglesigWalletItem(
  id: id,
  name: 'Hot $id',
  colorIndex: 0,
  iconIndex: 0,
  descriptor: _descriptor,
  hotWalletMetadata: HotWalletMetadata(
    walletId: id,
    secureStorageKey: 'hot_wallet_secret_$id',
    masterFingerprint: _fingerprint,
    derivationPath: "m/84'/1'/0'",
    accountIndex: 0,
    backupVerified: true,
    enterPassphraseWhenSigning: false,
    createdAt: DateTime.utc(2026, 10, 19),
  ),
);

void main() {
  late TestRealmManager realmManager;
  late ArkRepository arkRepository;
  late _FakeArkWalletService arkService;
  late _FakeWalletProvider walletProvider;
  late ArkProvider arkProvider;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // ignore: deprecated_member_use_from_same_package
    SharedPrefsRepository().setSharedPreferencesForTest(await SharedPreferences.getInstance());
    realmManager = await setupTestRealmManager();
    realmManager.realm.write(() {
      realmManager.realm.add(RealmWalletBase(1, 0, 0, _descriptor, 'Hot 1', WalletType.singleSignature.name));
      realmManager.realm.add(
        RealmHotWalletMetadata(
          1,
          'hot_wallet_secret_1',
          _fingerprint,
          "m/84'/1'/0'",
          0,
          true,
          false,
          DateTime.utc(2026, 10, 19),
          HotWalletLifecycleState.active.name,
        ),
      );
    });
    arkRepository = ArkRepository(realmManager);
    arkService = _FakeArkWalletService();
    walletProvider = _FakeWalletProvider([_hotWallet(1)]);
    arkProvider = ArkProvider(walletProvider, arkRepository, arkWalletService: arkService, startTimer: false);
  });

  tearDown(() async {
    // Let syncs started by an unlock finish before the Realm closes.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    arkProvider.dispose();
    realmManager.reset();
    realmManager.dispose();
  });

  test('a locked wallet shows its cached snapshot', () async {
    await arkRepository.saveSnapshot(1, createArkSnapshot());

    expect(arkProvider.isOpen(1), isFalse);
    expect(arkProvider.totalSats(1), 50000);
    expect(arkProvider.snapshot(1)!.vtxos, hasLength(1));
  });

  test('a sync writes the snapshot to Realm and keeps the shown address', () async {
    arkService.openWallets.add(_fingerprint.toLowerCase());
    await arkRepository.saveSnapshot(1, createArkSnapshot(address: 'tark1shown'));
    arkService.nextSnapshot = createArkSnapshot(
      address: 'tark1shown',
      vtxos: [createArkVtxo(), createArkVtxo(id: 'b:0')],
    );

    await arkProvider.syncNow(1);

    expect(arkService.calls, ['maintenance', 'snapshot(address: tark1shown)']);
    expect(arkRepository.getSnapshot(1)!.vtxos, hasLength(2));
    expect(arkProvider.snapshot(1)!.vtxos, hasLength(2));
  });

  test('a failed server sync still refreshes the cache from bark', () async {
    arkService.openWallets.add(_fingerprint.toLowerCase());
    arkService.maintenanceError = Exception('server unreachable');

    await arkProvider.syncNow(1);

    expect(arkProvider.syncError(1), contains('server unreachable'));
    expect(arkRepository.getSnapshot(1), isNotNull);
  });

  test('a locked wallet is not synced', () async {
    await arkProvider.syncNow(1);

    expect(arkService.calls, isEmpty);
  });

  test('cancelling the unlock leaves the wallet locked and stops automatic prompts', () async {
    expect(arkProvider.shouldAutoUnlock(1), isTrue);

    final opened = await arkProvider.open(1, () async => null);

    expect(opened, isFalse);
    expect(arkProvider.isOpen(1), isFalse);
    expect(arkProvider.shouldAutoUnlock(1), isFalse);
    expect(arkService.calls, isEmpty);
  });

  test('unlocking opens an existing Ark wallet, or creates one with recovery when missing', () async {
    expect(await arkProvider.open(1, () async => 'ab' * 64), isTrue);
    expect(arkService.calls.first, 'create(restore: true)');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    arkService.openWallets.clear();
    arkService.calls.clear();
    expect(await arkProvider.open(1, () async => 'ab' * 64), isTrue);
    expect(arkService.calls.first, 'open');
    expect(arkProvider.isOpen(1), isTrue);
  });

  test('concurrent unlock requests share one prompt', () async {
    var prompts = 0;
    Future<String?> unlock() async {
      prompts++;
      return 'ab' * 64;
    }

    final results = await Future.wait([arkProvider.open(1, unlock), arkProvider.open(1, unlock)]);

    expect(results, [true, true]);
    expect(prompts, 1);
  });

  test('watch-only wallets have no Ark side', () async {
    final watchOnly = SinglesigWalletItem(id: 2, name: 'Watch', colorIndex: 0, iconIndex: 0, descriptor: _descriptor);
    walletProvider.walletItemListNotifier.value = [_hotWallet(1), watchOnly];

    expect(arkProvider.supportsArkById(2), isFalse);
    expect(arkProvider.snapshot(2), isNull);
    expect(arkProvider.totalSats(2), 0);
  });
}
