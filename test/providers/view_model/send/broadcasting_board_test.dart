import 'dart:typed_data';

import 'package:coconut_lib/coconut_lib.dart';
import 'package:coconut_wallet/model/ark/ark_board.dart';
import 'package:coconut_wallet/model/error/app_error.dart';
import 'package:coconut_wallet/model/wallet/singlesig_wallet_item.dart';
import 'package:coconut_wallet/model/wallet/transaction_record.dart';
import 'package:coconut_wallet/model/wallet/wallet_item_base.dart';
import 'package:coconut_wallet/providers/ark_provider.dart';
import 'package:coconut_wallet/providers/node_provider/node_provider.dart';
import 'package:coconut_wallet/providers/send_info_provider.dart';
import 'package:coconut_wallet/providers/transaction_provider.dart';
import 'package:coconut_wallet/providers/utxo_tag_provider.dart';
import 'package:coconut_wallet/providers/view_model/send/broadcasting_view_model.dart';
import 'package:coconut_wallet/providers/wallet_provider.dart';
import 'package:coconut_wallet/repository/realm/transaction_draft_repository.dart';
import 'package:coconut_wallet/repository/realm/utxo_repository.dart';
import 'package:coconut_wallet/services/model/response/block_timestamp.dart';
import 'package:coconut_wallet/utils/result.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../mock/utxo_mock.dart';
import '../../../repository/realm/test_realm_manager.dart';

const _inputHash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _funding = ArkBoardFunding(address: 'unused-here', expiryHeight: 9000, keypairIndex: 7);

class _WalletProvider extends Fake implements WalletProvider {
  _WalletProvider(this.wallet);

  final WalletItemBase wallet;

  @override
  WalletItemBase getWalletById(int id) => wallet;

  @override
  bool containsAddress(int walletId, String address, {bool? isChange}) => false;
}

class _NodeProvider extends Fake implements NodeProvider {
  final List<String> events;
  int failuresLeft = 0;
  bool knowsTransaction = false;

  _NodeProvider(this.events);

  @override
  Future<Result<String>> getTransaction(String txHash) async {
    events.add('electrum lookup');
    return knowsTransaction ? Result.success('rawtx') : Result.failure(ErrorCodes.broadcastError);
  }

  @override
  Future<Result<BlockTimestamp>> getLatestBlock() async => Result.success(BlockTimestamp(100, DateTime(2026)));

  @override
  Future<Result<String>> broadcast(Transaction signedTx) async {
    events.add('electrum broadcast');
    if (failuresLeft > 0) {
      failuresLeft--;
      return Result.failure(ErrorCodes.broadcastError);
    }
    return Result.success(signedTx.transactionHash);
  }
}

class _TransactionProvider extends Fake implements TransactionProvider {
  @override
  TransactionRecord? getTransactionRecord(int walletId, String txHash) => null;
}

class _ArkProvider extends Fake implements ArkProvider {
  final List<String> events;
  Object? boardError;
  String? boardedPsbt;

  _ArkProvider(this.events);

  @override
  Future<void> board(int walletId, {required String unsignedPsbtBase64, required ArkBoardFunding funding}) async {
    events.add('board(wallet $walletId, keypair ${funding.keypairIndex}, expiry ${funding.expiryHeight})');
    if (boardError != null) throw boardError!;
    boardedPsbt = unsignedPsbtBase64;
  }

  @override
  Future<String> broadcastTx(int walletId, String txHex) async {
    events.add('bark broadcast');
    return 'txid-from-bark';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestRealmManager manager;
  late UtxoRepository repository;
  late UtxoTagProvider tags;
  late SingleSignatureVault vault;
  late List<String> events;
  late _NodeProvider node;
  late _ArkProvider ark;

  setUpAll(() {
    NetworkType.setNetworkType(NetworkType.testnet);
    vault = SingleSignatureVault.fromEntropy(Uint8List(16));
  });

  setUp(() {
    manager = TestRealmManager();
    repository = UtxoRepository(manager);
    tags = UtxoTagProvider(repository);
    events = [];
    node = _NodeProvider(events);
    ark = _ArkProvider(events);
    manager.realm.write(() {
      manager.realm.add(
        UtxoMock.createUnspentRealmUtxo(walletId: 1, address: vault.getAddress(0), transactionHash: _inputHash),
      );
    });
  });

  tearDown(() {
    tags.dispose();
    manager.dispose();
  });

  /// A transaction paying an outside address, signed by [vault], as the send flow leaves it.
  Future<(BroadcastingViewModel, String)> prepare({ArkBoardIntent? board, String? unsignedOverride}) async {
    final transaction = Transaction.withInputsAndOutputs(
      [TransactionInput.forPayment(_inputHash, 0, sequence: 0xfffffffd)],
      [TransactionOutput.forPayment(999000, vault.getAddress(10))],
      AddressType.p2wpkh,
    );
    transaction.utxoList.add(Utxo(_inputHash, 0, 1000000, '${vault.derivationPath}/0/0'));
    final unsigned = Psbt.fromTransaction(transaction, vault).serialize();
    final signed = vault.addSignatureToPsbt(unsigned);
    final sendInfo =
        SendInfoProvider()
          ..setWalletId(1)
          ..setTxWaitingForSign(unsignedOverride ?? unsigned)
          ..setSignedResult(signed)
          ..setArkBoard(board);
    final viewModel = BroadcastingViewModel(
      sendInfo,
      _WalletProvider(
        SinglesigWalletItem(id: 1, name: 'Test', colorIndex: 0, iconIndex: 0, descriptor: vault.descriptor),
      ),
      tags,
      true,
      node,
      _TransactionProvider(),
      TransactionDraftRepository(manager),
      repository,
      null,
      arkProvider: ark,
    );
    addTearDown(viewModel.dispose);
    expect(await viewModel.setTxInfo(), isNull);
    return (viewModel, unsigned);
  }

  const board = ArkBoardIntent(walletId: 3, funding: _funding);

  test('a board is registered with the unsigned PSBT before the transaction is broadcast', () async {
    final (viewModel, unsigned) = await prepare(board: board);

    final result = await viewModel.broadcast(inheritedTagIds: const []);

    expect(result.isSuccess, isTrue);
    expect(events, ['board(wallet 3, keypair 7, expiry 9000)', 'electrum broadcast']);
    expect(ark.boardedPsbt, unsigned);
    expect(viewModel.canUseTransactionDrafts, isFalse);
  });

  test('nothing is broadcast when the Ark server rejects the board', () async {
    ark.boardError = Exception('cosign refused');
    final (viewModel, _) = await prepare(board: board);

    final result = await viewModel.broadcast(inheritedTagIds: const []);

    expect(result.isFailure, isTrue);
    expect(result.error.message, contains('cosign refused'));
    expect(events, ['board(wallet 3, keypair 7, expiry 9000)']);
  });

  test('a signed transaction that differs from the boarded PSBT never reaches the board', () async {
    final other = Transaction.withInputsAndOutputs(
      [TransactionInput.forPayment(_inputHash, 0, sequence: 0xfffffffd)],
      [TransactionOutput.forPayment(998000, vault.getAddress(11))],
      AddressType.p2wpkh,
    );
    other.utxoList.add(Utxo(_inputHash, 0, 1000000, '${vault.derivationPath}/0/0'));

    // Coconut's intent check rejects it while preparing; the board's txid check is a backstop.
    await expectLater(
      prepare(board: board, unsignedOverride: Psbt.fromTransaction(other, vault).serialize()),
      throwsA(anything),
    );
    expect(events, isEmpty);
  });

  test('a failed broadcast of a registered board is retried, then sent through bark', () async {
    node.failuresLeft = 2;
    final (viewModel, _) = await prepare(board: board);

    final result = await viewModel.broadcast(inheritedTagIds: const []);

    expect(result.isSuccess, isTrue);
    expect(events, [
      'board(wallet 3, keypair 7, expiry 9000)',
      'electrum broadcast',
      'electrum broadcast',
      'electrum lookup',
      'bark broadcast',
    ]);
  });

  test('a board funding transaction already on the network counts as broadcast', () async {
    // The first attempt went through but its reply was lost; the retry is rejected as a duplicate.
    node.failuresLeft = 2;
    node.knowsTransaction = true;
    final (viewModel, _) = await prepare(board: board);

    final result = await viewModel.broadcast(inheritedTagIds: const []);

    expect(result.isSuccess, isTrue);
    expect(result.value, viewModel.signedTx!.transactionHash);
    expect(events, [
      'board(wallet 3, keypair 7, expiry 9000)',
      'electrum broadcast',
      'electrum broadcast',
      'electrum lookup',
    ]);
  });

  test('a send without a board never touches Ark', () async {
    final (viewModel, _) = await prepare();

    final result = await viewModel.broadcast(inheritedTagIds: const []);

    expect(result.isSuccess, isTrue);
    expect(events, ['electrum broadcast']);
  });
}
