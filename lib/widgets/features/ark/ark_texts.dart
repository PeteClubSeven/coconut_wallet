import 'package:coconut_wallet/enums/fiat_enums.dart';
import 'package:coconut_wallet/localization/strings.g.dart';
import 'package:coconut_wallet/model/wallet/wallet_activity.dart';
import 'package:coconut_wallet/providers/view_model/send/send_options_view_model.dart';
import 'package:coconut_wallet/model/ark/move.dart';
import 'package:coconut_wallet/utils/payment_request_parser.dart';
import 'package:coconut_wallet/utils/send_recipients.dart';

/// The user-facing text for the Ark codes (payment requests, problems, options, activity
/// labels), in one place.

/// An amount with its unit, "0 BTC" rather than nothing for zero.
String formatSats(BitcoinUnit unit, int sats) =>
    unit.displayBitcoinAmount(sats, withUnit: true, shouldCheckZero: true, defaultWhenZero: '0 ${unit.symbol}');

/// The start and end of a long address, invoice or id.
String shortenMiddle(String value, {int head = 14, int tail = 10}) =>
    value.length <= head + tail + 1 ? value : '${value.substring(0, head)}…${value.substring(value.length - tail)}';

/// The destination a payment request names: its on-chain address, Ark address, invoice or
/// Lightning address.
String requestDestination(PaymentRequest request) =>
    request.bitcoinAddress ?? request.arkAddress ?? request.lightningInvoice ?? request.lightningAddress ?? request.raw;

/// What a payment request is, in a few words.
String describePaymentRequest(PaymentRequest request, BitcoinUnit unit) {
  final texts = t.ark.request;
  switch (request.kind) {
    case PaymentRequestKind.bitcoinAddress:
      return texts.bitcoin_address;
    case PaymentRequestKind.arkAddress:
      return texts.ark_address;
    case PaymentRequestKind.lightningInvoice:
      final amount = request.invoiceAmountSats;
      return amount == null
          ? texts.lightning_invoice_no_amount
          : texts.lightning_invoice_amount(amount: unit.displayBitcoinAmount(amount, withUnit: true));
    case PaymentRequestKind.lightningAddress:
      return texts.lightning_address;
    case PaymentRequestKind.bip321:
      final methods = [
        if (request.arkAddress != null) t.ark.rail.ark,
        if (request.lightningInvoice != null) t.ark.rail.lightning,
        if (request.bitcoinAddress != null) texts.method_bitcoin,
      ];
      return texts.payment_code(methods: methods.join(' · '));
    case PaymentRequestKind.unsupported:
    case PaymentRequestKind.unknown:
      return paymentRequestProblemText(request) ?? t.ark.request_problem.unknown;
  }
}

/// Why a payment request can't be paid, if it can't.
String? paymentRequestProblemText(PaymentRequest request) {
  final texts = t.ark.request_problem;
  return switch (request.problem) {
    null => null,
    PaymentRequestProblem.nothingEntered => texts.nothing_entered,
    PaymentRequestProblem.unknown => texts.unknown,
    PaymentRequestProblem.bolt12 => texts.bolt12,
    PaymentRequestProblem.lnurl => texts.lnurl,
    PaymentRequestProblem.invoiceNetwork => texts.invoice_network,
    PaymentRequestProblem.arkNetwork => texts.ark_network,
    PaymentRequestProblem.requiredParameter => texts.required_parameter(name: request.problemDetail ?? ''),
    PaymentRequestProblem.invalidBitcoinAddress => texts.invalid_bitcoin_address,
    PaymentRequestProblem.invalidAmount => texts.invalid_amount,
    PaymentRequestProblem.noMethod => texts.no_method,
  };
}

/// Why a recipient on Send's first page can't be sent yet.
String? recipientProblemText(SendRecipientCheck check) {
  final texts = t.ark.recipient_problem;
  return switch (check.problem) {
    null => null,
    SendRecipientProblem.unsupported => check.request == null ? null : paymentRequestProblemText(check.request!),
    SendRecipientProblem.onchainOnly => texts.onchain_only,
    SendRecipientProblem.duplicate => texts.duplicate,
    SendRecipientProblem.needsAmount => texts.needs_amount,
  };
}

String sendOptionTitle(SendOptionKind kind) => switch (kind) {
  SendOptionKind.ark => t.ark.option.ark,
  SendOptionKind.lightning => t.ark.option.lightning,
  SendOptionKind.onchain => t.ark.option.onchain,
  SendOptionKind.onchainViaArk => t.ark.option.onchain_via_ark,
};

String sendOptionSource(SendOptionKind kind) =>
    kind == SendOptionKind.onchain ? t.ark.option.from_wallet : t.ark.option.from_ark;

/// Why a way to pay can't be used now, if it can't.
String? sendOptionProblemText(SendOptionStatus status) {
  final texts = t.ark.option_problem;
  return switch (status.problem) {
    null => null,
    SendOptionProblem.noArk => texts.no_ark,
    SendOptionProblem.oneDestination => texts.one_destination,
    SendOptionProblem.maxOnchainOnly => texts.max_onchain_only,
    SendOptionProblem.arkLocked => texts.locked,
    SendOptionProblem.needsAmount => texts.needs_amount,
    SendOptionProblem.belowDust => texts.below_dust,
    SendOptionProblem.someBelowDust => texts.some_below_dust,
    SendOptionProblem.arkAddressRefused => texts.address_refused,
    SendOptionProblem.estimateFailed => texts.estimate_failed(error: status.detail ?? ''),
    SendOptionProblem.notEnoughArk => texts.not_enough_ark,
    SendOptionProblem.noOnchainFunds => texts.no_onchain_funds,
    SendOptionProblem.needsFeeRate => texts.needs_fee_rate,
    SendOptionProblem.notEnoughOnchain => texts.not_enough_onchain,
    SendOptionProblem.tooSmallForFee => texts.too_small_for_fee,
    SendOptionProblem.buildFailed => status.detail ?? texts.build_failed,
    SendOptionProblem.boardRefused => status.detail ?? texts.board_refused,
  };
}

String arkRailText(ArkRail rail) => switch (rail) {
  ArkRail.onchain => t.ark.rail.onchain,
  ArkRail.ark => t.ark.rail.ark,
  ArkRail.lightning => t.ark.rail.lightning,
};

String? arkActivityLabelText(ArkActivityLabel? label) {
  final texts = t.ark.activity;
  return switch (label) {
    null => null,
    ArkActivityLabel.refresh => texts.refresh,
    ArkActivityLabel.movedToArk => texts.moved_to_ark,
    ArkActivityLabel.movedOnchain => texts.moved_onchain,
    ArkActivityLabel.exit => texts.exit,
    ArkActivityLabel.failed => texts.failed,
    ArkActivityLabel.canceled => texts.canceled,
  };
}

/// "On-chain · Wallet 1", "Ark · Wallet 1" or a vault's name.
String moveEndpointText(MoveEndpoint endpoint) => switch (endpoint.kind) {
  MoveEndpointKind.onchain => t.ark.move.onchain(name: endpoint.walletName),
  MoveEndpointKind.ark => t.ark.move.ark(name: endpoint.walletName),
  MoveEndpointKind.vault => endpoint.walletName,
};
