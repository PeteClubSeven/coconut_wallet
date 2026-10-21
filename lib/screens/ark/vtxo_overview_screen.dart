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
import 'package:coconut_wallet/providers/ark_provider.dart';
import 'package:coconut_wallet/providers/node_provider/node_provider.dart';
import 'package:coconut_wallet/providers/preferences/preference_provider.dart';
import 'package:coconut_wallet/providers/wallet_provider.dart';
import 'package:coconut_wallet/screens/ark/ark_unlock_flow.dart';
import 'package:coconut_wallet/services/model/response/block_timestamp.dart';
import 'package:coconut_wallet/ui/coconut/coconut_app_bar.dart';
import 'package:coconut_wallet/ui/coconut/coconut_overlays.dart';
import 'package:coconut_wallet/ui/coconut/coconut_underlined_button.dart';
import 'package:coconut_wallet/utils/datetime_util.dart';
import 'package:coconut_wallet/widgets/common/amount/animated_balance.dart';
import 'package:coconut_wallet/widgets/common/amount/bitcoin_amount_unit.dart';
import 'package:coconut_wallet/widgets/common/amount/fiat_price.dart';
import 'package:coconut_wallet/widgets/common/buttons/copy_text_container.dart';
import 'package:coconut_wallet/widgets/common/buttons/fixed_bottom_button.dart';
import 'package:coconut_wallet/widgets/common/buttons/fixed_bottom_tween_button.dart';
import 'package:coconut_wallet/widgets/common/buttons/shrink_animation_button.dart';
import 'package:coconut_wallet/widgets/common/overlays/common_bottom_sheets.dart';
import 'package:coconut_wallet/widgets/features/ark/ark_texts.dart';
import 'package:coconut_wallet/widgets/features/ark/ark_ui.dart';
import 'package:coconut_wallet/widgets/features/transaction/card/underline_button_item_card.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

/// The Ark side of a hot wallet, laid out like the UTXO list: its balance and breakdown, recovery
/// status and VTXOs, with delegated refresh. Reads the cache, so it works while the wallet is
/// locked.
class VtxoOverviewScreen extends StatefulWidget {
  const VtxoOverviewScreen({super.key, required this.id, this.startRefresh = false});

  final int id;

  /// Open in refresh mode, with the VTXOs bark wants refreshed selected.
  final bool startRefresh;

  @override
  State<VtxoOverviewScreen> createState() => _VtxoOverviewScreenState();
}

class _VtxoOverviewScreenState extends State<VtxoOverviewScreen> {
  late final ArkProvider _arkProvider;
  late BitcoinUnit _unit;
  bool _isSelecting = false;
  final Set<String> _selectedIds = {};
  bool _isRefreshing = false;
  int? _nextRefreshHeight;
  int _shownBalance = 0;

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
    final ids = _selectedIds.toList();
    if (ids.isEmpty) return;
    setState(() => _isRefreshing = true);
    try {
      final fee = await _arkProvider.estimateRefreshFee(widget.id, ids);
      if (!mounted) return;
      final confirmed = await confirmArkAction(
        context,
        title: t.ark.vtxo.refresh_title(count: ids.length),
        description: t.ark.vtxo.refresh_description(fee: formatSats(_unit, fee)),
      );
      if (!confirmed || !mounted) return;
      await _arkProvider.refreshDelegated(widget.id, ids);
      if (!mounted) return;
      _stopSelecting();
      _toast(t.ark.vtxo.refresh_scheduled);
    } catch (error) {
      if (mounted) _toast(t.ark.vtxo.refresh_failed(error: '$error'));
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

  @override
  Widget build(BuildContext context) {
    final colors = context.coconutColors;
    return Consumer<ArkProvider>(
      builder: (context, arkProvider, _) {
        final snapshot = arkProvider.snapshot(widget.id);
        final isOpen = arkProvider.isOpen(widget.id);
        final isBusy = arkProvider.isOpening(widget.id) || arkProvider.isSyncing(widget.id);
        final hasVtxos = snapshot != null && snapshot.vtxos.isNotEmpty;
        return Scaffold(
          backgroundColor: colors.background,
          appBar: CoconutAppBar.build(
            context: context,
            title: _isSelecting ? t.ark.vtxo.select_title : t.ark.vtxo.title,
            backgroundColor: colors.background,
          ),
          body: SafeArea(
            child: Stack(
              children: [
                ValueListenableBuilder<BlockTimestamp?>(
                  valueListenable: context.read<NodeProvider>().currentBlockNotifier,
                  builder: (context, tip, _) {
                    return CustomScrollView(
                      physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                      slivers: [
                        CupertinoSliverRefreshControl(onRefresh: () => arkProvider.syncNow(widget.id)),
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 160),
                          sliver: SliverList(
                            delegate: SliverChildListDelegate([
                              if (!_isSelecting) ...[
                                _buildHeader(snapshot?.balance.total ?? 0),
                                if (!isOpen) ...[
                                  ArkNoticeCard(
                                    title: t.ark.vtxo.locked_title,
                                    description: t.ark.vtxo.locked_description,
                                    iconPath: CommonSecurityIconPath.lock,
                                    actionText: isBusy ? null : t.ark.send.unlock,
                                    onAction: _ensureOpen,
                                  ),
                                  CoconutLayout.spacing_400h,
                                ],
                                if (snapshot != null) ...[
                                  _buildBreakdown(snapshot, tip?.height),
                                  CoconutLayout.spacing_400h,
                                  _buildRecovery(snapshot, canRetry: isOpen && !isBusy && snapshot.canRetryRecovery),
                                  CoconutLayout.spacing_500h,
                                ],
                              ],
                              if (snapshot == null)
                                _buildEmpty(isOpen ? t.ark.vtxo.syncing : t.ark.vtxo.nothing_synced)
                              else
                                _buildVtxoList(snapshot, tip?.height),
                            ]),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                if (hasVtxos && _isSelecting)
                  FixedBottomTweenButton(
                    leftText: t.cancel,
                    rightText: _isRefreshing ? t.ark.vtxo.refreshing : t.ark.vtxo.refresh_n(count: _selectedIds.length),
                    leftButtonClicked: _isRefreshing ? () {} : _stopSelecting,
                    rightButtonClicked: _confirmRefresh,
                    isRightButtonActive: !_isRefreshing && _selectedIds.isNotEmpty,
                  )
                else if (hasVtxos)
                  FixedBottomButton(onButtonClicked: _startSelecting, text: t.ark.vtxo.refresh, isActive: !isBusy),
              ],
            ),
          ),
        );
      },
    );
  }

  /// The Ark balance, like the UTXO list's "Total Balance" header.
  Widget _buildHeader(int total) {
    final colors = context.coconutColors;
    final previous = _shownBalance;
    _shownBalance = total;
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 28, right: 4, bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.ark.vtxo.ark_balance, style: CoconutTypography.body1_16_Bold.setColor(colors.primaryText)),
          CoconutLayout.spacing_100h,
          GestureDetector(
            onTap: _toggleUnit,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                IntrinsicWidth(
                  child: BitcoinAmountUnit(
                    currentUnit: _unit,
                    unitStyle: CoconutTypography.heading4_18_Number.setColor(colors.primaryText),
                    child: Expanded(
                      child: FittedBox(
                        alignment: Alignment.centerLeft,
                        fit: BoxFit.scaleDown,
                        child: AnimatedBalance(
                          prevValue: previous,
                          value: total,
                          currentUnit: _unit,
                          textStyle: CoconutTypography.heading2_28_NumberBold.setColor(colors.primaryText),
                        ),
                      ),
                    ),
                  ),
                ),
                CoconutLayout.spacing_50h,
                FiatPrice(satoshiAmount: total),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBreakdown(ArkSnapshot snapshot, int? tipHeight) {
    final colors = context.coconutColors;
    final earliestExpiry =
        snapshot.vtxos.isEmpty ? null : snapshot.vtxos.map((vtxo) => vtxo.expiryHeight).reduce((a, b) => a < b ? a : b);
    final syncError = _arkProvider.syncError(widget.id);
    return ArkCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (label, sats) in _breakdown(snapshot.balance))
            if (sats != 0 || label == t.ark.vtxo.spendable) ArkInfoRow(label: label, value: formatSats(_unit, sats)),
          CoconutLayout.spacing_200h,
          Divider(color: colors.divider, height: 1),
          CoconutLayout.spacing_200h,
          if (_nextRefreshHeight != null)
            ArkInfoRow(label: t.ark.vtxo.refresh_due, value: _blocks(_nextRefreshHeight!, tipHeight))
          else if (earliestExpiry != null)
            ArkInfoRow(label: t.ark.vtxo.earliest_expiry, value: _blocks(earliestExpiry, tipHeight)),
          if (snapshot.syncedAt != null)
            ArkInfoRow(
              label: t.ark.vtxo.last_synced,
              value: DateTimeUtil.formatTimestamp(snapshot.syncedAt!).join(' '),
            ),
          if (syncError != null) ...[
            CoconutLayout.spacing_200h,
            Text(syncError, style: CoconutTypography.body3_12.setColor(colors.danger)),
          ],
        ],
      ),
    );
  }

  List<(String, int)> _breakdown(ArkBalance balance) => [
    (t.ark.vtxo.spendable, balance.spendable),
    (t.ark.vtxo.pending_in_round, balance.pendingInRound),
    (t.ark.vtxo.pending_board, balance.pendingBoard),
    (t.ark.vtxo.pending_lightning_send, balance.pendingLightningSend),
    (t.ark.vtxo.claimable_lightning_receive, balance.claimableLightningReceive),
    (t.ark.vtxo.pending_exit, balance.pendingExit),
  ];

  Widget _buildRecovery(ArkSnapshot snapshot, {required bool canRetry}) {
    final colors = context.coconutColors;
    final state = switch (snapshot.recovery.state) {
      ArkRecoveryState.notRun => t.ark.vtxo.recovery_not_run,
      ArkRecoveryState.completed => t.ark.vtxo.recovery_completed,
      ArkRecoveryState.failed => t.ark.vtxo.recovery_failed,
    };
    return ArkCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ArkInfoRow(label: t.ark.vtxo.recovery, value: state),
          CoconutLayout.spacing_100h,
          // bark's own report (counts and amounts), as cached.
          Text(snapshot.recovery.description, style: CoconutTypography.body3_12.setColor(colors.secondaryText)),
          if (canRetry) ...[
            CoconutLayout.spacing_300h,
            Align(
              alignment: Alignment.centerLeft,
              child: CoconutUnderlinedButton(
                text: t.ark.vtxo.retry_recovery,
                textStyle: CoconutTypography.body3_12_Bold,
                padding: EdgeInsets.zero,
                onTap: _retryRecovery,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildVtxoList(ArkSnapshot snapshot, int? tipHeight) {
    final vtxos = List<ArkVtxo>.of(snapshot.vtxos)..sort((a, b) => a.expiryHeight.compareTo(b.expiryHeight));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ArkSectionTitle(t.ark.vtxo.list_title(count: vtxos.length)),
        if (vtxos.isEmpty) _buildEmpty(t.ark.vtxo.empty),
        for (final vtxo in vtxos) ...[_buildVtxoCard(vtxo, tipHeight), CoconutLayout.spacing_200h],
      ],
    );
  }

  Widget _buildEmpty(String text) {
    final colors = context.coconutColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 60),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SvgPicture.asset(
            CommonStateIconPath.searchNotFound,
            width: 16,
            colorFilter: ColorFilter.mode(colors.iconSecondary, BlendMode.srcIn),
          ),
          CoconutLayout.spacing_200w,
          Text(text, style: CoconutTypography.body3_12.setColor(colors.secondaryText)),
        ],
      ),
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
            _showVtxoDetails(vtxo, tipHeight);
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

  void _showVtxoDetails(ArkVtxo vtxo, int? tipHeight) {
    final colors = context.coconutColors;
    TextStyle valueStyle() => CoconutTypography.body2_14_Number.setColor(colors.primaryText);
    CommonBottomSheets.showBottomSheet(
      context: context,
      title: t.ark.vtxo.detail_title,
      screenName: '${AppRouteNames.arkWallet}/vtxo',
      showCloseButton: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CopyTextContainer(text: vtxo.id, textStyle: valueStyle()),
            CoconutLayout.spacing_500h,
            UnderlineButtonItemCard(
              label: t.ark.vtxo.amount,
              child: Text(formatSats(_unit, vtxo.amountSats), style: valueStyle()),
            ),
            UnderlineButtonItemCard(
              label: t.ark.vtxo.expiry,
              child: Text(
                '${t.ark.vtxo.at_block(height: vtxo.expiryHeight)} · ${_blocks(vtxo.expiryHeight, tipHeight)}',
                style: valueStyle(),
              ),
            ),
            UnderlineButtonItemCard(
              label: t.ark.vtxo.state,
              child: Text(vtxo.isLocked ? t.ark.vtxo.state_locked : t.ark.vtxo.spendable, style: valueStyle()),
            ),
            UnderlineButtonItemCard(label: t.ark.vtxo.kind, child: Text(vtxo.kind, style: valueStyle())),
            UnderlineButtonItemCard(
              label: t.ark.vtxo.exit_depth,
              showDivider: false,
              child: Text('${vtxo.exitDepth}', style: valueStyle()),
            ),
          ],
        ),
      ),
    );
  }

  static String _blocks(int height, int? tipHeight) {
    if (tipHeight == null) return t.ark.vtxo.at_block(height: height);
    final left = height - tipHeight;
    if (left <= 0) return t.ark.vtxo.expired;
    return t.ark.vtxo.in_blocks(count: left);
  }
}
