import 'package:coconut_lib/coconut_lib.dart';
import 'package:coconut_wallet/utils/address_util.dart';
import 'package:coconut_wallet/utils/payment_request_parser.dart';

/// Why a row of Send's first page can't be sent yet.
enum SendRecipientProblem {
  /// The destination can't be paid at all; the request's own problem says why.
  unsupported,

  /// One of several recipients without an on-chain address (Ark pays one destination).
  onchainOnly,
  duplicate,
  needsAmount,
}

/// One row of Send's first page, as entered.
class SendRecipientRow {
  const SendRecipientRow(this.input, {this.enteredAmountSats, this.isMax = false});

  final String input;
  final int? enteredAmountSats;

  /// Send everything left (on-chain) to this row; only honoured on the last row.
  final bool isMax;
}

/// What Send's first page found in one row.
class SendRecipientCheck {
  const SendRecipientCheck({this.request, this.fixedAmountSats, this.amountSats, this.problem, this.canUseMax = false});

  /// Null for an empty row.
  final PaymentRequest? request;

  /// The amount the destination carries (an invoice's, or a BIP21/BIP321 `amount`).
  final int? fixedAmountSats;

  /// The amount to send: the fixed one, else the one entered; null with Max.
  final int? amountSats;

  /// Why the row can't be sent yet.
  final SendRecipientProblem? problem;

  /// Whether this row may send everything left (the last row, on-chain, with no fixed amount).
  final bool canUseMax;

  bool get isEmpty => request == null;
  bool get isValid => !isEmpty && problem == null;
}

/// The rules for Send's first page: one recipient can be anything payable; several are paid in
/// one on-chain transaction, so each needs an on-chain address (Ark pays one destination).
class SendRecipientList {
  SendRecipientList(
    List<SendRecipientRow> rows, {
    required NetworkType network,
    required int onchainAvailableSats,
    required int arkAvailableSats,
  }) {
    final requests = [
      for (final row in rows) row.input.trim().isEmpty ? null : PaymentRequest.parse(row.input.trim(), network),
    ];
    final filled = [
      for (var i = 0; i < rows.length; i++)
        if (requests[i] != null) i,
    ];
    final several = filled.length > 1;
    final lastFilled = filled.isEmpty ? null : filled.last;
    final seen = <String>{};

    for (var i = 0; i < rows.length; i++) {
      final request = requests[i];
      if (request == null) {
        checks.add(const SendRecipientCheck());
        continue;
      }
      final row = rows[i];
      final fixed = request.amountSats;
      final address = request.bitcoinAddress == null ? null : normalizeAddress(request.bitcoinAddress!);
      final canUseMax = i == lastFilled && address != null && fixed == null && request.isPayable;
      final isMax = row.isMax && canUseMax;
      final amount = isMax ? null : (fixed ?? row.enteredAmountSats);
      SendRecipientProblem? problem;
      if (!request.isPayable) {
        problem = SendRecipientProblem.unsupported;
      } else if (several && address == null) {
        problem = SendRecipientProblem.onchainOnly;
      } else if (several && !seen.add(address!)) {
        problem = SendRecipientProblem.duplicate;
      } else if (!isMax && (amount == null || amount <= 0)) {
        problem = SendRecipientProblem.needsAmount;
      }
      checks.add(
        SendRecipientCheck(
          request: request,
          fixedAmountSats: fixed,
          amountSats: amount,
          problem: problem,
          canUseMax: canUseMax,
        ),
      );
      if (isMax) maxLast = true;
    }

    final first = filled.isEmpty ? null : checks[filled.first].request;
    final total = checks.fold<int>(0, (sum, check) => sum + (check.amountSats ?? 0));
    final int available;
    if (several || first == null) {
      available = onchainAvailableSats;
    } else {
      // A single recipient can be paid from either balance it can use.
      available = [
        if (first.bitcoinAddress != null) onchainAvailableSats,
        if (first.bitcoinAddress != null || first.hasArkOrLightning) arkAvailableSats,
      ].fold(0, (best, sats) => sats > best ? sats : best);
    }
    exceedsAvailable = total > available;
  }

  final List<SendRecipientCheck> checks = [];

  /// The amounts add up to more than any balance that could pay them.
  bool exceedsAvailable = false;

  /// The last recipient gets everything left.
  bool maxLast = false;

  /// The filled rows, in order.
  List<SendRecipientCheck> get recipients => checks.where((check) => !check.isEmpty).toList();

  bool get canContinue => !exceedsAvailable && recipients.isNotEmpty && recipients.every((check) => check.isValid);
}
