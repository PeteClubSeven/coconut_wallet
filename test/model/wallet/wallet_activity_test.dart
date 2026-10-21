import 'package:coconut_wallet/enums/network_enums.dart';
import 'package:coconut_wallet/enums/transaction_enums.dart';
import 'package:coconut_wallet/model/ark/ark_movement.dart';
import 'package:coconut_wallet/model/wallet/wallet_activity.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../mock/ark/ark_fixtures.dart';
import '../../mock/transaction_record_mock.dart';

void main() {
  DateTime at(int hour) => DateTime.utc(2026, 10, 19, hour);

  test('merge lists pending entries first, then newest first, across both histories', () {
    final transactions = [
      TransactionRecordMock.createMockTransactionRecord(
        transactionHash: 'confirmed-10h',
        timestamp: at(10),
        blockHeight: 100,
        inputAddressList: const [],
        outputAddressList: const [],
      ),
      TransactionRecordMock.createMockTransactionRecord(
        transactionHash: 'pending-onchain',
        blockHeight: 0,
        createdAt: at(9),
        inputAddressList: const [],
        outputAddressList: const [],
      ),
    ];
    final movements = [
      createArkMovement(id: 1, createdAt: at(12)),
      createArkMovement(id: 2, createdAt: at(8)),
      createArkMovement(id: 3, createdAt: at(11), status: ArkMovementStatus.pending),
      createArkMovement(id: 4, createdAt: at(13), status: ArkMovementStatus.canceled, effectiveBalanceSats: 0),
    ];

    final merged = WalletActivity.merge(transactions, movements);

    expect(merged.map((activity) => activity.key), ['ark:3', 'pending-onchain', 'ark:1', 'confirmed-10h', 'ark:2']);
  });

  test('Ark movements map to the transaction statuses rows already show', () {
    expect(ArkActivity(createArkMovement(effectiveBalanceSats: 1000)).status, TransactionStatus.received);
    expect(
      ArkActivity(createArkMovement(effectiveBalanceSats: 1000, status: ArkMovementStatus.pending)).status,
      TransactionStatus.receiving,
    );
    expect(
      ArkActivity(
        createArkMovement(subsystemName: 'bark.arkoor', subsystemKind: 'send', effectiveBalanceSats: -1000),
      ).status,
      TransactionStatus.sent,
    );
    final refresh = ArkActivity(
      createArkMovement(subsystemName: 'bark.round', subsystemKind: 'refresh', effectiveBalanceSats: -50),
    );
    expect(refresh.status, TransactionStatus.self);
    expect(refresh.statusLabel, 'Refresh');
    expect(ArkActivity(createArkMovement(subsystemName: 'bark.lightning_receive')).railLabel, 'Lightning');
  });

  test('equality follows the key and content, so unchanged lists diff as equal', () {
    final movement = createArkMovement(id: 5);
    expect(ArkActivity(movement), ArkActivity(movement));
    expect(ArkActivity(movement) == ArkActivity(createArkMovement(id: 5, status: ArkMovementStatus.pending)), isFalse);
    final tx = TransactionRecordMock.createMockTransactionRecord(
      transactionType: TransactionType.received,
      inputAddressList: const [],
      outputAddressList: const [],
    );
    expect(OnchainActivity(tx), OnchainActivity(tx));
  });
}
