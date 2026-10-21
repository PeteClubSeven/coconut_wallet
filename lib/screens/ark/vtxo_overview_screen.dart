import 'package:coconut_design_system/coconut_design_system.dart'
    hide CoconutAppBar, CoconutPopup, CoconutToast, CoconutUnderlinedButton;
import 'package:coconut_wallet/app/router/app_route_names.dart';
import 'package:coconut_wallet/constants/icon_path.dart';
import 'package:coconut_wallet/design_system/context/coconut_theme_context_extension.dart';
import 'package:coconut_wallet/enums/fiat_enums.dart';
import 'package:coconut_wallet/localization/strings.g.dart';
import 'package:coconut_wallet/model/ark/ark_balance.dart';
import 'package:coconut_wallet/model/ark/ark_snapshot.dart';
import 'package:coconut_wallet/model/ark/ark_vtxo.dart';
import 'package:coconut_wallet/model/utxo/utxo_bucket.dart';
import 'package:coconut_wallet/providers/ark_provider.dart';
import 'package:coconut_wallet/providers/node_provider/node_provider.dart';
import 'package:coconut_wallet/providers/preferences/preference_provider.dart';
import 'package:coconut_wallet/providers/price_provider.dart';
import 'package:coconut_wallet/providers/wallet_provider.dart';
import 'package:coconut_wallet/app/router/route_args.dart';
import 'package:coconut_wallet/screens/ark/ark_unlock_flow.dart';
import 'package:coconut_wallet/screens/ark/vtxo_refresh_flow.dart';
import 'package:coconut_wallet/screens/wallet_detail/utxo_overview/utxo_bucket_scroll_rail.dart';
import 'package:coconut_wallet/screens/wallet_detail/utxo_overview/utxo_overview_filter_widgets.dart';
import 'package:coconut_wallet/screens/wallet_detail/utxo_overview/utxo_overview_header.dart';
import 'package:coconut_wallet/services/model/response/block_timestamp.dart';
import 'package:coconut_wallet/ui/coconut/coconut_overlays.dart';
import 'package:coconut_wallet/utils/datetime_util.dart';
import 'package:coconut_wallet/utils/utxo_amount_format_util.dart';
import 'package:coconut_wallet/widgets/common/buttons/fixed_bottom_button.dart';
import 'package:coconut_wallet/widgets/common/buttons/fixed_bottom_tween_button.dart';
import 'package:coconut_wallet/widgets/common/buttons/shrink_animation_button.dart';
import 'package:coconut_wallet/widgets/common/overlays/common_bottom_sheets.dart';
import 'package:coconut_wallet/widgets/features/ark/ark_texts.dart';
import 'package:coconut_wallet/widgets/features/ark/ark_ui.dart';
import 'package:coconut_wallet/widgets/features/ark/vtxo_overview_widgets.dart';
import 'package:coconut_wallet/widgets/features/transaction/card/underline_button_item_card.dart';
import 'package:coconut_wallet/widgets/features/wallet/icon/wallet_refresh_icon.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

/// The Ark side of a hot wallet, laid out like the UTXO overview: the Ark balance in the collapsing
/// header, an Overview of VTXOs as coins grouped by amount or by expiry, and a List with
/// delegated refresh. Balance details and recovery live behind the header's menu. Reads the
/// cache, so it works while the wallet is locked.
class VtxoOverviewScreen extends StatefulWidget {
  const VtxoOverviewScreen({super.key, required this.id, this.startRefresh = false});

  final int id;

  /// Open in refresh mode, with the VTXOs bark wants refreshed selected.
  final bool startRefresh;

  @override
  State<VtxoOverviewScreen> createState() => _VtxoOverviewScreenState();
}

class _VtxoOverviewScreenState extends State<VtxoOverviewScreen> {
  static const double _collapseExtent = 96;
  static const double _itemHeight = 10 + VtxoBucketRow.rowHeight + 10;

  late final ArkProvider _arkProvider;
  late BitcoinUnit _unit;
  final ScrollController _headerScrollController = ScrollController();
  ScrollController? _contentScrollController;
  final ValueNotifier<int> _activeIndex = ValueNotifier(0);
  final ValueNotifier<double> _activeBucketY = ValueNotifier(0);
  final GlobalKey _chartKey = GlobalKey();
  final GlobalKey _railKey = GlobalKey();
  List<GlobalKey> _bucketKeys = [];
  bool _isSnappingHeader = false;

  bool _isOverview = true;
  bool _isByAmount = true;
  bool _showLockedOnly = false;
  bool _isSelecting = false;
  final Set<String> _selectedIds = {};
  bool _isRefreshing = false;
  int? _nextRefreshHeight;

  @override
  void initState() {
    super.initState();
    _arkProvider = context.read<ArkProvider>();
    _unit = context.read<PreferenceProvider>().currentUnit;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadRefreshInfo();
      if (widget.startRefresh) await _startSelecting();
    });
  }

  @override
  void dispose() {
    _contentScrollController?.removeListener(_updateActiveBucket);
    _headerScrollController.dispose();
    _activeIndex.dispose();
    _activeBucketY.dispose();
    super.dispose();
  }

  // --- Ark actions ---

  Future<void> _loadRefreshInfo() async {
    if (!_arkProvider.isOpen(widget.id)) return;
    try {
      final height = await _arkProvider.nextRequiredRefreshHeight(widget.id);
      if (mounted) setState(() => _nextRefreshHeight = height);
    } catch (_) {
      // Shown from the cache instead.
    }
  }

  Future<bool> _ensureOpen() async {
    final opened = await openArkWalletForSession(context, widget.id, userInitiated: true);
    if (opened) await _loadRefreshInfo();
    return opened;
  }

  /// Refresh happens in the list: it opens with the VTXOs bark wants refreshed selected.
  Future<void> _startSelecting() async {
    if (!await _ensureOpen() || !mounted) return;
    List<String> due = const [];
    try {
      due = await _arkProvider.vtxoIdsToRefresh(widget.id);
    } catch (_) {
      // Let the user pick.
    }
    if (!mounted) return;
    setState(() {
      _isOverview = false;
      _showLockedOnly = false;
      _isSelecting = true;
      _selectedIds
        ..clear()
        ..addAll(due);
    });
    if (due.isEmpty) _toast(t.ark.vtxo.none_due);
  }

  void _stopSelecting() => setState(() {
    _isSelecting = false;
    _selectedIds.clear();
  });

  Future<void> _confirmRefresh() async {
    setState(() => _isRefreshing = true);
    try {
      final scheduled = await refreshVtxosWithConfirmation(
        context,
        walletId: widget.id,
        ids: _selectedIds.toList(),
        unit: _unit,
      );
      if (scheduled && mounted) _stopSelecting();
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  Future<void> _retryRecovery() async {
    final wallet = context.read<WalletProvider>().getWalletById(widget.id);
    final seedHex = await unlockArkSeed(context, wallet);
    if (seedHex == null) return;
    await _arkProvider.retryRecovery(widget.id, seedHex);
  }

  void _toast(String text) => CoconutToast.showBottomToast(context: context, text: text);

  void _toggleUnit() => setState(() => _unit = _unit.isBasedOnSatoshi ? BitcoinUnit.btc : BitcoinUnit.sats);

  // --- Menu ---

  void _onMenuSelected(int index, ArkSnapshot? snapshot, int? tipHeight) {
    switch (index) {
      case 0:
        if (snapshot != null) _showBalanceDetails(snapshot, tipHeight);
      case 1:
        if (snapshot != null) _showRecovery(snapshot);
      case 2:
        _startSelecting();
    }
  }

  void _showBalanceDetails(ArkSnapshot snapshot, int? tipHeight) {
    final valueStyle = CoconutTypography.body2_14_Number.setColor(context.coconutColors.primaryText);
    final earliestExpiry =
        snapshot.vtxos.isEmpty ? null : snapshot.vtxos.map((vtxo) => vtxo.expiryHeight).reduce((a, b) => a < b ? a : b);
    final rows = <(String, String)>[
      for (final (label, sats) in _breakdown(snapshot.balance)) (label, formatSats(_unit, sats)),
      if (_nextRefreshHeight != null)
        (t.ark.vtxo.refresh_due, _blocks(_nextRefreshHeight!, tipHeight))
      else if (earliestExpiry != null)
        (t.ark.vtxo.earliest_expiry, _blocks(earliestExpiry, tipHeight)),
      if (snapshot.syncedAt != null)
        (t.ark.vtxo.last_synced, DateTimeUtil.formatTimestamp(snapshot.syncedAt!).join(' ')),
    ];
    CommonBottomSheets.showBottomSheet(
      context: context,
      title: t.ark.vtxo.menu_balance,
      screenName: '${AppRouteNames.arkWallet}/balance',
      showCloseButton: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (index, (label, value)) in rows.indexed)
              UnderlineButtonItemCard(
                label: label,
                showDivider: index < rows.length - 1,
                child: Text(value, style: valueStyle),
              ),
          ],
        ),
      ),
    );
  }

  void _showRecovery(ArkSnapshot snapshot) {
    final colors = context.coconutColors;
    final canRetry = _arkProvider.isOpen(widget.id) && !_arkProvider.isSyncing(widget.id) && snapshot.canRetryRecovery;
    CommonBottomSheets.showBottomSheet(
      context: context,
      title: t.ark.vtxo.menu_recovery,
      screenName: '${AppRouteNames.arkWallet}/recovery',
      showCloseButton: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UnderlineButtonItemCard(
              label: t.ark.vtxo.recovery,
              showDivider: false,
              child: Text(
                _recoveryState(snapshot.recovery.state),
                style: CoconutTypography.body2_14_Number.setColor(colors.primaryText),
              ),
            ),
            // bark's own report (counts and amounts), as cached.
            Text(snapshot.recovery.description, style: CoconutTypography.body3_12.setColor(colors.secondaryText)),
            if (canRetry) ...[
              CoconutLayout.spacing_500h,
              InlineActionButton(
                text: t.ark.vtxo.retry_recovery,
                onPressed: () {
                  Navigator.pop(context);
                  _retryRecovery();
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _recoveryState(ArkRecoveryState state) => switch (state) {
    ArkRecoveryState.notRun => t.ark.vtxo.recovery_not_run,
    ArkRecoveryState.completed => t.ark.vtxo.recovery_completed,
    ArkRecoveryState.failed => t.ark.vtxo.recovery_failed,
  };

  List<(String, int)> _breakdown(ArkBalance balance) => [
    (t.ark.vtxo.spendable, balance.spendable),
    (t.ark.vtxo.pending_in_round, balance.pendingInRound),
    (t.ark.vtxo.pending_board, balance.pendingBoard),
    (t.ark.vtxo.pending_lightning_send, balance.pendingLightningSend),
    (t.ark.vtxo.claimable_lightning_receive, balance.claimableLightningReceive),
    (t.ark.vtxo.pending_exit, balance.pendingExit),
  ];

  // --- Header and scrolling, as the UTXO overview ---

  bool _handleScrollEnd(ScrollEndNotification notification) {
    if (!_headerScrollController.hasClients || _isSnappingHeader || notification.depth != 0) return false;
    final offset = _headerScrollController.offset;
    if (offset <= 0 || offset >= _collapseExtent) return false;
    final target = offset < _collapseExtent * 0.7 ? 0.0 : _collapseExtent;
    _isSnappingHeader = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_headerScrollController.hasClients) {
        _isSnappingHeader = false;
        return;
      }
      HapticFeedback.selectionClick();
      try {
        await _headerScrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        );
      } finally {
        _isSnappingHeader = false;
      }
    });
    return false;
  }

  Future<void> _selectTab(int index) async {
    final overview = index == 0;
    if (overview == _isOverview) return;
    setState(() {
      _isOverview = overview;
      if (overview) {
        _isSelecting = false;
        _selectedIds.clear();
      }
    });
    await WidgetsBinding.instance.endOfFrame;
    if (mounted && _headerScrollController.hasClients && _headerScrollController.offset > 0) {
      _isSnappingHeader = true;
      try {
        await _headerScrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeInOutCubic,
        );
      } finally {
        _isSnappingHeader = false;
      }
    }
  }

  void _bindContentScrollController(BuildContext context) {
    final controller = PrimaryScrollController.maybeOf(context);
    if (controller == null || identical(controller, _contentScrollController)) return;
    _contentScrollController?.removeListener(_updateActiveBucket);
    _contentScrollController = controller;
    controller.addListener(_updateActiveBucket);
  }

  /// The bucket row at the middle of the visible list is the active (expanded) one.
  void _updateActiveBucket() {
    final controller = _contentScrollController;
    if (!mounted || controller == null || !controller.hasClients || !_isOverview) return;
    final count = _bucketKeys.length;
    if (count == 0) return;
    if (count == 1) {
      if (_activeIndex.value != 0) _activeIndex.value = 0;
      _updateBucketY(0);
      return;
    }
    final position = controller.position;
    final chartBox = _chartKey.currentContext?.findRenderObject() as RenderBox?;
    final chartHeight = chartBox?.hasSize == true ? chartBox!.size.height : 0.0;
    final pixels = position.pixels;
    final target =
        pixels <= position.minScrollExtent + 1
            ? 0
            : pixels >= position.maxScrollExtent - 1
            ? count - 1
            : ((pixels + position.viewportDimension / 2 - chartHeight) / _itemHeight).floor().clamp(0, count - 1);
    if (target != _activeIndex.value) _activeIndex.value = target;
    _updateBucketY(target);
  }

  void _updateBucketY(int index) {
    final bucketBox = _bucketKeys[index].currentContext?.findRenderObject() as RenderBox?;
    final railBox = _railKey.currentContext?.findRenderObject() as RenderBox?;
    if (bucketBox == null || !bucketBox.hasSize || railBox == null || !railBox.hasSize) return;
    final center = bucketBox.localToGlobal(Offset(bucketBox.size.width / 2, bucketBox.size.height / 2));
    _activeBucketY.value = center.dy - railBox.localToGlobal(Offset.zero).dy;
  }

  // --- Layout ---

  @override
  Widget build(BuildContext context) {
    final colors = context.coconutColors;
    return Consumer<ArkProvider>(
      builder: (context, arkProvider, _) {
        final snapshot = arkProvider.snapshot(widget.id);
        final isOpen = arkProvider.isOpen(widget.id);
        final isBusy = arkProvider.isOpening(widget.id) || arkProvider.isSyncing(widget.id);
        final vtxos = snapshot?.vtxos ?? const <ArkVtxo>[];
        return ValueListenableBuilder<BlockTimestamp?>(
          valueListenable: context.read<NodeProvider>().currentBlockNotifier,
          builder: (context, tip, _) {
            return Scaffold(
              backgroundColor: colors.background,
              body: Stack(
                children: [
                  NotificationListener<ScrollEndNotification>(
                    onNotification: _handleScrollEnd,
                    child: NestedScrollView(
                      controller: _headerScrollController,
                      physics: const AlwaysScrollableScrollPhysics(),
                      headerSliverBuilder:
                          (context, _) => [_buildHeader(snapshot, vtxos, isBusy: isBusy, tipHeight: tip?.height)],
                      body: Builder(
                        builder: (innerContext) {
                          _bindContentScrollController(innerContext);
                          return _isOverview
                              ? _buildOverviewBody(
                                snapshot,
                                vtxos,
                                isOpen: isOpen,
                                isBusy: isBusy,
                                tipHeight: tip?.height,
                              )
                              : _buildListBody(vtxos, tip?.height);
                        },
                      ),
                    ),
                  ),
                  if (_isSelecting && vtxos.isNotEmpty)
                    FixedBottomTweenButton(
                      leftText: t.cancel,
                      rightText:
                          _isRefreshing ? t.ark.vtxo.refreshing : t.ark.vtxo.refresh_n(count: _selectedIds.length),
                      leftButtonClicked: _isRefreshing ? () {} : _stopSelecting,
                      rightButtonClicked: _confirmRefresh,
                      isRightButtonActive: !_isRefreshing && _selectedIds.isNotEmpty,
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  SliverPersistentHeader _buildHeader(
    ArkSnapshot? snapshot,
    List<ArkVtxo> vtxos, {
    required bool isBusy,
    required int? tipHeight,
  }) {
    final total = snapshot?.balance.total ?? 0;
    return SliverPersistentHeader(
      pinned: true,
      delegate: UtxoHeaderDelegate(
        topPadding: MediaQuery.paddingOf(context).top,
        balanceLabel: t.ark.vtxo.ark_balance,
        totalBalance: formatUtxoAmountForDisplay(total, _unit, dustThreshold: 0),
        fiatPrice: context.read<PriceProvider>().getFiatPrice(total),
        bottomBar:
            _isOverview
                ? VtxoGroupingTabBar(
                  isByAmount: _isByAmount,
                  onSelected: (index) => setState(() => _isByAmount = index == 0),
                )
                : _buildListFilterBar(vtxos),
        isOverviewSelected: _isOverview,
        onBackPressed: () => Navigator.pop(context),
        onTabChanged: _selectTab,
        refreshButton: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            WalletRefreshIndicator(isRefreshing: isBusy),
            VtxoMenuButton(
              items: [t.ark.vtxo.menu_balance, t.ark.vtxo.menu_recovery, t.ark.vtxo.menu_refresh],
              onSelected: (index) => _onMenuSelected(index, snapshot, tipHeight),
            ),
          ],
        ),
      ),
    );
  }

  /// All / Locked chips, as the UTXO list's filter header.
  Widget _buildListFilterBar(List<ArkVtxo> vtxos) {
    final lockedCount = vtxos.where((vtxo) => vtxo.isLocked).length;
    return Container(
      color: context.coconutColors.background,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          AnimatedUtxoFilterChip(
            label: t.ark.vtxo.all,
            count: vtxos.length,
            isSelected: !_showLockedOnly,
            onTap: () => setState(() => _showLockedOnly = false),
          ),
          CoconutLayout.spacing_200w,
          AnimatedUtxoFilterChip(
            label: t.ark.vtxo.locked,
            count: lockedCount,
            isSelected: _showLockedOnly,
            onTap: () => setState(() => _showLockedOnly = true),
          ),
        ],
      ),
    );
  }

  Widget _buildOverviewBody(
    ArkSnapshot? snapshot,
    List<ArkVtxo> vtxos, {
    required bool isOpen,
    required bool isBusy,
    required int? tipHeight,
  }) {
    final colors = context.coconutColors;
    final tierTheme = context.watch<PreferenceProvider>().utxoTierTheme;
    final buckets =
        _isByAmount
            ? bucketVtxosByAmount(vtxos, tierTheme)
            : bucketVtxosByExpiry(vtxos, tipHeight, tierTheme, (danger: colors.danger, warning: colors.warning));
    if (_bucketKeys.length != buckets.length) {
      _bucketKeys = [for (var i = 0; i < buckets.length; i++) GlobalKey()];
      _activeIndex.value = 0;
    }
    final recoveryFailed = snapshot?.recovery.state == ArkRecoveryState.failed;
    final refreshDue = _nextRefreshHeight;
    return Stack(
      children: [
        if (buckets.length > 1 && _contentScrollController != null)
          Positioned(
            left: -8,
            top: 0,
            bottom: 0,
            width: 34,
            child: UtxoBucketScrollRail(
              key: _railKey,
              buckets: const <UtxoBucket>[],
              scrollController: _contentScrollController!,
              activeIndexListenable: _activeIndex,
              activeBucketY: _activeBucketY,
            ),
          ),
        CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            CupertinoSliverRefreshControl(
              onRefresh: () => _arkProvider.syncNow(widget.id),
              refreshTriggerPullDistance: 80,
              builder: (_, _, _, _, _) => const SizedBox.shrink(),
            ),
            SliverToBoxAdapter(
              child: Column(
                key: _chartKey,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!isOpen)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: ArkNoticeCard(
                        title: t.ark.vtxo.locked_title,
                        description: t.ark.vtxo.locked_description,
                        iconPath: CommonSecurityIconPath.lock,
                        actionText: isBusy ? null : t.ark.send.unlock,
                        onAction: _ensureOpen,
                      ),
                    ),
                  if (recoveryFailed)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: ArkNoticeCard(
                        title: t.ark.vtxo.recovery_failed_title,
                        description: t.ark.vtxo.recovery_failed_description,
                        iconPath: CommonStateIconPath.triangleWarning,
                        isWarning: true,
                        actionText: t.ark.vtxo.retry_recovery,
                        onAction: () => _showRecovery(snapshot!),
                      ),
                    ),
                  GestureDetector(
                    onTap: _toggleUnit,
                    child: VtxoSummaryChart(
                      buckets: buckets,
                      vtxos: vtxos,
                      currentUnit: _unit,
                      guideTitle:
                          _isByAmount ? t.utxo_overview_screen.interval_info_title : t.ark.vtxo.expiry_guide_title,
                      footer:
                          refreshDue == null
                              ? null
                              : Text(
                                '${t.ark.vtxo.refresh_due} · ${_blocks(refreshDue, tipHeight)}',
                                style: CoconutTypography.caption_10.setColor(colors.mutedText),
                              ),
                    ),
                  ),
                ],
              ),
            ),
            if (buckets.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Text(
                    snapshot == null ? (isOpen ? t.ark.vtxo.syncing : t.ark.vtxo.nothing_synced) : t.ark.vtxo.empty,
                    style: CoconutTypography.body2_14.setColor(colors.secondaryText),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.only(left: 38),
                sliver: SliverList.builder(
                  itemCount: buckets.length,
                  itemBuilder: (context, index) {
                    final bucket = buckets[index];
                    return Padding(
                      key: _bucketKeys[index],
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                      child: VtxoBucketRow(
                        bucket: bucket,
                        index: index,
                        currentUnit: _unit,
                        activeIndexListenable: _activeIndex,
                        captionOf: (vtxo) => _blocks(vtxo.expiryHeight, tipHeight),
                        colorOf:
                            (vtxo) =>
                                _isByAmount ? tierTheme.colorForSats(vtxo.amountSats, dustThreshold: 0) : bucket.color,
                        onTapVtxo: _openVtxo,
                      ),
                    );
                  },
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 120)),
          ],
        ),
      ],
    );
  }

  Widget _buildListBody(List<ArkVtxo> vtxos, int? tipHeight) {
    final colors = context.coconutColors;
    final shown =
        (_showLockedOnly ? vtxos.where((vtxo) => vtxo.isLocked) : vtxos).toList()
          ..sort((a, b) => a.expiryHeight.compareTo(b.expiryHeight));
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        CupertinoSliverRefreshControl(
          onRefresh: () => _arkProvider.syncNow(widget.id),
          refreshTriggerPullDistance: 80,
          builder: (_, _, _, _, _) => const SizedBox.shrink(),
        ),
        if (shown.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.only(top: 80),
              child: Text(
                t.ark.vtxo.empty,
                textAlign: TextAlign.center,
                style: CoconutTypography.body2_14.setColor(colors.secondaryText),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 160),
            sliver: SliverList.builder(
              itemCount: shown.length,
              itemBuilder:
                  (context, index) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _buildVtxoCard(shown[index], tipHeight),
                  ),
            ),
          ),
      ],
    );
  }

  /// One VTXO, as the UTXO list's item card: expiry and amount, then its id and state.
  Widget _buildVtxoCard(ArkVtxo vtxo, int? tipHeight) {
    final colors = context.coconutColors;
    final isSelected = _selectedIds.contains(vtxo.id);
    return Opacity(
      opacity: _isSelecting && vtxo.isLocked ? 0.5 : 1,
      child: ShrinkAnimationButton(
        onPressed: () {
          if (!_isSelecting) {
            _openVtxo(vtxo);
          } else if (!vtxo.isLocked) {
            setState(() => isSelected ? _selectedIds.remove(vtxo.id) : _selectedIds.add(vtxo.id));
          }
        },
        defaultColor: colors.surface,
        pressedOverlayColor: colors.surfacePressOverlay,
        pressedOverlayOpacity: colors.surfacePressOverlayOpacity,
        borderRadius: CoconutStyles.radius_300,
        borderWidth: 0,
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(
              color:
                  _isSelecting
                      ? (isSelected ? colors.borderStrong : colors.borderStrong.withAlpha(40))
                      : Colors.transparent,
            ),
            borderRadius: BorderRadius.circular(CoconutStyles.radius_300),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (_isSelecting) ...[
                    SvgPicture.asset(
                      CommonFormIconPath.circleCheck,
                      width: 20,
                      height: 20,
                      colorFilter: ColorFilter.mode(
                        isSelected ? colors.borderStrong : colors.borderStrong.withAlpha(40),
                        BlendMode.srcIn,
                      ),
                    ),
                    CoconutLayout.spacing_100w,
                  ],
                  Text(
                    _blocks(vtxo.expiryHeight, tipHeight),
                    style: CoconutTypography.body3_12_Number.setColor(colors.secondaryText),
                  ),
                  CoconutLayout.spacing_200w,
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (vtxo.isLocked) ...[
                            SvgPicture.asset(
                              CommonSecurityIconPath.lock,
                              width: 16,
                              height: 16,
                              colorFilter: ColorFilter.mode(colors.iconPrimary, BlendMode.srcIn),
                            ),
                            const SizedBox(width: 4),
                          ],
                          Text(
                            _unit.displayBitcoinAmount(vtxo.amountSats),
                            style: CoconutTypography.heading4_18_NumberBold.setColor(colors.primaryText),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              CoconutLayout.spacing_100h,
              Text(
                shortenMiddle(vtxo.id, head: 18, tail: 12),
                style: CoconutTypography.body2_14_Number.setColor(colors.secondaryText).copyWith(height: 1.3),
              ),
              if (vtxo.isLocked) ...[CoconutLayout.spacing_150h, ArkChip(t.ark.vtxo.locked)],
            ],
          ),
        ),
      ),
    );
  }

  void _openVtxo(ArkVtxo vtxo) =>
      Navigator.pushNamed(context, AppRouteNames.vtxoDetail, arguments: VtxoDetailRouteArgs(id: widget.id, vtxo: vtxo));

  static String _blocks(int height, int? tipHeight) {
    if (tipHeight == null) return t.ark.vtxo.at_block(height: height);
    final left = height - tipHeight;
    if (left <= 0) return t.ark.vtxo.expired;
    return t.ark.vtxo.in_blocks(count: left);
  }
}
