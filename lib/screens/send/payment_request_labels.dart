import 'package:coconut_wallet/enums/fiat_enums.dart';
import 'package:coconut_wallet/providers/view_model/send/send_options_view_model.dart';
import 'package:coconut_wallet/utils/payment_request_parser.dart';

/// What a payment request is, in a few words. Strings are not localized yet (proof of concept).
String describePaymentRequest(PaymentRequest request, BitcoinUnit unit) {
  switch (request.kind) {
    case PaymentRequestKind.bitcoinAddress:
      return 'Bitcoin address';
    case PaymentRequestKind.arkAddress:
      return 'Ark address';
    case PaymentRequestKind.lightningInvoice:
      final amount = request.invoiceAmountSats;
      return amount == null
          ? 'Lightning invoice (no amount)'
          : 'Lightning invoice · ${unit.displayBitcoinAmount(amount, withUnit: true)}';
    case PaymentRequestKind.lightningAddress:
      return 'Lightning address';
    case PaymentRequestKind.bip321:
      final methods = [
        if (request.arkAddress != null) 'Ark',
        if (request.lightningInvoice != null) 'Lightning',
        if (request.bitcoinAddress != null) 'Bitcoin',
      ];
      return 'Payment code: ${methods.join(' · ')}';
    case PaymentRequestKind.unsupported:
    case PaymentRequestKind.unknown:
      return 'Can\'t pay this';
  }
}

/// Whether Send can go on to the ways to pay it.
bool isPayable(PaymentRequest request) =>
    request.kind != PaymentRequestKind.unsupported && request.kind != PaymentRequestKind.unknown;

String shortenDestination(String value) =>
    value.length <= 32 ? value : '${value.substring(0, 16)}…${value.substring(value.length - 10)}';

String sendOptionTitle(SendOptionKind kind) => switch (kind) {
  SendOptionKind.ark => 'Ark',
  SendOptionKind.lightning => 'Lightning',
  SendOptionKind.onchain => 'On-chain',
  SendOptionKind.onchainViaArk => 'On-chain via Ark',
};

String sendOptionSource(SendOptionKind kind) => kind == SendOptionKind.onchain ? 'From the wallet' : 'From Ark';
