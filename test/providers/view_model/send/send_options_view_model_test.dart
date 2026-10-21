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

  SendOptionsViewModel create(String input, {List<UtxoState>? walletUtxos, RecommendedFee? fees}) =>
      SendOptionsViewModel(
        request: PaymentRequest.parse(input, NetworkType.regtest),
        wallet: WalletMock.createSingleSigWalletItem(),
        utxos: walletUtxos ?? utxos,
        changeDerivationPath: "m/84'/1'/0'/1/0",
        ark: ark,
        sendInfoProvider: sendInfo,
        network: NetworkType.regtest,
        loadRecommendedFees: () async => fees,
      );

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  List<SendOptionKind> kinds(SendOptionsViewModel vm) => vm.options.map((option) => option.kind).toList();

  test('each kind of request yields its ways to pay', () {
    expect(kinds(create(_bitcoin)), [SendOptionKind.onchain, SendOptionKind.onchainViaArk]);
    expect(kinds(create(_ark)), [SendOptionKind.ark]);
    expect(kinds(create(_invoice)), [SendOptionKind.lightning]);
    expect(kinds(create('satoshi@example.com')), [SendOptionKind.lightning]);
    expect(kinds(create('bitcoin:$_bitcoin?amount=0.0001&ark=$_ark&lightning=$_invoice')), [
      SendOptionKind.ark,
      SendOptionKind.lightning,
      SendOptionKind.onchain,
      SendOptionKind.onchainViaArk,
    ]);
    final lightningAddress = create('satoshi@example.com').options.single;
    expect(lightningAddress.rail, ArkPaymentRail.lightningAddress);
  });

  test('an invoice fixes the amount; anything else takes the amount entered', () async {
    final invoice = create(_invoice);
    invoice.setEnteredAmount(5000);
    expect(invoice.amountSats, 30000);
    expect(invoice.canUseMax, isFalse);

    final address = create(_bitcoin);
    expect(address.amountSats, isNull);
    address.setEnteredAmount(20000);
    expect(address.amountSats, 20000);
    expect(address.canUseMax, isTrue);
  });

  test('balances follow the UTXOs picked', () {
    final vm = create(_bitcoin);
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

  test('the on-chain fee follows the amount, UTXOs and fee rate', () async {
    final vm = create(_bitcoin, fees: RecommendedFee(10, 2, 1, 1, 1));
    vm.setEnteredAmount(50000);
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

    vm.setEnteredAmount(400000);
    expect(vm.statusOf(vm.onchainOption!).problem, 'Not enough on-chain');
  });

  test('without recommended fees the user has to set a rate', () async {
    final vm = create(_bitcoin);
    vm.setEnteredAmount(50000);
    await vm.refreshRecommendedFees();
    expect(vm.statusOf(vm.onchainOption!).problem, 'Set a fee rate');
    vm.feeRateController.text = '3';
    expect(vm.feeRate, 3);
    expect(vm.statusOf(vm.onchainOption!).isReady, isTrue);
  });

  test('Max sends what the picked UTXOs hold, less the fee and the other recipients', () async {
    final vm = create(_bitcoin, fees: RecommendedFee(1, 1, 1, 1, 1));
    await vm.refreshRecommendedFees();
    vm.setSelectedUtxos([utxos.last]);
    vm.setMaxMode(true);
    final fee = vm.onchainFeeSats!;
    expect(vm.amountSats, 200000 - fee);
    expect(vm.selected!.kind, SendOptionKind.onchain);
    expect(vm.statusOf(vm.options[1]).problem, 'Max is for on-chain only');

    expect(vm.addRecipient(_otherBitcoin, 50000), isNull);
    expect(vm.amountSats, 200000 - 50000 - vm.onchainFeeSats!);
    expect(vm.statusOf(vm.onchainOption!).isReady, isTrue);

    vm.setEnteredAmount(10000);
    expect(vm.isMaxMode, isFalse);
    expect(vm.amountSats, 10000);
  });

  test('more recipients are on-chain only', () async {
    final vm = create('bitcoin:$_bitcoin?ark=$_ark', fees: RecommendedFee(1, 1, 1, 1, 1));
    await vm.refreshRecommendedFees();
    vm.setEnteredAmount(20000);
    await settle();
    expect(vm.selected!.kind, SendOptionKind.ark); // cheapest

    expect(vm.addRecipient(_ark, 10000), startsWith('Only Bitcoin addresses'));
    expect(vm.addRecipient(_invoice, 10000), startsWith('Only Bitcoin addresses'));
    expect(vm.addRecipient(_bitcoin, 10000), 'This address is already a recipient');
    expect(vm.addRecipient(_otherBitcoin, 100), 'The amount is below the dust limit');
    expect(vm.addRecipient('bitcoin:$_otherBitcoin?amount=0.0001', 10000), isNull);
    expect(vm.addRecipient(_otherBitcoin, 10000), 'This address is already a recipient');

    expect(vm.extraRecipients.single.address, _otherBitcoin);
    expect(vm.selected!.kind, SendOptionKind.onchain);
    expect(vm.statusOf(vm.options.first).problem, 'Ark pays one destination');
    expect(vm.statusOf(vm.onchainOption!).isReady, isTrue);

    vm.removeRecipient(0);
    expect(vm.extraRecipients, isEmpty);
    await settle();
    expect(vm.statusOf(vm.options.first).isReady, isTrue);
  });

  test('Ark options say why they can\'t be used', () async {
    ark.isOpen = false;
    final vm = create(_bitcoin);
    vm.setEnteredAmount(200);
    final viaArk = vm.options.last;
    expect(vm.statusOf(viaArk).problem, 'Ark is locked');
    expect(vm.statusOf(viaArk).canUnlock, isTrue);

    ark.isOpen = true;
    vm.onArkChanged();
    expect(vm.statusOf(viaArk).problem, 'The amount is below the dust limit');

    vm.setEnteredAmount(99000);
    await settle();
    expect(vm.statusOf(viaArk).problem, 'Not enough in Ark'); // 99,000 + 2,530 > 100,000

    ark.acceptsAddress = false;
    final arkVm = create(_ark);
    arkVm.setEnteredAmount(1000);
    await settle();
    expect(arkVm.statusOf(arkVm.options.single).problem, contains('doesn\'t accept this Ark address'));

    ark.isSupported = false;
    expect(create(_ark).statusOf(arkVm.options.single).problem, 'This wallet has no Ark');
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

    final picked = create(_bitcoin, fees: RecommendedFee(1, 1, 1, 1, 1));
    await picked.refreshRecommendedFees();
    picked.setEnteredAmount(20000);
    await settle();
    expect(picked.selected!.kind, SendOptionKind.onchain); // a few hundred sats vs 2,530
    picked.select(picked.options.last);
    picked.setEnteredAmount(30000);
    await settle();
    expect(picked.selected!.kind, SendOptionKind.onchainViaArk); // the user's pick is kept
  });

  test('a late estimate for an old amount is ignored', () async {
    ark.pending = [];
    final vm = create(_ark);
    vm.setEnteredAmount(10000);
    vm.setEnteredAmount(20000);
    await settle();
    expect(ark.estimatedAmounts, [10000, 20000]);

    ark.pending![1].complete(7);
    await settle();
    ark.pending![0].complete(3);
    await settle();
    expect(vm.statusOf(vm.options.single).feeSats, 7);
  });

  test('the on-chain transaction is handed to the confirm screen', () async {
    final vm = create(_bitcoin, fees: RecommendedFee(1, 1, 1, 1, 1));
    await vm.refreshRecommendedFees();
    vm.setEnteredAmount(50000);
    expect(vm.addRecipient(_otherBitcoin, 30000), isNull);
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
