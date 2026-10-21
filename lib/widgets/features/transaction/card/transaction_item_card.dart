import 'package:coconut_design_system/coconut_design_system.dart';
import 'package:coconut_wallet/design_system/context/coconut_theme_context_extension.dart';
import 'package:coconut_wallet/enums/fiat_enums.dart';
import 'package:coconut_wallet/enums/transaction_enums.dart';
import 'package:coconut_wallet/localization/strings.g.dart';
import 'package:coconut_wallet/model/wallet/wallet_activity.dart';
import 'package:coconut_wallet/utils/datetime_util.dart';
import 'package:coconut_wallet/utils/text_utils.dart';
import 'package:coconut_wallet/utils/transaction_util.dart';
import 'package:coconut_wallet/widgets/common/buttons/shrink_animation_button.dart';
import 'package:coconut_wallet/widgets/common/icon/transaction_status_gradient_mask.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';
import 'package:coconut_wallet/constants/icon_path.dart';
import 'package:coconut_wallet/widgets/features/ark/ark_texts.dart';

/// A row of a wallet's history: an on-chain transaction or an Ark movement.
class TransactionItemCard extends StatelessWidget {
  final WalletActivity activity;
  final BitcoinUnit currentUnit;
  final int id;
  final Function onPressed;
  final EdgeInsetsGeometry padding;
  final double borderRadius;

  late final TransactionStatus? status;

  TransactionItemCard({
    super.key,
    required this.activity,
    required this.currentUnit,
    required this.id,
    required this.onPressed,
    this.padding = const EdgeInsets.symmetric(horizontal: Sizes.size20, vertical: Sizes.size16),
    this.borderRadius = 12,
  }) {
    status = activity.status;
  }

  ArkActivity? get _arkActivity => switch (activity) {
    ArkActivity ark => ark,
    OnchainActivity() => null,
  };

  Widget _buildStatus(BuildContext context) {
    final iconPath = TransactionUtil.getStatusIconAsset(status);
    String statusText;
    Color? iconColor;
    switch (status) {
      case TransactionStatus.received:
        statusText = t.status_received;
        iconColor = context.coconutColors.receivingColor;
        break;
      case TransactionStatus.receiving:
        statusText = t.status_receiving;
        iconColor = context.coconutColors.receivingColor;
        break;
      case TransactionStatus.sent:
        statusText = t.status_sent;
        iconColor = context.coconutColors.sendingColor;
        break;
      case TransactionStatus.sending:
        statusText = t.status_sending;
        iconColor = context.coconutColors.sendingColor;
        break;
      case TransactionStatus.self:
        statusText = t.status_sent;
        break;
      case TransactionStatus.selfsending:
        statusText = t.status_sending;
        break;
      default:
        return const SizedBox.shrink(); // fallback
    }
    return _buildIconStatus(context, iconPath, iconColor, arkActivityLabelText(_arkActivity?.label) ?? statusText);
  }

  Widget _buildIconStatus(BuildContext context, String assetPath, Color? iconColor, String statusString) {
    final icon =
        iconColor == null
            ? TransactionStatusGradientMask(
              child: SvgPicture.asset(
                assetPath,
                width: 24,
                height: 24,
                colorFilter: ColorFilter.mode(context.coconutColors.iconPrimary, BlendMode.srcIn),
              ),
            )
            : SvgPicture.asset(
              assetPath,
              width: 24,
              height: 24,
              colorFilter: ColorFilter.mode(iconColor, BlendMode.srcIn),
            );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        icon,
        CoconutLayout.spacing_200w,
        Text(statusString, style: CoconutTypography.body2_14.setColor(context.coconutColors.primaryText)),
        if (_arkActivity != null) ...[CoconutLayout.spacing_200w, _buildRailBadge(context, arkRailText(_arkActivity!.rail))],
      ],
    );
  }

  Widget _buildRailBadge(BuildContext context, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: context.coconutColors.surfaceMuted,
        borderRadius: BorderRadius.circular(CoconutStyles.radius_100),
      ),
      child: Text(label, style: CoconutTypography.caption_10.setColor(context.coconutColors.secondaryText)),
    );
  }

  Widget _buildAmount(BuildContext context) {
    final String amountString = currentUnit.displayBitcoinAmount(activity.displayAmount);
    final bool isReceived = status == TransactionStatus.received || status == TransactionStatus.receiving;
    final String prefix = isReceived ? '+' : '';

    return Expanded(
      child: FittedBox(
        alignment: Alignment.centerRight,
        fit: BoxFit.scaleDown,
        child: Text(
          '$prefix$amountString',
          style: CoconutTypography.body1_16_Number.setColor(context.coconutColors.primaryText),
        ),
      ),
    );
  }

  Widget _buildTimestamp(BuildContext context, List<String> transactionTimeStamp) {
    final textStyle = CoconutTypography.body3_12_Number.setColor(context.coconutColors.tertiaryText);
    return Row(
      children: [
        Text(transactionTimeStamp[0], style: textStyle),
        CoconutLayout.spacing_200w,
        Text('|', style: textStyle),
        CoconutLayout.spacing_200w,
        Text(transactionTimeStamp[1], style: textStyle),
      ],
    );
  }

  Widget _buildMemo(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        SvgPicture.asset(
          CommonActionIconPath.editOutlined,
          colorFilter: ColorFilter.mode(context.coconutColors.iconSecondary, BlendMode.srcIn),
          width: Sizes.size12,
        ),
        CoconutLayout.spacing_100w,
        Text(
          TextUtils.ellipsisIfLonger(activity.memo!, maxLength: 20),
          style: CoconutTypography.body3_12.setColor(context.coconutColors.primaryText),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final displayTime = switch (activity) {
      OnchainActivity(:final tx) => tx.getDateTimeToDisplay()!,
      ArkActivity(:final time) => time,
    };
    List<String>? transactionTimeStamp = DateTimeUtil.formatTimestamp(displayTime.toLocal());
    final colors = context.coconutColors;
    return ShrinkAnimationButton(
      onPressed: () {
        onPressed();
      },
      defaultColor: colors.surface,
      pressedOverlayColor: colors.surfacePressOverlay,
      pressedOverlayOpacity: colors.surfacePressOverlayOpacity,
      borderWidth: 0,
      borderRadius: borderRadius,
      child: Container(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildTimestamp(context, transactionTimeStamp),
            CoconutLayout.spacing_200h,
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [_buildStatus(context), CoconutLayout.spacing_200w, _buildAmount(context)],
            ),
            if (activity.memo != null && activity.memo!.isNotEmpty) _buildMemo(context),
          ],
        ),
      ),
    );
  }
}
