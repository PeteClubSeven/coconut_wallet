import 'dart:async';

import 'package:coconut_design_system/coconut_design_system.dart' hide CoconutPulldownMenu, CoconutPulldownMenuItem;
import 'package:coconut_wallet/constants/icon_path.dart';
import 'package:coconut_wallet/design_system/context/coconut_theme_context_extension.dart';
import 'package:coconut_wallet/enums/fiat_enums.dart';
import 'package:coconut_wallet/localization/strings.g.dart';
import 'package:coconut_wallet/model/ark/ark_vtxo.dart';
import 'package:coconut_wallet/model/utxo/utxo_bucket.dart';
import 'package:coconut_wallet/screens/wallet_detail/utxo_overview/utxo_chart_bubble.dart';
import 'package:coconut_wallet/screens/wallet_detail/utxo_overview/utxo_overview_filter_widgets.dart';
import 'package:coconut_wallet/ui/coconut/coconut_pulldown_menu.dart';
import 'package:coconut_wallet/utils/utxo_amount_format_util.dart';
import 'package:coconut_wallet/utils/utxo_tier_theme.dart';
import 'package:coconut_wallet/widgets/common/overlays/common_bottom_sheets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The VTXO overview's visuals, adapted from the UTXO overview's (`utxo_summary_chart.dart`,
/// `utxo_bucket_card_row.dart`), which are tied to `UtxoState`: the summary chart, bucket rows of
/// coins and the coin card.

/// A group of VTXOs (by amount or by expiry) and the colour it is drawn in.
class VtxoBucket {
  const VtxoBucket({required this.label, required this.guide, required this.color, required this.vtxos});

  final String label;

  /// The range, for the interval guide.
  final String guide;
  final Color color;
  final List<ArkVtxo> vtxos;

  int get totalSats => vtxos.fold(0, (sum, vtxo) => sum + vtxo.amountSats);
}

/// VTXOs grouped by amount, with the UTXO overview's ranges and tier colours (no dust floor).
List<VtxoBucket> bucketVtxosByAmount(List<ArkVtxo> vtxos, UtxoTierTheme tierTheme) {
  return getUtxoBucketRanges(dustThreshold: 0)
      .map((range) {
        final inRange =
            vtxos.where((vtxo) => vtxo.amountSats >= range.min && vtxo.amountSats <= range.max).toList()
              ..sort((a, b) => b.amountSats.compareTo(a.amountSats));
        final guide =
            range.label == 'whale'
                ? '≥ 10 ${t.btc}'
                : '${formatUtxoAmountForDisplay(range.min, BitcoinUnit.btc, dustThreshold: 0)} ~ '
                    '${formatUtxoAmountForDisplay(range.max, BitcoinUnit.btc, dustThreshold: 0)}';
        return VtxoBucket(
          label: range.label,
          guide: guide,
          color: tierTheme.colorForSats(range.max, dustThreshold: 0),
          vtxos: inRange,
        );
      })
      .where((bucket) => bucket.vtxos.isNotEmpty)
      .toList();
}

/// VTXOs grouped by time to expiry (in blocks), most urgent first.
List<VtxoBucket> bucketVtxosByExpiry(
  List<ArkVtxo> vtxos,
  int? tipHeight,
  UtxoTierTheme tierTheme,
  ({Color danger, Color warning}) urgent,
) {
  final texts = t.ark.vtxo;
  final ranges = <({String label, String guide, Color color, bool Function(int left) contains})>[
    (label: texts.expiry_expired, guide: texts.expiry_guide_expired, color: urgent.danger, contains: (l) => l <= 0),
    (label: texts.expiry_day, guide: texts.expiry_guide_day, color: urgent.warning, contains: (l) => l > 0 && l <= 144),
    (
      label: texts.expiry_week,
      guide: texts.expiry_guide_week,
      color: tierTheme.colorForSats(500_000, dustThreshold: 0),
      contains: (l) => l > 144 && l <= 1008,
    ),
    (
      label: texts.expiry_month,
      guide: texts.expiry_guide_month,
      color: tierTheme.colorForSats(50_000_000, dustThreshold: 0),
      contains: (l) => l > 1008 && l <= 4320,
    ),
    (
      label: texts.expiry_later,
      guide: texts.expiry_guide_later,
      color: tierTheme.colorForSats(2_000_000_000, dustThreshold: 0),
      contains: (l) => l > 4320,
    ),
  ];
  // Without a chain tip, everything counts as later.
  int left(ArkVtxo vtxo) => tipHeight == null ? 1 << 30 : vtxo.expiryHeight - tipHeight;
  return ranges
      .map(
        (range) => VtxoBucket(
          label: range.label,
          guide: range.guide,
          color: range.color,
          vtxos:
              vtxos.where((vtxo) => range.contains(left(vtxo))).toList()
                ..sort((a, b) => a.expiryHeight.compareTo(b.expiryHeight)),
        ),
      )
      .where((bucket) => bucket.vtxos.isNotEmpty)
      .toList();
}

/// "Amount" / "Expiry", as the UTXO overview's grouping tab bar.
class VtxoGroupingTabBar extends StatelessWidget {
  const VtxoGroupingTabBar({super.key, required this.isByAmount, required this.onSelected});

  static const double _tabWidth = 96;

  final bool isByAmount;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            color: context.coconutColors.background,
            padding: const EdgeInsets.fromLTRB(4, 12, 0, 0),
            child: SizedBox(
              width: _tabWidth * 2,
              height: 40,
              child: Stack(
                children: [
                  Row(
                    children: [
                      UtxoGroupingTab(label: t.ark.vtxo.by_amount, isSelected: isByAmount, onTap: () => onSelected(0)),
                      UtxoGroupingTab(label: t.ark.vtxo.by_expiry, isSelected: !isByAmount, onTap: () => onSelected(1)),
                    ],
                  ),
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    left: isByAmount ? 0 : _tabWidth,
                    bottom: 0,
                    child: Container(
                      width: _tabWidth,
                      height: 2,
                      decoration: BoxDecoration(
                        color: context.coconutColors.primaryText,
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Container(width: MediaQuery.sizeOf(context).width, height: 1, color: context.coconutColors.divider),
        ],
      ),
    );
  }
}

/// The spendable and locked chips and the bar chart, as the UTXO overview's summary chart.
class VtxoSummaryChart extends StatelessWidget {
  const VtxoSummaryChart({
    super.key,
    required this.buckets,
    required this.vtxos,
    required this.currentUnit,
    required this.guideTitle,
    this.footer,
  });

  final List<VtxoBucket> buckets;
  final List<ArkVtxo> vtxos;
  final BitcoinUnit currentUnit;
  final String guideTitle;

  /// Shown under the chart (e.g. when a refresh is due).
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final colors = context.coconutColors;
    final spendable = vtxos.where((vtxo) => !vtxo.isLocked).toList();
    final locked = vtxos.where((vtxo) => vtxo.isLocked).toList();
    int sum(List<ArkVtxo> list) => list.fold(0, (total, vtxo) => total + vtxo.amountSats);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [colors.background, colors.divider],
        ),
        borderRadius: const BorderRadius.only(bottomLeft: Radius.circular(24)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: _AvailabilityChip(
                    label: t.ark.vtxo.spendable,
                    count: spendable.length,
                    amount: formatUtxoAmountForDisplay(sum(spendable), currentUnit, dustThreshold: 0),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _AvailabilityChip(
                    label: t.ark.vtxo.locked,
                    count: locked.length,
                    amount: formatUtxoAmountForDisplay(sum(locked), currentUnit, dustThreshold: 0),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _VtxoBarChart(buckets: buckets, currentUnit: currentUnit, guideTitle: guideTitle),
            if (footer != null) ...[const SizedBox(height: 12), footer!],
          ],
        ),
      ),
    );
  }
}

class _AvailabilityChip extends StatelessWidget {
  const _AvailabilityChip({required this.label, required this.count, required this.amount});

  final String label;
  final int count;
  final String amount;

  @override
  Widget build(BuildContext context) {
    final colors = context.coconutColors;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: colors.utxoOverviewChartSurface, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.ark.vtxo.chip(label: label, count: count),
            style: CoconutTypography.caption_10.setColor(colors.mutedText),
          ),
          const SizedBox(height: 4),
          Text(amount, style: CoconutTypography.body3_12_Number.setColor(colors.primaryText)),
        ],
      ),
    );
  }
}

class _VtxoBarChart extends StatefulWidget {
  const _VtxoBarChart({required this.buckets, required this.currentUnit, required this.guideTitle});

  final List<VtxoBucket> buckets;
  final BitcoinUnit currentUnit;
  final String guideTitle;

  @override
  State<_VtxoBarChart> createState() => _VtxoBarChartState();
}

class _VtxoBarChartState extends State<_VtxoBarChart> {
  static const double _barMaxHeight = 80;
  int? _tappedIndex;
  Timer? _bubbleTimer;

  @override
  void dispose() {
    _bubbleTimer?.cancel();
    super.dispose();
  }

  void _tap(int index) {
    final next = _tappedIndex == index ? null : index;
    setState(() => _tappedIndex = next);
    _bubbleTimer?.cancel();
    if (next != null) {
      _bubbleTimer = Timer(const Duration(seconds: 3), () {
        if (mounted && _tappedIndex == next) setState(() => _tappedIndex = null);
      });
    }
  }

  void _showGuide() {
    final colors = context.coconutColors;
    CommonBottomSheets.showBottomSheet(
      context: context,
      title: widget.guideTitle,
      screenName: 'ark_vtxo_overview/interval_guide',
      showCloseButton: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final bucket in widget.buckets)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(color: bucket.color, shape: BoxShape.circle),
                    ),
                    SizedBox(
                      width: 72,
                      child: Text(
                        bucket.label,
                        style: CoconutTypography.body3_12_Number.setColor(colors.secondaryText),
                      ),
                    ),
                    Expanded(
                      child: Text(bucket.guide, style: CoconutTypography.body3_12_Number.setColor(colors.primaryText)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.buckets.isEmpty) return const SizedBox.shrink();
    final colors = context.coconutColors;
    final maxCount = widget.buckets.map((b) => b.vtxos.length).reduce((a, b) => a > b ? a : b).toDouble();
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: colors.utxoOverviewChartSurface,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(24),
              topRight: Radius.circular(48),
              bottomLeft: Radius.circular(24),
              bottomRight: Radius.circular(24),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final (index, bucket) in widget.buckets.indexed)
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _tap(index),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            height: _barMaxHeight,
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              width: double.infinity,
                              height: (_barMaxHeight * bucket.vtxos.length / (maxCount < 1 ? 1 : maxCount)).clamp(
                                4.0,
                                _barMaxHeight,
                              ),
                              decoration: BoxDecoration(
                                color:
                                    _tappedIndex == index
                                        ? bucket.color
                                        : Color.lerp(
                                          bucket.color,
                                          colors.divider,
                                          colors.utxoOverviewChartUnselectedOverlayOpacity,
                                        ),
                                borderRadius: const BorderRadius.all(Radius.circular(12)),
                              ),
                            ),
                          ),
                          Transform.translate(
                            offset: const Offset(0, -4),
                            child: Container(
                              width: 24,
                              height: 24,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: colors.utxoOverviewChartSurface,
                                borderRadius: BorderRadius.circular(999),
                                boxShadow: [
                                  BoxShadow(color: colors.shadowDefault, blurRadius: 4, offset: const Offset(0, 2)),
                                ],
                              ),
                              child: Text(
                                '${bucket.vtxos.length}',
                                style: CoconutTypography.caption_10_NumberBold.setColor(colors.primaryText),
                              ),
                            ),
                          ),
                          Text(
                            bucket.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: CoconutTypography.caption_10.setColor(colors.mutedText),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Positioned(
          top: -8,
          right: -8,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _showGuide,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: SvgPicture.asset(
                CommonStateIconPath.circleInfo,
                width: 18,
                height: 18,
                colorFilter: ColorFilter.mode(colors.iconSecondary, BlendMode.srcIn),
              ),
            ),
          ),
        ),
        if (_tappedIndex != null)
          Positioned(
            left: 16,
            right: 16,
            top: -8,
            height: 38,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (var index = 0; index < widget.buckets.length; index++)
                  Expanded(
                    child: Center(
                      child:
                          index == _tappedIndex
                              ? OverflowBox(
                                maxWidth: 100,
                                child: UtxoChartBubble(
                                  text: formatUtxoBalanceForTooltip(
                                    widget.buckets[index].totalSats,
                                    widget.currentUnit,
                                    dustThreshold: 0,
                                    isDustBucket: false,
                                  ),
                                  maxWidth: 100,
                                ),
                              )
                              : const SizedBox.shrink(),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// One bucket: "N VTXOs • amount" and its coins, which spread into a carousel when the row is the
/// active one (the row at the middle of the screen), as the UTXO overview's bucket rows.
class VtxoBucketRow extends StatelessWidget {
  const VtxoBucketRow({
    super.key,
    required this.bucket,
    required this.index,
    required this.currentUnit,
    required this.activeIndexListenable,
    required this.captionOf,
    required this.colorOf,
    required this.onTapVtxo,
  });

  static const double rowHeight = 210 + 24 + 4 + 4;

  final VtxoBucket bucket;
  final int index;
  final BitcoinUnit currentUnit;
  final ValueListenable<int> activeIndexListenable;
  final String Function(ArkVtxo vtxo) captionOf;
  final Color Function(ArkVtxo vtxo) colorOf;
  final void Function(ArkVtxo vtxo) onTapVtxo;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: rowHeight,
      child: ValueListenableBuilder<int>(
        valueListenable: activeIndexListenable,
        builder: (context, active, _) {
          final colors = context.coconutColors;
          return Column(
            children: [
              const SizedBox(height: 8),
              Text(
                t.ark.vtxo.count_amount(
                  count: bucket.vtxos.length,
                  amount: formatUtxoAmountForDisplay(bucket.totalSats, currentUnit, dustThreshold: 0),
                ),
                style: CoconutTypography.body2_14_NumberBold.setColor(
                  active == index ? colors.primaryText : colors.mutedText,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: _VtxoCoinStack(
                  vtxos: bucket.vtxos,
                  currentUnit: currentUnit,
                  isExpanded: active == index,
                  captionOf: captionOf,
                  colorOf: colorOf,
                  onTap: onTapVtxo,
                ),
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }
}

class _VtxoCoinStack extends StatefulWidget {
  const _VtxoCoinStack({
    required this.vtxos,
    required this.currentUnit,
    required this.isExpanded,
    required this.captionOf,
    required this.colorOf,
    required this.onTap,
  });

  static const double coinSize = 132.0;

  final List<ArkVtxo> vtxos;
  final BitcoinUnit currentUnit;
  final bool isExpanded;
  final String Function(ArkVtxo vtxo) captionOf;
  final Color Function(ArkVtxo vtxo) colorOf;
  final void Function(ArkVtxo vtxo) onTap;

  @override
  State<_VtxoCoinStack> createState() => _VtxoCoinStackState();
}

class _VtxoCoinStackState extends State<_VtxoCoinStack> {
  static const double _coinSize = _VtxoCoinStack.coinSize;
  static const double _collapsedOverlap = 24.0;
  static const double _expandedOverlap = 55.0;
  static const double _leftOverlap = 20.0;
  static const int _maxCollapsed = 5;
  static const Duration _animDuration = Duration(milliseconds: 300);
  static const Curve _animCurve = Curves.easeOutCubic;
  static const double _dragSensitivity = 0.015;
  static const double _focusedScale = 1.08;

  double _scrollOffset = 0;

  @override
  void didUpdateWidget(covariant _VtxoCoinStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isExpanded && oldWidget.isExpanded) _scrollOffset = 0;
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.vtxos.length;
    final isExpanded = widget.isExpanded;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final centerX = (width - _coinSize) / 2;
        final previewCount = total.clamp(0, _maxCollapsed);
        final extraCount = total - previewCount;
        final showBadge = extraCount > 0 && !isExpanded;
        const badgeGap = 8.0;
        final badgeWidth = showBadge ? 50.0 : 0.0;
        final firstBillOffset =
            (!isExpanded && total > 0 && VtxoCoinCard.isBillShape(widget.vtxos[0].amountSats))
                ? _coinSize * 0.175
                : 0.0;
        final collapsedBaseX = centerX - (showBadge ? badgeWidth + badgeGap + firstBillOffset : 0);
        final currentIndex = _scrollOffset.round().clamp(0, total - 1);

        final List<int> visible;
        if (isExpanded) {
          final rightSpace = width - centerX - _coinSize;
          final maxAfter = (rightSpace / _expandedOverlap).floor().clamp(1, total);
          final afterCount = (total - currentIndex - 1).clamp(0, maxAfter + 1);
          final maxBefore = (centerX / _leftOverlap).floor().clamp(0, total);
          final beforeCount = currentIndex.clamp(0, maxBefore + 1);
          final start = (currentIndex - beforeCount).clamp(0, total - 1);
          final end = (currentIndex + afterCount).clamp(0, total - 1);
          visible = [for (var i = start; i <= end; i++) i];
        } else {
          visible = [for (var i = 0; i < previewCount; i++) i];
        }

        double leftOf(int i) {
          if (isExpanded) {
            final position = i - currentIndex;
            return centerX + position * (position <= 0 ? _leftOverlap : _expandedOverlap);
          }
          return centerX + i * _collapsedOverlap;
        }

        final renderOrder = List<int>.from(visible)..sort((a, b) {
          final da = (a - _scrollOffset).abs();
          final db = (b - _scrollOffset).abs();
          return da != db ? db.compareTo(da) : a.compareTo(b);
        });

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate:
              isExpanded && total > 1
                  ? (details) => setState(() {
                    _scrollOffset = (_scrollOffset - details.delta.dx * _dragSensitivity).clamp(0.0, total - 1.0);
                  })
                  : null,
          child: SizedBox(
            height: _coinSize,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                if (extraCount > 0)
                  AnimatedPositioned(
                    duration: _animDuration,
                    curve: _animCurve,
                    left: collapsedBaseX,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: AnimatedOpacity(
                        duration: _animDuration,
                        opacity: isExpanded ? 0.0 : 1.0,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(999),
                            color: context.coconutColors.surfaceInfoChip,
                          ),
                          child: Text(
                            '+$extraCount',
                            style: CoconutTypography.body3_12_Number.setColor(context.coconutColors.primaryText),
                          ),
                        ),
                      ),
                    ),
                  ),
                for (final i in renderOrder)
                  AnimatedPositioned(
                    key: ValueKey(widget.vtxos[i].id),
                    duration: _animDuration,
                    curve: _animCurve,
                    left: leftOf(i) - (VtxoCoinCard.isBillShape(widget.vtxos[i].amountSats) ? _coinSize * 0.175 : 0),
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: AnimatedScale(
                        scale: (isExpanded && i == currentIndex) ? _focusedScale : 1.0,
                        duration: _animDuration,
                        curve: _animCurve,
                        child: VtxoCoinCard(
                          vtxo: widget.vtxos[i],
                          size: _coinSize,
                          compact: !isExpanded,
                          isFocused: isExpanded && i == currentIndex,
                          currentUnit: widget.currentUnit,
                          caption: widget.captionOf(widget.vtxos[i]),
                          tierColor: widget.colorOf(widget.vtxos[i]),
                          onTap: () => widget.onTap(widget.vtxos[i]),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A VTXO as a coin (or a bill from 0.1 BTC), as the UTXO overview's coin card: the tier colour,
/// the amount, a caption (time to expiry) and a lock badge when it's held by an operation.
class VtxoCoinCard extends StatefulWidget {
  const VtxoCoinCard({
    super.key,
    required this.vtxo,
    required this.size,
    required this.currentUnit,
    required this.caption,
    required this.tierColor,
    required this.onTap,
    this.compact = false,
    this.isFocused = true,
  });

  static const int _billThreshold = 10_000_000; // 0.1 BTC
  static bool isBillShape(int sats) => sats >= _billThreshold;

  final ArkVtxo vtxo;
  final double size;
  final BitcoinUnit currentUnit;
  final String caption;
  final Color tierColor;
  final VoidCallback onTap;
  final bool compact;
  final bool isFocused;

  @override
  State<VtxoCoinCard> createState() => _VtxoCoinCardState();
}

/// Keeps the tier colour far enough in lightness from the coin surface for the watermark to show
/// (as the UTXO coin card does).
Color _legibleTierColor(Color tierColor, Color surface) {
  const minLightnessGap = 0.28;
  final hsl = HSLColor.fromColor(tierColor);
  final surfaceLightness = HSLColor.fromColor(surface).lightness;
  if ((hsl.lightness - surfaceLightness).abs() >= minLightnessGap) return tierColor;
  final target =
      surfaceLightness >= 0.5
          ? (surfaceLightness - minLightnessGap).clamp(0.0, 1.0)
          : (surfaceLightness + minLightnessGap).clamp(0.0, 1.0);
  return hsl.withLightness(target).toColor();
}

class _VtxoCoinCardState extends State<VtxoCoinCard> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.coconutColors;
    final isLarge = !widget.compact;
    final isBill = VtxoCoinCard.isBillShape(widget.vtxo.amountSats);
    final width = isBill ? widget.size * 1.35 : widget.size;
    final height = isBill ? widget.size * 0.85 : widget.size;
    final tier = _legibleTierColor(widget.tierColor, colors.utxoOverviewCoinSurface);
    final tint = widget.isFocused ? tier : Color.lerp(colors.background, tier, colors.utxoOverviewCoinTintStrength)!;
    final innerStroke = tint.withValues(alpha: widget.isFocused ? 0.2 : colors.utxoOverviewCoinInnerStrokeOpacity);

    Widget content() => Stack(
      alignment: Alignment.center,
      children: [
        Positioned.fill(
          child: Padding(
            padding: EdgeInsets.all(widget.size * 0.2),
            child: Opacity(
              opacity: widget.isFocused ? 0.2 : colors.utxoOverviewCoinIconOpacity,
              child: SvgPicture.asset(
                FeatureWalletIconPath.bitcoin,
                colorFilter: ColorFilter.mode(tint, BlendMode.srcIn),
              ),
            ),
          ),
        ),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  formatUtxoBalanceForTooltip(
                    widget.vtxo.amountSats,
                    widget.currentUnit,
                    dustThreshold: 0,
                    isDustBucket: false,
                  ),
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  style: (isLarge ? CoconutTypography.heading4_18_NumberBold : CoconutTypography.body1_16_NumberBold)
                      .setColor(colors.primaryText.withValues(alpha: widget.isFocused ? 1 : 0.4)),
                ),
              ),
              if (isLarge) ...[
                const SizedBox(height: 4),
                Text(
                  widget.caption,
                  textAlign: TextAlign.center,
                  style: CoconutTypography.caption_10.setColor(
                    colors.mutedText.withValues(alpha: widget.isFocused ? 1 : 0.4),
                  ),
                ),
              ],
            ],
          ),
        ),
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.all(5),
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: isBill ? BoxShape.rectangle : BoxShape.circle,
                borderRadius: isBill ? BorderRadius.circular(5) : null,
                border: Border.all(color: innerStroke, width: 4),
              ),
            ),
          ),
        ),
      ],
    );

    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) => setState(() => _isPressed = false),
      onTapCancel: () => setState(() => _isPressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _isPressed ? 0.92 : 1.0,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeInOut,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: width,
              height: height,
              decoration: BoxDecoration(
                shape: isBill ? BoxShape.rectangle : BoxShape.circle,
                borderRadius: isBill ? BorderRadius.circular(8) : null,
                color: isBill ? colors.utxoOverviewBillSurface : colors.utxoOverviewCoinSurface,
                boxShadow: [
                  BoxShadow(
                    color: colors.shadowDefault,
                    blurRadius: widget.isFocused ? 16.0 : 6.0,
                    spreadRadius: widget.isFocused ? 2 : 0,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child:
                  isBill
                      ? ClipRRect(borderRadius: BorderRadius.circular(8), child: content())
                      : ClipOval(child: content()),
            ),
            if (widget.vtxo.isLocked)
              Positioned(
                bottom: isLarge ? 4 : 2,
                right: isLarge ? 4 : 2,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(color: colors.primaryText.withValues(alpha: 0.5), shape: BoxShape.circle),
                  child: SvgPicture.asset(
                    CommonSecurityIconPath.lock,
                    width: isLarge ? 16 : 12,
                    height: isLarge ? 16 : 12,
                    colorFilter: ColorFilter.mode(colors.dimOverlay, BlendMode.srcIn),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The kebab and its pulldown menu, as the wallet list's app bar menu.
class VtxoMenuButton extends StatefulWidget {
  const VtxoMenuButton({super.key, required this.items, required this.onSelected});

  final List<String> items;
  final ValueChanged<int> onSelected;

  @override
  State<VtxoMenuButton> createState() => _VtxoMenuButtonState();
}

class _VtxoMenuButtonState extends State<VtxoMenuButton> {
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _menu;

  @override
  void dispose() {
    _removeMenu();
    super.dispose();
  }

  void _showMenu() {
    if (_menu != null) return;
    _menu = OverlayEntry(
      builder:
          (overlayContext) => Stack(
            children: [
              Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.translucent, onTap: _removeMenu)),
              CompositedTransformFollower(
                link: _layerLink,
                showWhenUnlinked: false,
                targetAnchor: Alignment.bottomRight,
                followerAnchor: Alignment.topRight,
                child: CoconutPulldownMenu(
                  backgroundColor: overlayContext.coconutColors.pulldownMenuBackground,
                  shadowColor: overlayContext.coconutColors.shadowDefault.withValues(alpha: 0.06),
                  dividerColor: overlayContext.coconutColors.pulldownMenuDividerColor,
                  splashColor: overlayContext.coconutColors.pulldownMenuPressedColor,
                  textColor: overlayContext.coconutColors.pulldownMenuTextColor,
                  entries: [for (final item in widget.items) CoconutPulldownMenuItem(title: item)],
                  onSelected: (index, _) {
                    _removeMenu();
                    widget.onSelected(index);
                  },
                ),
              ),
            ],
          ),
    );
    Overlay.of(context, rootOverlay: true).insert(_menu!);
  }

  void _removeMenu() {
    _menu?.remove();
    _menu = null;
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: SizedBox(
        width: 40,
        height: 40,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _menu == null ? _showMenu() : _removeMenu(),
          child: Center(
            child: SvgPicture.asset(
              CommonMenuIconPath.kebab,
              colorFilter: ColorFilter.mode(context.coconutColors.iconPrimary, BlendMode.srcIn),
            ),
          ),
        ),
      ),
    );
  }
}
