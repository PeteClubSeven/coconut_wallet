import 'package:coconut_design_system/coconut_design_system.dart' hide CoconutUnderlinedButton;
import 'package:coconut_wallet/constants/icon_path.dart';
import 'package:coconut_wallet/design_system/context/coconut_theme_context_extension.dart';
import 'package:coconut_wallet/localization/strings.g.dart';
import 'package:coconut_wallet/providers/preferences/preference_provider.dart';
import 'package:coconut_wallet/ui/coconut/coconut_underlined_button.dart';
import 'package:coconut_wallet/widgets/common/buttons/shrink_animation_button.dart';
import 'package:coconut_wallet/widgets/common/dialogs/dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

/// Small pieces the Ark screens share, built from Coconut's own widgets and tokens so they read
/// like the rest of the app.

/// A label on the left and a value on the right, for summaries inside cards.
class ArkInfoRow extends StatelessWidget {
  const ArkInfoRow({super.key, required this.label, this.value, this.valueWidget, this.valueColor});

  final String label;
  final String? value;
  final Widget? valueWidget;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.coconutColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label, style: CoconutTypography.body3_12.setColor(colors.secondaryText))),
          CoconutLayout.spacing_300w,
          valueWidget ??
              Text(
                value ?? '',
                textAlign: TextAlign.end,
                style: CoconutTypography.body2_14_Number.setColor(valueColor ?? colors.primaryText),
              ),
        ],
      ),
    );
  }
}

/// A small badge in the style of the UTXO "Change" chip.
class ArkChip extends StatelessWidget {
  const ArkChip(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.coconutColors;
    return IntrinsicWidth(
      child: CoconutChip(
        minWidth: 40,
        color: colors.surfaceInfoChip,
        borderColor: colors.surfaceInfoChip,
        label: label,
        labelSize: 10,
        labelColor: colors.primaryText,
      ),
    );
  }
}

/// A small label over an amount in a rounded box, as the UTXO overview's availability chips.
class ArkBalanceBox extends StatelessWidget {
  const ArkBalanceBox({super.key, required this.label, required this.amount, this.backgroundColor});

  final String label;
  final String amount;

  /// Defaults to the surface colour.
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.coconutColors;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: backgroundColor ?? colors.surface, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: CoconutTypography.caption_10.setColor(colors.mutedText)),
          const SizedBox(height: 4),
          Text(amount, style: CoconutTypography.body3_12_Number.setColor(colors.primaryText)),
        ],
      ),
    );
  }
}

/// A section title, as wallet detail's section headers.
class ArkSectionTitle extends StatelessWidget {
  const ArkSectionTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(text, style: CoconutTypography.body2_14_Bold.setColor(context.coconutColors.primaryText)),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// A surface card, radius 24 and padding 20 like the app's other cards.
class ArkCard extends StatelessWidget {
  const ArkCard({super.key, required this.child, this.padding = const EdgeInsets.all(20)});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: context.coconutColors.surface,
        borderRadius: BorderRadius.circular(CoconutStyles.radius_400),
      ),
      child: child,
    );
  }
}

/// A pressable card that can be picked, with a check on the right when it is (the idiom of
/// Coconut's selectable sheets).
class ArkSelectableCard extends StatelessWidget {
  const ArkSelectableCard({
    super.key,
    required this.isSelected,
    required this.onPressed,
    required this.child,
    this.isEnabled = true,
    this.footer,
  });

  final bool isSelected;
  final bool isEnabled;
  final VoidCallback onPressed;
  final Widget child;

  /// Shown under the card's main row, inside the card.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final colors = context.coconutColors;
    return Opacity(
      opacity: isEnabled ? 1 : 0.5,
      child: ShrinkAnimationButton(
        onPressed: onPressed,
        defaultColor: colors.surface,
        pressedOverlayColor: colors.surfacePressOverlay,
        pressedOverlayOpacity: colors.surfacePressOverlayOpacity,
        borderRadius: CoconutStyles.radius_300,
        borderWidth: isSelected ? 1 : 0,
        border: isSelected ? Border.all(color: colors.borderStrong) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: child),
                  Container(
                    margin: const EdgeInsets.only(left: 16),
                    width: 18,
                    height: 18,
                    child:
                        isSelected
                            ? SvgPicture.asset(
                              CommonActionIconPath.check,
                              width: 16,
                              height: 16,
                              colorFilter: ColorFilter.mode(colors.primaryText, BlendMode.srcIn),
                            )
                            : null,
                  ),
                ],
              ),
              if (footer != null) footer!,
            ],
          ),
        ),
      ),
    );
  }
}

/// The small pill under the send screen's amount ("Send All"); a public copy of send_screen's
/// private one.
class SendOptionPill extends StatelessWidget {
  const SendOptionPill({
    super.key,
    required this.label,
    required this.onPressed,
    this.iconPath,
    this.isSelected = false,
  });

  final String label;
  final VoidCallback onPressed;
  final String? iconPath;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.coconutColors;
    final background = isSelected ? colors.brandAccentBackground : colors.surfaceButton;
    final foreground = isSelected ? colors.brandAccentForeground : colors.primaryText;
    return ShrinkAnimationButton(
      onPressed: onPressed,
      defaultColor: background,
      pressedOverlayColor: colors.surface,
      pressedOverlayOpacity: 0.8,
      borderRadius: 4.0,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (iconPath != null) ...[
              SvgPicture.asset(
                iconPath!,
                width: 16,
                colorFilter: ColorFilter.mode(foreground.withValues(alpha: 0.5), BlendMode.srcIn),
              ),
              CoconutLayout.spacing_100w,
            ],
            Text(label, style: CoconutTypography.body3_12_Number.setColor(foreground)),
          ],
        ),
      ),
    );
  }
}

/// A notice with an icon, a title, a description and an optional underlined action (e.g. a
/// locked Ark wallet and "Unlock").
class ArkNoticeCard extends StatelessWidget {
  const ArkNoticeCard({
    super.key,
    required this.title,
    this.description,
    this.actionText,
    this.onAction,
    this.iconPath = CommonStateIconPath.circleInfo,
    this.isWarning = false,
  });

  final String title;
  final String? description;
  final String? actionText;
  final VoidCallback? onAction;
  final String iconPath;
  final bool isWarning;

  @override
  Widget build(BuildContext context) {
    final colors = context.coconutColors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: colors.surface, borderRadius: BorderRadius.circular(CoconutStyles.radius_300)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: SvgPicture.asset(
              iconPath,
              width: 18,
              height: 18,
              colorFilter: ColorFilter.mode(isWarning ? colors.warning : colors.iconPrimary, BlendMode.srcIn),
            ),
          ),
          CoconutLayout.spacing_300w,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: CoconutTypography.body2_14_Bold.setColor(colors.primaryText)),
                if (description != null) ...[
                  CoconutLayout.spacing_100h,
                  Text(description!, style: CoconutTypography.body3_12.setColor(colors.secondaryText)),
                ],
                if (actionText != null && onAction != null) ...[
                  CoconutLayout.spacing_200h,
                  CoconutUnderlinedButton(
                    text: actionText!,
                    textStyle: CoconutTypography.body3_12_Bold,
                    padding: EdgeInsets.zero,
                    onTap: onAction!,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Asks to confirm an Ark action with Coconut's popup; true when confirmed.
Future<bool> confirmArkAction(
  BuildContext context, {
  required String title,
  required String description,
  String? confirmText,
}) async {
  var confirmed = false;
  await showConfirmDialog(
    context,
    context.read<PreferenceProvider>().language,
    title,
    description,
    leftButtonText: t.cancel,
    rightButtonText: confirmText ?? t.confirm,
    onTapRight: () {
      confirmed = true;
      Navigator.pop(context);
    },
  );
  return confirmed;
}

/// Shows an Ark error with Coconut's info popup.
Future<void> showArkError(BuildContext context, String title, String message) =>
    showInfoDialog(context, context.read<PreferenceProvider>().language, title, message);
