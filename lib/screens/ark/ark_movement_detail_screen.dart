import 'package:coconut_design_system/coconut_design_system.dart' hide CoconutAppBar;
import 'package:coconut_wallet/app/router/app_route_names.dart';
import 'package:coconut_wallet/app/router/route_args.dart';
import 'package:coconut_wallet/design_system/context/coconut_theme_context_extension.dart';
import 'package:coconut_wallet/enums/fiat_enums.dart';
import 'package:coconut_wallet/model/ark/ark_movement.dart';
import 'package:coconut_wallet/model/wallet/wallet_activity.dart';
import 'package:coconut_wallet/providers/ark_provider.dart';
import 'package:coconut_wallet/providers/preferences/preference_provider.dart';
import 'package:coconut_wallet/providers/transaction_provider.dart';
import 'package:coconut_wallet/ui/coconut/coconut_app_bar.dart';
import 'package:coconut_wallet/widgets/common/buttons/copy_text_container.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:coconut_wallet/widgets/features/ark/ark_texts.dart';

/// Opens the detail screen of a history entry: the on-chain transaction or the Ark movement.
void openWalletActivityDetail(BuildContext context, int walletId, WalletActivity activity) {
  switch (activity) {
    case OnchainActivity(:final tx):
      Navigator.pushNamed(
        context,
        AppRouteNames.transactionDetail,
        arguments: TransactionDetailRouteArgs(id: walletId, txHash: tx.transactionHash),
      );
    case ArkActivity(:final movement):
      Navigator.pushNamed(
        context,
        AppRouteNames.arkMovementDetail,
        arguments: ArkMovementDetailRouteArgs(id: walletId, movementId: movement.id),
      );
  }
}

/// Details of one Ark movement (bark's history entry), from the cache. Strings are not localized
/// yet (proof of concept).
class ArkMovementDetailScreen extends StatefulWidget {
  const ArkMovementDetailScreen({super.key, required this.id, required this.movementId});

  final int id;
  final int movementId;

  @override
  State<ArkMovementDetailScreen> createState() => _ArkMovementDetailScreenState();
}

class _ArkMovementDetailScreenState extends State<ArkMovementDetailScreen> {
  late final ArkProvider _arkProvider;

  int get id => widget.id;
  int get movementId => widget.movementId;

  // Syncs every few seconds while shown, so a payment that's still going (e.g. over Lightning)
  // settles on screen.
  @override
  void initState() {
    super.initState();
    _arkProvider = context.read<ArkProvider>();
    _arkProvider.setFastSync(id, true);
  }

  @override
  void dispose() {
    _arkProvider.setFastSync(id, false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final unit = context.select<PreferenceProvider, BitcoinUnit>((provider) => provider.currentUnit);
    return Consumer<ArkProvider>(
      builder: (context, arkProvider, _) {
        final movement = arkProvider.snapshot(id)?.movements.where((m) => m.id == movementId).firstOrNull;
        return Scaffold(
          backgroundColor: context.coconutColors.background,
          appBar: CoconutAppBar.build(
            context: context,
            title: 'Ark payment',
            backgroundColor: context.coconutColors.background,
          ),
          body: SafeArea(
            child:
                movement == null
                    ? const Center(child: _Muted('This movement is no longer in the Ark history.'))
                    : _MovementDetails(walletId: id, movement: movement, unit: unit),
          ),
        );
      },
    );
  }
}

class _MovementDetails extends StatelessWidget {
  const _MovementDetails({required this.walletId, required this.movement, required this.unit});

  final int walletId;
  final ArkMovement movement;
  final BitcoinUnit unit;

  @override
  Widget build(BuildContext context) {
    final activity = ArkActivity(movement);
    final colors = context.coconutColors;
    final amount = movement.effectiveBalanceSats;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          '${amount > 0 ? '+' : ''}${unit.displayBitcoinAmount(amount, withUnit: true)}',
          style: CoconutTypography.heading3_21_NumberBold.setColor(colors.primaryText),
        ),
        Text(
          '${arkActivityLabelText(activity.label) ?? _kindLabel(movement.kind)} · ${arkRailText(activity.rail)} · ${movement.status.name}',
          style: CoconutTypography.body2_14.setColor(colors.secondaryText),
        ),
        CoconutLayout.spacing_500h,
        _Row(
          'Fee',
          unit.displayBitcoinAmount(
            movement.offchainFeeSats,
            withUnit: true,
            shouldCheckZero: true,
            defaultWhenZero: '0',
          ),
        ),
        _Row('Created', _time(movement.createdAt)),
        if (movement.completedAt != null) _Row('Completed', _time(movement.completedAt!)),
        _Row('bark subsystem', '${movement.subsystemName} / ${movement.subsystemKind}'),
        _Row('Movement id', '${movement.id}'),
        for (final destination in movement.sentToDestinations)
          _Copyable('Sent to (${destination.type})', destination.value),
        for (final destination in movement.receivedOnDestinations)
          _Copyable('Received on (${destination.type})', destination.value),
        if (movement.lightningInvoice != null) _Copyable('Lightning invoice', movement.lightningInvoice!),
        if (movement.paymentHash != null) _Copyable('Payment hash', movement.paymentHash!),
        if (movement.linkedTxid != null) ...[
          _Copyable('On-chain transaction', movement.linkedTxid!),
          // A move's on-chain side, when it's in this wallet's history.
          if (context.read<TransactionProvider>().getTransactionRecord(walletId, movement.linkedTxid!) != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: CoconutButton(
                text: 'View on-chain transaction',
                onPressed:
                    () => Navigator.pushNamed(
                      context,
                      AppRouteNames.transactionDetail,
                      arguments: TransactionDetailRouteArgs(id: walletId, txHash: movement.linkedTxid!),
                    ),
                height: 44,
                backgroundColor: context.coconutColors.surfaceButton,
                foregroundColor: context.coconutColors.surfaceButtonText,
              ),
            ),
        ],
        if (movement.inputVtxoIds.isNotEmpty) _Copyable('VTXOs spent', movement.inputVtxoIds.join('\n')),
        if (movement.outputVtxoIds.isNotEmpty) _Copyable('VTXOs created', movement.outputVtxoIds.join('\n')),
        if (movement.exitedVtxoIds.isNotEmpty) _Copyable('VTXOs exited', movement.exitedVtxoIds.join('\n')),
      ],
    );
  }

  static String _kindLabel(ArkMovementKind kind) => switch (kind) {
    ArkMovementKind.arkSend || ArkMovementKind.lightningSend => 'Sent',
    ArkMovementKind.arkReceive || ArkMovementKind.lightningReceive => 'Received',
    ArkMovementKind.sendOnchain => 'Sent on-chain',
    _ => kind.name,
  };

  static String _time(DateTime time) {
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label, style: CoconutTypography.body2_14.setColor(context.coconutColors.secondaryText))),
          CoconutLayout.spacing_300w,
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: CoconutTypography.body2_14_Number.setColor(context.coconutColors.primaryText),
            ),
          ),
        ],
      ),
    );
  }
}

class _Copyable extends StatelessWidget {
  const _Copyable(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: CoconutTypography.body2_14.setColor(context.coconutColors.secondaryText)),
          CoconutLayout.spacing_100h,
          CopyTextContainer(
            text: value,
            textStyle: CoconutTypography.body3_12_Number.setColor(context.coconutColors.primaryText),
            padding: const EdgeInsets.all(14),
          ),
        ],
      ),
    );
  }
}

class _Muted extends StatelessWidget {
  const _Muted(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: CoconutTypography.body2_14.setColor(context.coconutColors.secondaryText));
}
