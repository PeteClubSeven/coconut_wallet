import 'package:coconut_lib/coconut_lib.dart';
import 'package:coconut_wallet/config/number_format_config.dart';
import 'package:coconut_wallet/constants/dust_constants.dart';
import 'package:coconut_wallet/core/exceptions/transaction_creation/transaction_creation_exception.dart';
import 'package:coconut_wallet/core/transaction/transaction_builder.dart';
import 'package:coconut_wallet/enums/wallet_enums.dart';
import 'package:coconut_wallet/model/ark/ark_board.dart';
import 'package:coconut_wallet/model/ark/ark_payment.dart';
import 'package:coconut_wallet/model/utxo/utxo_state.dart';
import 'package:coconut_wallet/model/wallet/wallet_item_base.dart';
import 'package:coconut_wallet/providers/ark_provider.dart';
import 'package:coconut_wallet/providers/send_info_provider.dart';
import 'package:coconut_wallet/services/fee_service.dart';
import 'package:coconut_wallet/services/model/response/recommended_fee.dart';
import 'package:coconut_wallet/utils/address_util.dart';
import 'package:coconut_wallet/utils/fee_rate_mixin.dart';
import 'package:coconut_wallet/utils/payment_request_parser.dart';
import 'package:flutter/widgets.dart';

/// A way to pay a recipient: from the wallet's UTXOs ([SendOptionKind.onchain]) or from its Ark
/// balance (the others).
enum SendOptionKind { ark, lightning, onchain, onchainViaArk }

class SendOption {
  const SendOption(this.kind, this.destination, {this.rail});

  final SendOptionKind kind;
  final String destination;

  /// How Ark pays it; null for [SendOptionKind.onchain].
  final ArkPaymentRail? rail;

  bool get usesArk => kind != SendOptionKind.onchain;
}

/// Whether an option can be used right now, and what it costs.
class SendOptionStatus {
  const SendOptionStatus({this.feeSats, this.isEstimating = false, this.problem, this.canUnlock = false});

  final int? feeSats;
  final bool isEstimating;

  /// Why it can't be used now, if it can't.
  final String? problem;

  /// The problem is a locked Ark wallet, which the user can unlock.
  final bool canUnlock;

  bool get isReady => problem == null && !isEstimating && feeSats != null;
}

/// Another on-chain recipient in the same transaction.
class SendRecipient {
  const SendRecipient(this.address, this.amountSats);

  final String address;
  final int amountSats;
}

/// What the options need from the wallet's Ark side, so tests can fake it.
abstract class SendArkAccess {
  bool get isSupported;
  bool get isOpen;
  int get spendableSats;
  Future<int> estimateFee(ArkPaymentRail rail, String destination, int amountSats);
  Future<bool> validateAddress(String address);
}

class ArkProviderSendAccess implements SendArkAccess {
  ArkProviderSendAccess(this._arkProvider, this._walletId);

  final ArkProvider _arkProvider;
  final int _walletId;

  @override
  bool get isSupported => _arkProvider.supportsArkById(_walletId);
  @override
  bool get isOpen => _arkProvider.isOpen(_walletId);
  @override
  int get spendableSats => _arkProvider.balance(_walletId)?.spendable ?? 0;
  @override
  Future<int> estimateFee(ArkPaymentRail rail, String destination, int amountSats) =>
      _arkProvider.estimatePaymentFee(_walletId, rail, destination: destination, amountSats: amountSats);
  @override
  Future<bool> validateAddress(String address) => _arkProvider.validateArkAddress(_walletId, address);
}

/// The second step of Send for a hot wallet with Ark: the amount and the ways to pay a recipient.
/// The on-chain way builds the transaction here (UTXOs, fee rate, extra recipients, Max) and
/// hands it to the confirm screen; the Ark ways are paid by the screen through [ArkProvider].
class SendOptionsViewModel extends ChangeNotifier with FeeRateMixin {
  SendOptionsViewModel({
    required this.request,
    required WalletItemBase wallet,
    required List<UtxoState> utxos,
    required String changeDerivationPath,
    required SendArkAccess ark,
    required SendInfoProvider sendInfoProvider,
    NetworkType? network,
    Future<RecommendedFee?> Function()? loadRecommendedFees,
  }) : _wallet = wallet,
       _unspentUtxos = utxos.where((utxo) => utxo.status == UtxoStatus.unspent).toList(),
       _changeDerivationPath = changeDerivationPath,
       _ark = ark,
       _sendInfoProvider = sendInfoProvider,
       _network = network ?? NetworkType.currentNetworkType,
       _loadRecommendedFees = loadRecommendedFees ?? FeeService().getRecommendedFees {
    options = _optionsFor(request);
    feeRateController.addListener(_onFeeRateTextChanged);
    _refresh();
  }

  final PaymentRequest request;
  final WalletItemBase _wallet;
  final List<UtxoState> _unspentUtxos;
  final String _changeDerivationPath;
  final SendArkAccess _ark;
  final SendInfoProvider _sendInfoProvider;
  final NetworkType _network;
  final Future<RecommendedFee?> Function() _loadRecommendedFees;

  late final List<SendOption> options;

  final TextEditingController feeRateController = TextEditingController();
  final FocusNode feeRateFocusNode = FocusNode();

  int? _enteredAmountSats;
  bool _isMaxMode = false;
  List<UtxoState>? _selectedUtxos;
  double? _feeRate;
  final List<SendRecipient> _extraRecipients = [];

  TransactionBuildResult? _onchainResult;
  final Map<SendOptionKind, String> _arkKeys = {};
  final Map<SendOptionKind, int> _arkFees = {};
  final Map<SendOptionKind, String> _arkProblems = {};
  final Set<SendOptionKind> _arkEstimating = {};

  SendOption? _selected;
  bool _userSelected = false;
  bool _disposed = false;

  RecommendedFeeFetchStatus _feeFetchStatus = RecommendedFeeFetchStatus.fetching;

  static List<SendOption> _optionsFor(PaymentRequest request) => [
    if (request.arkAddress != null) SendOption(SendOptionKind.ark, request.arkAddress!, rail: ArkPaymentRail.ark),
    if (request.lightningInvoice != null)
      SendOption(SendOptionKind.lightning, request.lightningInvoice!, rail: ArkPaymentRail.lightningInvoice)
    else if (request.lightningAddress != null)
      SendOption(SendOptionKind.lightning, request.lightningAddress!, rail: ArkPaymentRail.lightningAddress),
    if (request.bitcoinAddress != null) ...[
      SendOption(SendOptionKind.onchain, request.bitcoinAddress!),
      SendOption(SendOptionKind.onchainViaArk, request.bitcoinAddress!, rail: ArkPaymentRail.onchain),
    ],
  ];

  // --- Amount ---

  /// The amount the request carries (an invoice's, or a BIP321 `amount`), which can't be changed.
  int? get fixedAmountSats => request.amountSats;

  bool get isMaxMode => _isMaxMode;

  bool get canUseMax => fixedAmountSats == null && onchainOption != null;

  /// What the main recipient gets: the fixed or entered amount, or with Max what's left of the
  /// on-chain funds after the other recipients and the fee.
  int? get amountSats {
    if (_isMaxMode) {
      final fee = onchainFeeSats;
      return fee == null ? null : onchainAvailableSats - _extraTotal - fee;
    }
    return fixedAmountSats ?? _enteredAmountSats;
  }

  void setEnteredAmount(int? sats) {
    if (fixedAmountSats != null) return;
    if (_enteredAmountSats == sats && !_isMaxMode) return;
    _enteredAmountSats = sats;
    _isMaxMode = false;
    _refresh();
  }

  void setMaxMode(bool enabled) {
    if (!canUseMax || _isMaxMode == enabled) return;
    _isMaxMode = enabled;
    if (enabled) {
      _selected = onchainOption;
      _userSelected = true;
    }
    _refresh();
  }

  // --- Balances ---

  int get arkSpendableSats => _ark.isSupported ? _ark.spendableSats : 0;

  bool get isUtxoAuto => _selectedUtxos == null;
  List<UtxoState> get selectedUtxos => _selectedUtxos ?? const [];
  List<UtxoState> get unspentUtxos => _unspentUtxos;

  /// The wallet's confirmed balance, or the picked UTXOs' total.
  int get onchainAvailableSats => _sum(_selectedUtxos ?? _unspentUtxos);

  bool get showsOnchainBalance => onchainOption != null;
  bool get showsArkBalance => options.any((option) => option.usesArk);

  /// An empty list goes back to automatic selection.
  void setSelectedUtxos(List<UtxoState> utxos) {
    _selectedUtxos = utxos.isEmpty ? null : List.of(utxos);
    _refresh();
  }

  // --- Fee rate ---

  double? get feeRate => _feeRate;

  @override
  RecommendedFeeFetchStatus get recommendedFeeFetchStatus => _feeFetchStatus;

  /// Loads the recommended rates and starts at the half-hour one unless a rate was set.
  Future<void> refreshRecommendedFees() async {
    _feeFetchStatus = RecommendedFeeFetchStatus.fetching;
    _notify();
    final fees = await _loadRecommendedFees();
    if (_disposed) return;
    if (fees == null) {
      _feeFetchStatus = RecommendedFeeFetchStatus.failed;
      _notify();
      return;
    }
    feeInfos[0].satsPerVb = fees.fastestFee;
    feeInfos[1].satsPerVb = fees.halfHourFee;
    feeInfos[2].satsPerVb = fees.hourFee;
    _feeFetchStatus = RecommendedFeeFetchStatus.succeed;
    if (_feeRate == null && fees.halfHourFee != null) setFeeRateFromRecommendation(fees.halfHourFee!);
    _notify();
  }

  /// For the fee sheet's field: true when the rate typed is below the minimum.
  bool onFeeRateChanged(String text) => handleFeeRateChanged(text, (_) {});

  void setFeeRateFromRecommendation(double satsPerVb) {
    feeRateController.text = _formatFeeRate(satsPerVb);
  }

  /// After the fee sheet closes: no trailing separator, and never a zero rate.
  void tidyFeeRate() {
    final text = removeTrailingDotInFeeRateText(feeRateController.text);
    if (text != feeRateController.text) feeRateController.text = text;
    final parsed = double.tryParse(normalizeNumTextForNumParsing(feeRateController.text));
    if ((parsed == null || parsed <= 0) && _feeRate != null) feeRateController.text = _formatFeeRate(_feeRate!);
  }

  static String _formatFeeRate(double satsPerVb) {
    final text = satsPerVb == satsPerVb.roundToDouble() ? satsPerVb.toStringAsFixed(0) : satsPerVb.toString();
    return text.replaceAll('.', NumberFormatConfig.instance.decimalSeparator);
  }

  void _onFeeRateTextChanged() {
    final parsed = double.tryParse(normalizeNumTextForNumParsing(feeRateController.text));
    if (parsed == null || parsed <= 0 || parsed == _feeRate) return;
    _feeRate = parsed;
    _refresh();
  }

  // --- Extra recipients ---

  List<SendRecipient> get extraRecipients => List.unmodifiable(_extraRecipients);

  int get _extraTotal => _extraRecipients.fold(0, (total, recipient) => total + recipient.amountSats);

  /// Adds an on-chain recipient, or returns why it can't be added.
  String? addRecipient(String input, int amountSats) {
    final option = onchainOption;
    if (option == null) return 'Only on-chain payments can have more recipients';
    final parsed = PaymentRequest.parse(input, _network);
    final address = parsed.bitcoinAddress;
    if (address == null) {
      return parsed.hasArkOrLightning
          ? 'Only Bitcoin addresses can be added: Ark pays one destination'
          : (parsed.problem ?? 'Not a Bitcoin address');
    }
    final normalized = normalizeAddress(address);
    final taken = {option.destination, ..._extraRecipients.map((recipient) => recipient.address)};
    if (taken.contains(normalized)) return 'This address is already a recipient';
    if (amountSats <= _dustThreshold) return 'The amount is below the dust limit';
    _extraRecipients.add(SendRecipient(normalized, amountSats));
    _selected = option;
    _userSelected = true;
    _refresh();
    return null;
  }

  void removeRecipient(int index) {
    if (index < 0 || index >= _extraRecipients.length) return;
    _extraRecipients.removeAt(index);
    _refresh();
  }

  // --- Options ---

  SendOption? get onchainOption => options.where((option) => option.kind == SendOptionKind.onchain).firstOrNull;

  SendOption? get selected => _selected;

  void select(SendOption option) {
    _selected = option;
    _userSelected = true;
    if (option.kind != SendOptionKind.onchain && _isMaxMode) {
      _isMaxMode = false;
      _refresh();
      return;
    }
    _notify();
  }

  /// Call when the Ark side changed (unlocked, synced), to refresh its options.
  void onArkChanged() => _refresh();

  int? get onchainFeeSats {
    final result = _onchainResult;
    if (result == null || !result.isSuccess) return null;
    return result.estimatedFee;
  }

  /// Change too small to keep, added to the fee.
  int? get unintendedDustFee => _onchainResult?.unintendedDustFee;

  SendOptionStatus statusOf(SendOption option) {
    if (option.kind == SendOptionKind.onchain) return _onchainStatus();
    if (!_ark.isSupported) return const SendOptionStatus(problem: 'This wallet has no Ark');
    if (_extraRecipients.isNotEmpty) return const SendOptionStatus(problem: 'Ark pays one destination');
    if (_isMaxMode) return const SendOptionStatus(problem: 'Max is for on-chain only');
    if (!_ark.isOpen) return const SendOptionStatus(problem: 'Ark is locked', canUnlock: true);
    final amount = amountSats;
    if (amount == null || amount <= 0) return const SendOptionStatus(problem: 'Enter an amount');
    if (option.kind == SendOptionKind.onchainViaArk && amount <= ArkBoardTerms.dustLimitSats) {
      return const SendOptionStatus(problem: 'The amount is below the dust limit');
    }
    if (_arkEstimating.contains(option.kind)) return const SendOptionStatus(isEstimating: true);
    final problem = _arkProblems[option.kind];
    if (problem != null) return SendOptionStatus(problem: problem);
    final fee = _arkFees[option.kind];
    if (fee == null) return const SendOptionStatus(isEstimating: true);
    if (amount + fee > _ark.spendableSats) return SendOptionStatus(feeSats: fee, problem: 'Not enough in Ark');
    return SendOptionStatus(feeSats: fee);
  }

  SendOptionStatus _onchainStatus() {
    if (onchainAvailableSats <= 0) return const SendOptionStatus(problem: 'No confirmed on-chain funds');
    if (_feeRate == null) {
      return SendOptionStatus(
        isEstimating: _feeFetchStatus == RecommendedFeeFetchStatus.fetching,
        problem: _feeFetchStatus == RecommendedFeeFetchStatus.fetching ? null : 'Set a fee rate',
      );
    }
    final amount = _isMaxMode ? null : amountSats;
    if (!_isMaxMode && (amount == null || amount <= 0)) return const SendOptionStatus(problem: 'Enter an amount');
    if (!_isMaxMode && amount! <= _dustThreshold) {
      return const SendOptionStatus(problem: 'The amount is below the dust limit');
    }
    final result = _onchainResult;
    if (result == null) return const SendOptionStatus(isEstimating: true);
    if (result.isSuccess) return SendOptionStatus(feeSats: result.estimatedFee);
    final error = result.exception;
    if (error is InsufficientBalanceException) return const SendOptionStatus(problem: 'Not enough on-chain');
    if (error is SendAmountTooLowException) return const SendOptionStatus(problem: 'Too small to cover the fee');
    return SendOptionStatus(problem: error?.toString() ?? 'Can\'t build the transaction');
  }

  /// Whether the selected option can go ahead.
  bool get canProceed {
    final option = _selected;
    return option != null && statusOf(option).isReady;
  }

  // --- On-chain hand-off ---

  /// Fills [SendInfoProvider] for the confirm screen with the built transaction.
  void saveOnchainForConfirm(SendEntryPoint entryPoint) {
    final transaction = _onchainResult?.transaction;
    if (transaction == null || _feeRate == null) throw StateError('No on-chain transaction to confirm');
    _sendInfoProvider.clear();
    _sendInfoProvider.setSendEntryPoint(entryPoint);
    _sendInfoProvider.setWalletId(_wallet.id);
    _sendInfoProvider.setTransaction(transaction);
    _sendInfoProvider.setIsMultisig(_wallet.walletType == WalletType.multiSignature);
    _sendInfoProvider.setWalletImportSource(_wallet.walletImportSource);
    _sendInfoProvider.setFeeRate(_feeRate!);
    _sendInfoProvider.setIsMaxMode(_isMaxMode);
  }

  // --- Internals ---

  int get _dustThreshold => _wallet.walletType.addressType.dustThreshold;

  static int _sum(List<UtxoState> utxos) => utxos.fold(0, (total, utxo) => total + utxo.amount);

  void _refresh() {
    _buildOnchain();
    _estimateArk();
    _autoSelect();
    _notify();
  }

  void _buildOnchain() {
    _onchainResult = null;
    final option = onchainOption;
    final feeRate = _feeRate;
    if (option == null || feeRate == null || onchainAvailableSats <= 0) return;
    final Map<String, int> recipients;
    if (_isMaxMode) {
      final rest = onchainAvailableSats - _extraTotal;
      if (rest <= _dustThreshold) {
        _onchainResult = const TransactionBuildResult(
          transaction: null,
          selectedUtxos: null,
          estimatedFee: 0,
          exception: SendAmountTooLowException(estimatedFee: 0),
        );
        return;
      }
      // The builder takes the fee from the last recipient, so the Max one goes last.
      recipients = {for (final recipient in _extraRecipients) recipient.address: recipient.amountSats};
      recipients[option.destination] = rest;
    } else {
      final amount = amountSats;
      if (amount == null || amount <= _dustThreshold) return;
      recipients = {
        option.destination: amount,
        for (final recipient in _extraRecipients) recipient.address: recipient.amountSats,
      };
    }
    _onchainResult =
        TransactionBuilder(
          availableUtxos: _selectedUtxos ?? _unspentUtxos,
          recipients: recipients,
          feeRate: feeRate,
          changeDerivationPath: _changeDerivationPath,
          walletItemBase: _wallet,
          isFeeSubtractedFromAmount: _isMaxMode,
          isUtxoFixed: _selectedUtxos != null,
        ).build();
  }

  void _estimateArk() {
    final amount = amountSats;
    for (final option in options.where((option) => option.usesArk)) {
      final kind = option.kind;
      final blocked =
          !_ark.isSupported ||
          !_ark.isOpen ||
          _isMaxMode ||
          amount == null ||
          amount <= 0 ||
          (kind == SendOptionKind.onchainViaArk && amount <= ArkBoardTerms.dustLimitSats);
      if (blocked) {
        _arkKeys.remove(kind);
        _arkEstimating.remove(kind);
        continue;
      }
      final key = '${option.destination}:$amount';
      if (_arkKeys[kind] == key) continue;
      _arkKeys[kind] = key;
      _arkEstimating.add(kind);
      _arkFees.remove(kind);
      _arkProblems.remove(kind);
      _estimateOne(option, amount, key);
    }
  }

  Future<void> _estimateOne(SendOption option, int amount, String key) async {
    int? fee;
    String? problem;
    try {
      if (option.kind == SendOptionKind.ark && !await _ark.validateAddress(option.destination)) {
        problem = 'bark doesn\'t accept this Ark address (another Ark server or network?)';
      } else {
        fee = await _ark.estimateFee(option.rail!, option.destination, amount);
      }
    } catch (error) {
      problem = 'Could not estimate the fee: $error';
    }
    if (_disposed || _arkKeys[option.kind] != key) return;
    _arkEstimating.remove(option.kind);
    if (fee != null) _arkFees[option.kind] = fee;
    if (problem != null) _arkProblems[option.kind] = problem;
    _autoSelect();
    _notify();
  }

  /// Until the user picks one, the cheapest option that can be paid; ties go by the options' order
  /// (Ark, Lightning, on-chain, on-chain via Ark).
  void _autoSelect() {
    if (_userSelected && _selected != null) return;
    SendOption? best;
    int? bestFee;
    for (final option in options) {
      final status = statusOf(option);
      if (!status.isReady) continue;
      if (bestFee == null || status.feeSats! < bestFee) {
        best = option;
        bestFee = status.feeSats;
      }
    }
    _selected = best ?? _selected ?? options.firstOrNull;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    feeRateController.removeListener(_onFeeRateTextChanged);
    feeRateController.dispose();
    feeRateFocusNode.dispose();
    super.dispose();
  }
}
