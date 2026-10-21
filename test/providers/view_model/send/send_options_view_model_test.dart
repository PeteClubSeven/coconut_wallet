import 'dart:async';

import 'package:coconut_lib/coconut_lib.dart';
import 'package:coconut_wallet/model/ark/ark_payment.dart';
import 'package:coconut_wallet/model/utxo/utxo_state.dart';
import 'package:coconut_wallet/providers/send_info_provider.dart';
import 'package:coconut_wallet/providers/view_model/send/send_options_view_model.dart';
import 'package:coconut_wallet/services/model/response/recommended_fee.dart';
import 'package:coconut_wallet/utils/payment_request_parser.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../mock/wallet_mock.dart';

const _bitcoin = 'bcrt1q7kcrvjzszlxme7fgs2euvv6lkgf99jdu8zjnus';
const _otherBitcoin = 'bcrt1qve37yvsmqksx93j6gqsnz862qpzfa0xya0yvve';
const _ark =
    'tark1pqma5v23zqqp5z47f6anpx0lp5vu757p3cnxzqx887t8zl3wacuvdgyeyee2puh3zqypf2680f7z8zau5ukptjaa7suxu0vadk0ncdyw4qdeazs9u29fddycffu4m9';
const _invoice =
    'lnbcrt300u1p4dtlwusp5nptqcasatxvy082yctgkamwtewxfdnuh3eemk48utk2cp6zz9umspp50rc6tq4889yrpqt5tlmssthes5qxrfzh3qh93fqm8h00j3sav27sdqqxqy9gcqcqzgq9qyysgqcjnlnm5mwfsf09uvnjraxzwj04c2l9gtduntevk95pec3vvkglv9wqu57rnw3mz8t37add2fsrs44llju7ncaty67ay3d2x9kayxxcsqertrwr';

class _FakeArk implements SendArkAccess {
  @override
  bool isSupported = true;
  @override
  bool isOpen = true;
  @override
  int spendableSats = 100000;
  bool acceptsAddress = true;
  final Map<ArkPaymentRail, int> fees = {
    ArkPaymentRail.ark: 0,
    ArkPaymentRail.lightningInvoice: 48,
    ArkPaymentRail.lightningAddress: 48,
    ArkPaymentRail.onchain: 2530,
  };

  /// When set, estimates wait for the test to complete them, in order.
  List<Completer<int>>? pending;
  final List<int> estimatedAmounts = [];

  @override
  Future<int> estimateFee(ArkPaymentRail rail, String destination, int amountSats) {
    estimatedAmounts.add(amountSats);
    if (pending != null) {
      final completer = Completer<int>();
      pending!.add(completer);
      return completer.future;
    }
    return Future.value(fees[rail]!);
  }

  @override
  Future<bool> validateAddress(String address) async => acceptsAddress;
}

UtxoState _utxo(int index, int amount) => UtxoState(
  transactionHash:
      index.isEven
          ? 'd77dc64d3eb3454e9c65e5e36989af0eef349d824593dfe2a086fb9dadf7dfc4'
          : '577a101d9bddd1ddee0d72a0853a8ca2d8b13d92c63f9a84277152ba791e426a',
  index: index,
  amount: amount,
  blockHeight: 100 + index,
  to: 'bcrt1qh22yl57ys0vaaln9nfp4zczj2fshjnl6gnsh66',
  derivationPath: "m/84'/1'/0'/0/$index",
  timestamp: DateTime(2026, 10, 19),
);

void main() {
  setUpAll(() => NetworkType.setNetworkType(NetworkType.regtest));

  final utxos = [_utxo(0, 100000), _utxo(1, 200000)];
  late _FakeArk ark;
  late SendInfoProvider sendInfo;

  setUp(() {
    ark = _FakeArk();
    sendInfo = SendInfoProvider();
  });

  SendOptionsViewModel createMany(
    List<(String, int?)> recipients, {
    bool maxLast = false,
    List<UtxoState>? walletUtxos,
    RecommendedFee? fees,
  }) => SendOptionsViewModel(
    recipients: [
      for (final (input, amount) in recipients)
        SendRecipientInput(PaymentRequest.parse(input, NetworkType.regtest), amount),
    ],
    maxLast: maxLast,
    wallet: WalletMock.createSingleSigWalletItem(),
    utxos: walletUtxos ?? utxos,
    changeDerivationPath: "m/84'/1'/0'/1/0",
    ark: ark,
    sendInfoProvider: sendInfo,
    loadRecommendedFees: () async => fees,
  );

  SendOptionsViewModel create(String input, {int? amount, RecommendedFee? fees}) =>
      createMany([(input, amount ?? PaymentRequest.parse(input, NetworkType.regtest).amountSats)], fees: fees);

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  List<SendOptionKind> kinds(SendOptionsViewModel vm) => vm.options.map((option) => option.kind).toList();

  test('one recipient can be paid every way its request allows', () {
    expect(kinds(create(_bitcoin, amount: 1000)), [SendOptionKind.onchain, SendOptionKind.onchainViaArk]);
    expect(kinds(create(_ark, amount: 1000)), [SendOptionKind.ark]);
    expect(kinds(create(_invoice)), [SendOptionKind.lightning]);
    expect(kinds(create('satoshi@example.com', amount: 1000)), [SendOptionKind.lightning]);
    expect(kinds(create('bitcoin:$_bitcoin?amount=0.0001&ark=$_ark&lightning=$_invoice')), [
      SendOptionKind.ark,
      SendOptionKind.lightning,
      SendOptionKind.onchain,
      SendOptionKind.onchainViaArk,
    ]);
    expect(create('satoshi@example.com', amount: 1000).options.single.rail, ArkPaymentRail.lightningAddress);
    expect(create(_invoice).amountSats, 30000);
  });

  test('several recipients, or Max, are on-chain only', () {
    final several = createMany([(_bitcoin, 10000), ('bitcoin:$_otherBitcoin?ark=$_ark', 20000)]);
    expect(kinds(several), [SendOptionKind.onchain]);
    expect(several.isBatch, isTrue);

    final max = createMany([('bitcoin:$_bitcoin?ark=$_ark', null)], maxLast: true);
    expect(kinds(max), [SendOptionKind.onchain]);
    expect(max.isMaxMode, isTrue);
  });

  test('balances follow the UTXOs picked', () {
    final vm = create(_bitcoin, amount: 1000);
    expect(vm.onchainAvailableSats, 300000);
    expect(vm.arkSpendableSats, 100000);
    expect(vm.isUtxoAuto, isTrue);

    vm.setSelectedUtxos([utxos.first]);
    expect(vm.isUtxoAuto, isFalse);
    expect(vm.onchainAvailableSats, 100000);

    vm.setSelectedUtxos([]);
    expect(vm.isUtxoAuto, isTrue);
    expect(vm.onchainAvailableSats, 300000);
  });

  test('the on-chain fee follows the UTXOs and fee rate', () async {
    final vm = create(_bitcoin, amount: 50000, fees: RecommendedFee(10, 2, 1, 1, 1));
    expect(vm.statusOf(vm.onchainOption!).isEstimating, isTrue); // no fee rate yet

    await vm.refreshRecommendedFees();
    expect(vm.feeRate, 2);
    final atTwo = vm.statusOf(vm.onchainOption!).feeSats!;
    expect(atTwo, greaterThan(0));

    vm.setFeeRateFromRecommendation(10);
    final atTen = vm.statusOf(vm.onchainOption!).feeSats!;
    expect(atTen, greaterThan(atTwo));

    vm.setSelectedUtxos(utxos);
    expect(vm.statusOf(vm.onchainOption!).feeSats!, greaterThan(atTen)); // two inputs

    final tooMuch = create(_bitcoin, amount: 400000, fees: RecommendedFee(1, 1, 1, 1, 1));
    await tooMuch.refreshRecommendedFees();
    expect(tooMuch.statusOf(tooMuch.onchainOption!).problem, SendOptionProblem.notEnoughOnchain);
  });

  test('without recommended fees the user has to set a rate', () async {
    final vm = create(_bitcoin, amount: 50000);
    await vm.refreshRecommendedFees();
    expect(vm.statusOf(vm.onchainOption!).problem, SendOptionProblem.needsFeeRate);
    vm.feeRateController.text = '3';
    expect(vm.feeRate, 3);
    expect(vm.statusOf(vm.onchainOption!).isReady, isTrue);
  });

  test('Max gives the last recipient what the picked UTXOs hold, less the others and the fee', () async {
    final single = createMany([(_bitcoin, null)], maxLast: true, fees: RecommendedFee(1, 1, 1, 1, 1));
    await single.refreshRecommendedFees();
    single.setSelectedUtxos([utxos.last]);
    expect(single.amountSats, 200000 - single.onchainFeeSats!);
    expect(single.totalSats, 200000 - single.onchainFeeSats!);

    final several = createMany(
      [(_otherBitcoin, 50000), (_bitcoin, null)],
      maxLast: true,
      fees: RecommendedFee(1, 1, 1, 1, 1),
    );
    await several.refreshRecommendedFees();
    several.setSelectedUtxos([utxos.last]);
    expect(several.amountOf(0), 50000);
    expect(several.amountOf(1), 200000 - 50000 - several.onchainFeeSats!);
    expect(several.statusOf(several.onchainOption!).isReady, isTrue);
    several.saveOnchainForConfirm(SendEntryPoint.walletDetail);
    expect(sendInfo.isMaxMode, isTrue);
  });

  test('Ark options say why they can\'t be used', () async {
    ark.isOpen = false;
    final locked = create(_bitcoin, amount: 20000);
    final viaArk = locked.options.last;
    expect(locked.statusOf(viaArk).problem, SendOptionProblem.arkLocked);
    expect(locked.statusOf(viaArk).canUnlock, isTrue);

    ark.isOpen = true;
    locked.onArkChanged();
    await settle();
    expect(locked.statusOf(viaArk).isReady, isTrue);

    expect(create(_bitcoin, amount: 200).statusOf(viaArk).problem, SendOptionProblem.belowDust);

    final short = create(_bitcoin, amount: 99000);
    await settle();
    expect(short.statusOf(viaArk).problem, SendOptionProblem.notEnoughArk); // 99,000 + 2,530 > 100,000

    ark.acceptsAddress = false;
    final arkVm = create(_ark, amount: 1000);
    await settle();
    expect(arkVm.statusOf(arkVm.options.single).problem, SendOptionProblem.arkAddressRefused);

    ark.isSupported = false;
    expect(create(_ark, amount: 1000).statusOf(arkVm.options.single).problem, SendOptionProblem.noArk);
  });

  test('the cheapest option that can be paid is preselected until the user picks one', () async {
    final vm = create('bitcoin:$_bitcoin?amount=0.0002&ark=$_ark&lightning=$_invoice');
    await settle();
    expect(vm.selected!.kind, SendOptionKind.ark);

    ark.fees[ArkPaymentRail.ark] = 100;
    final dearArk = create('bitcoin:?amount=0.0002&ark=$_ark&lightning=$_invoice');
    await settle();
    expect(dearArk.selected!.kind, SendOptionKind.lightning);

    ark.fees[ArkPaymentRail.ark] = 48;
    final tie = create('bitcoin:?amount=0.0002&ark=$_ark&lightning=$_invoice');
    await settle();
    expect(tie.selected!.kind, SendOptionKind.ark); // the earlier option wins a tie

    final picked = create(_bitcoin, amount: 20000, fees: RecommendedFee(1, 1, 1, 1, 1));
    await picked.refreshRecommendedFees();
    await settle();
    expect(picked.selected!.kind, SendOptionKind.onchain); // a few hundred sats vs 2,530
    picked.select(picked.options.last);
    picked.onArkChanged();
    await settle();
    expect(picked.selected!.kind, SendOptionKind.onchainViaArk); // the user's pick is kept
  });

  test('an estimate that arrives after the screen closed is ignored', () async {
    ark.pending = [];
    final vm = create(_ark, amount: 10000);
    await settle();
    expect(ark.estimatedAmounts, [10000]);
    vm.dispose();
    ark.pending!.single.complete(7);
    await settle(); // no notification after dispose
  });

  test('the on-chain transaction is handed to the confirm screen', () async {
    final vm = createMany([(_bitcoin, 50000), (_otherBitcoin, 30000)], fees: RecommendedFee(1, 1, 1, 1, 1));
    await vm.refreshRecommendedFees();
    expect(vm.totalSats, 80000);
    vm.saveOnchainForConfirm(SendEntryPoint.walletDetail);

    expect(sendInfo.walletId, 1);
    expect(sendInfo.sendEntryPoint, SendEntryPoint.walletDetail);
    expect(sendInfo.feeRate, 1);
    expect(sendInfo.isMaxMode, isFalse);
    expect(sendInfo.isMultisig, isFalse);
    final payments = sendInfo.transaction!.outputs.where((output) => output.isChangeOutput != true);
    expect(payments.map((output) => output.amount).toList()..sort(), [30000, 50000]);
  });
}
