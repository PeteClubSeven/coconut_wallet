import 'package:coconut_design_system/coconut_design_system.dart' hide CoconutAppBar;
import 'package:coconut_wallet/app/router/app_route_names.dart';
import 'package:coconut_wallet/app/router/route_args.dart';
import 'package:coconut_wallet/design_system/context/coconut_theme_context_extension.dart';
import 'package:coconut_wallet/enums/fiat_enums.dart';
import 'package:coconut_wallet/localization/strings.g.dart';
import 'package:coconut_wallet/model/ark/ark_movement.dart';
import 'package:coconut_wallet/model/wallet/wallet_activity.dart';
import 'package:coconut_wallet/providers/ark_provider.dart';
import 'package:coconut_wallet/providers/preferences/preference_provider.dart';
import 'package:coconut_wallet/providers/transaction_provider.dart';
import 'package:coconut_wallet/ui/coconut/coconut_app_bar.dart';
import 'package:coconut_wallet/utils/datetime_util.dart';
import 'package:coconut_wallet/widgets/common/amount/fiat_price.dart';
import 'package:coconut_wallet/widgets/common/buttons/copy_text_container.dart';
import 'package:coconut_wallet/widgets/common/info/highlighted_info_area.dart';
import 'package:coconut_wallet/widgets/features/ark/ark_texts.dart';
import 'package:coconut_wallet/widgets/features/transaction/card/underline_button_item_card.dart';
import 'package:coconut_wallet/widgets/features/transaction/icon/pending_transaction_lottie_icon.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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

/// Details of one Ark movement (bark's history entry), from the cache, laid out like the
/// transaction detail screen.
class ArkMovementDetailScreen extends StatefulWidget {
  const ArkMovementDetailScreen({super.key, required this.id, required this.movementId});

  final int id;
  final int movementId;

  @override
  State<ArkMovementDetailScreen> createState() => _ArkMovementDetailScreenState();
}

class _ArkMovementDetailScreenState extends State<ArkMovementDetailScreen> {
  late final ArkProvider _arkProvider;
  late BitcoinUnit _unit;

  // Syncs every few seconds while shown, so a payment that's still going (e.g. over Lightning)
  // settles on screen.
  @override
  void initState() {
    super.initState();
    _arkProvider = context.read<ArkProvider>();
    _unit = context.read<PreferenceProvider>().currentUnit;
    _arkProvider.setFastSync(widget.id, true);
  }

  @override
  void dispose() {
    _arkProvider.setFastSync(widget.id, false);
    super.dispose();
  }

  void _toggleUnit() => setState(() => _unit = _unit.isBasedOnSatoshi ? BitcoinUnit.btc : BitcoinUnit.sats);

  @override
  Widget build(BuildContext context) {
    final colors = context.coconutColors;
    return Consumer<ArkProvider>(
      builder: (context, arkProvider, _) {
        final movement = arkProvider.snapshot(widget.id)?.movements.where((m) => m.id == widget.movementId).firstOrNull;
        return Scaffold(
          backgroundColor: colors.background,
          appBar: CoconutAppBar.build(context: context, title: t.view_tx_details, backgroundColor: colors.background),
          body: SafeArea(
            child:
                movement == null
                    ? Center(
                      child: Text(
                        t.ark.movement.gone,
                        style: CoconutTypography.body3_12.setColor(colors.secondaryText),
                      ),
                    )
                    : _MovementDetails(walletId: widget.id, movement: movement, unit: _unit, onToggleUnit: _toggleUnit),
          ),
        );
      },
    );
  }
}

class _MovementDetails extends StatelessWidget {
  const _MovementDetails({
    required this.walletId,
    required this.movement,
    required this.unit,
    required this.onToggleUnit,
  });

  final int walletId;
  final ArkMovement movement;
  final BitcoinUnit unit;
  final VoidCallback onToggleUnit;

  @override
  Widget build(BuildContext context) {
    final activity = ArkActivity(movement);
    final colors = context.coconutColors;
    final valueStyle = CoconutTypography.body2_14_Number.setColor(colors.primaryText);
    final linkedTxid = movement.linkedTxid;
    final hasLinkedTx =
        linkedTxid != null && context.read<TransactionProvider>().getTransactionRecord(walletId, linkedTxid) != null;
    final copyable = <(String, String)>[
      for (final destination in movement.sentToDestinations) (t.ark.movement.sent_to, destination.value),
      for (final destination in movement.receivedOnDestinations) (t.ark.movement.received_on, destination.value),
      // A Lightning send's destination is already its invoice.
      if (movement.lightningInvoice != null &&
          !movement.sentToDestinations.any((d) => d.value == movement.lightningInvoice))
        (t.ark.movement.lightning_invoice, movement.lightningInvoice!),
      if (movement.paymentHash != null) (t.ark.movement.payment_hash, movement.paymentHash!),
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          HighlightedInfoArea(textList: DateTimeUtil.formatTimestamp(movement.timestamp)),
          CoconutLayout.spacing_500h,
          _buildAmount(context),
          CoconutLayout.spacing_400h,
          if (movement.isPending) ...[_buildPending(context), CoconutLayout.spacing_400h],
          CoconutLayout.spacing_400h,
          UnderlineButtonItemCard(
            label: t.ark.movement.status,
            child: Text(
              '${arkActivityLabelText(activity.label) ?? _kindText(movement)} · ${arkRailText(activity.rail)} · '
              '${_statusText(movement.status)}',
              style: valueStyle,
            ),
          ),
          UnderlineButtonItemCard(
            label: t.ark.movement.fee,
            child: Text(formatSats(unit, movement.offchainFeeSats), style: valueStyle),
          ),
          if (movement.completedAt != null)
            UnderlineButtonItemCard(
              label: t.ark.movement.completed_at,
              child: Text(DateTimeUtil.formatTimestamp(movement.completedAt!).join(' '), style: valueStyle),
            ),
          for (final (label, value) in copyable)
            UnderlineButtonItemCard(label: label, child: CopyTextContainer(text: value, textStyle: valueStyle)),
          if (linkedTxid != null)
            UnderlineButtonItemCard(
              label: t.ark.movement.onchain_tx,
              underlineButtonLabel: hasLinkedTx ? t.ark.movement.view_transaction : null,
              onTapUnderlineButton:
                  hasLinkedTx
                      ? () => Navigator.pushNamed(
                        context,
                        AppRouteNames.transactionDetail,
                        arguments: TransactionDetailRouteArgs(id: walletId, txHash: linkedTxid),
                      )
                      : null,
              child: CopyTextContainer(text: linkedTxid, textStyle: valueStyle),
            ),
          // bark's own record, for support and debugging.
          UnderlineButtonItemCard(
            label: t.ark.movement.technical,
            showDivider: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _detail(context, t.ark.movement.movement_id, '${movement.id}'),
                _detail(context, t.ark.movement.subsystem, '${movement.subsystemName} / ${movement.subsystemKind}'),
                if (movement.inputVtxoIds.isNotEmpty)
                  _detail(context, t.ark.movement.vtxos_spent, movement.inputVtxoIds.join('\n')),
                if (movement.outputVtxoIds.isNotEmpty)
                  _detail(context, t.ark.movement.vtxos_created, movement.outputVtxoIds.join('\n')),
                if (movement.exitedVtxoIds.isNotEmpty)
                  _detail(context, t.ark.movement.vtxos_exited, movement.exitedVtxoIds.join('\n')),
              ],
            ),
          ),
          CoconutLayout.spacing_1000h,
        ],
      ),
    );
  }

  /// The signed amount in the receiving or sending colour, as on the transaction detail screen.
  Widget _buildAmount(BuildContext context) {
    final colors = context.coconutColors;
    final amount = movement.effectiveBalanceSats;
    final isIncoming = amount > 0;
    final color = amount == 0 ? colors.primaryText : (isIncoming ? colors.receivingColor : colors.sendingColor);
    final sign = amount == 0 ? '' : (isIncoming ? '+' : '-');
    final boldStyle = CoconutTypography.heading2_28_NumberBold.copyWith(fontSize: 24, color: color);
    final unitStyle = CoconutTypography.heading4_18_NumberBold.copyWith(color: color);
    final absAmount = unit.displayBitcoinAmount(amount.abs(), shouldCheckZero: true, defaultWhenZero: '0');
    return GestureDetector(
      onTap: onToggleUnit,
      child: Column(
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children:
                  unit.isPrefixSymbol
                      ? [
                        Text(sign, style: boldStyle),
                        Text(unit.symbol, style: unitStyle),
                        CoconutLayout.spacing_50w,
                        Text(absAmount, style: boldStyle),
                      ]
                      : [
                        Text('$sign$absAmount', style: boldStyle),
                        CoconutLayout.spacing_50w,
                        Text(unit.symbol, style: unitStyle),
                      ],
            ),
          ),
          CoconutLayout.spacing_100h,
          FiatPrice(
            satoshiAmount: amount.abs(),
            textStyle: CoconutTypography.body2_14_Number.setColor(color.withValues(alpha: 0.7)),
          ),
        ],
      ),
    );
  }

  /// The transaction detail screen's pending box.
  Widget _buildPending(BuildContext context) {
    final colors = context.coconutColors;
    final isIncoming = movement.effectiveBalanceSats > 0;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border.all(width: 1, color: colors.feeBumpingHistoryLine),
        borderRadius: BorderRadius.circular(CoconutStyles.radius_200),
      ),
      padding: const EdgeInsets.all(10),
      child: Row(
        children: [
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 8),
            child: PendingTransactionLottieIcon(isIncoming: isIncoming, size: 24),
          ),
          Expanded(
            child: Text(
              isIncoming ? t.status_receiving : t.status_sending,
              style: CoconutTypography.body2_14.setColor(colors.primaryText).copyWith(fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  Widget _detail(BuildContext context, String label, String value) {
    final colors = context.coconutColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: CoconutTypography.body3_12.setColor(colors.secondaryText)),
          Text(value, style: CoconutTypography.body3_12_Number.setColor(colors.primaryText)),
        ],
      ),
    );
  }

  static String _statusText(ArkMovementStatus status) => switch (status) {
    ArkMovementStatus.pending => t.ark.movement.pending,
    ArkMovementStatus.successful => t.ark.movement.successful,
    ArkMovementStatus.failed => t.ark.movement.failed,
    ArkMovementStatus.canceled => t.ark.movement.canceled,
  };

  static String _kindText(ArkMovement movement) =>
      movement.effectiveBalanceSats > 0 ? t.ark.movement.received : t.ark.movement.sent;
}
