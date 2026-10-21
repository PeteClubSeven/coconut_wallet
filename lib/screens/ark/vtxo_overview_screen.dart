import 'package:coconut_design_system/coconut_design_system.dart' hide CoconutAppBar, CoconutPopup, CoconutToast;
import 'package:coconut_wallet/app/router/app_route_names.dart';
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
import 'package:coconut_wallet/widgets/common/buttons/copy_text_container.dart';
import 'package:coconut_wallet/widgets/common/overlays/common_bottom_sheets.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// The Ark side of a hot wallet: its balance breakdown, recovery status and VTXOs, with
/// delegated refresh. Reads the cache, so it works while the wallet is locked. Strings are not
/// localized yet (proof of concept).
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
  bool _isSelecting = false;
  final Set<String> _selectedIds = {};
  bool _isRefreshing = false;
  int? _nextRefreshHeight;

  @override
  void initState() {
    super.initState();
    _arkProvider = context.read<ArkProvider>();
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
    if (due.isEmpty) _toast('No VTXO needs a refresh yet. Select any to refresh early.');
  }

  Future<void> _confirmRefresh() async {
    final ids = _selectedIds.toList();
    if (ids.isEmpty) return;
    final unit = context.read<PreferenceProvider>().currentUnit;
    setState(() => _isRefreshing = true);
    try {
      final fee = await _arkProvider.estimateRefreshFee(widget.id, ids);
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder:
            (dialogContext) => CoconutPopup(
              languageCode: context.read<PreferenceProvider>().language,
              title: 'Refresh ${ids.length} VTXO${ids.length == 1 ? '' : 's'}?',
              description:
                  'The Ark server moves them into new VTXOs in its next round, without this app having to stay '
                  'open (a delegated refresh). Fee: ${_amount(unit, fee)}.',
              leftButtonText: t.cancel,
              rightButtonText: t.confirm,
              onTapLeft: () => Navigator.pop(dialogContext, false),
              onTapRight: () => Navigator.pop(dialogContext, true),
            ),
      );
      if (confirmed != true || !mounted) return;
      await _arkProvider.refreshDelegated(widget.id, ids);
      if (!mounted) return;
      setState(() {
        _isSelecting = false;
        _selectedIds.clear();
      });
      _toast('Refresh scheduled for the next round');
    } catch (error) {
      if (mounted) _toast('Refresh failed: $error');
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

  static String _amount(BitcoinUnit unit, int sats) =>
      unit.displayBitcoinAmount(sats, withUnit: true, shouldCheckZero: true, defaultWhenZero: '0 ${unit.symbol}');

  @override
  Widget build(BuildContext context) {
    final unit = context.select<PreferenceProvider, BitcoinUnit>((provider) => provider.currentUnit);
    return Consumer<ArkProvider>(
      builder: (context, arkProvider, _) {
        final snapshot = arkProvider.snapshot(widget.id);
        final isOpen = arkProvider.isOpen(widget.id);
        final isBusy = arkProvider.isOpening(widget.id) || arkProvider.isSyncing(widget.id);
        return Scaffold(
          backgroundColor: context.coconutColors.background,
          appBar: CoconutAppBar.build(
            context: context,
            title: _isSelecting ? 'Select VTXOs to refresh' : 'VTXOs',
            backgroundColor: context.coconutColors.background,
          ),
          body: SafeArea(
            child: ValueListenableBuilder<BlockTimestamp?>(
              valueListenable: context.read<NodeProvider>().currentBlockNotifier,
              builder: (context, tip, _) {
                return RefreshIndicator(
                  onRefresh: () => arkProvider.syncNow(widget.id),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                    children: [
                      if (!isOpen) _buildLockedBanner(isBusy),
                      if (snapshot == null)
                        _muted(isOpen ? 'Syncing…' : 'Nothing synced yet.')
                      else ...[
                        if (!_isSelecting) ...[
                          _buildSummary(snapshot, unit, tip?.height),
                          CoconutLayout.spacing_500h,
                          _buildRecovery(snapshot, canRetry: isOpen && !isBusy && snapshot.canRetryRecovery),
                          CoconutLayout.spacing_500h,
                        ],
                        _buildVtxoList(snapshot, unit, tip?.height),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
          bottomNavigationBar: snapshot == null || snapshot.vtxos.isEmpty ? null : _buildBottomBar(isBusy),
        );
      },
    );
  }

  Widget _buildLockedBanner(bool isBusy) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _muted('Locked: showing the last synced data. Unlock to sync and refresh.'),
          CoconutLayout.spacing_200h,
          _button('Unlock', isBusy ? null : _ensureOpen),
        ],
      ),
    );
  }

  Widget _buildSummary(ArkSnapshot snapshot, BitcoinUnit unit, int? tipHeight) {
    final balance = snapshot.balance;
    final earliestExpiry =
        snapshot.vtxos.isEmpty ? null : snapshot.vtxos.map((vtxo) => vtxo.expiryHeight).reduce((a, b) => a < b ? a : b);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: context.coconutColors.surface,
        borderRadius: BorderRadius.circular(CoconutStyles.radius_400),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('Ark balance'),
          Text(
            _amount(unit, balance.total),
            style: CoconutTypography.heading3_21_NumberBold.setColor(context.coconutColors.primaryText),
          ),
          CoconutLayout.spacing_300h,
          ..._breakdown(balance).map((entry) => _row(entry.$1, _amount(unit, entry.$2))),
          CoconutLayout.spacing_300h,
          if (_nextRefreshHeight != null)
            _row('Refresh due', _blocks(_nextRefreshHeight!, tipHeight))
          else if (earliestExpiry != null)
            _row('Earliest expiry', _blocks(earliestExpiry, tipHeight)),
          if (snapshot.syncedAt != null) _row('Last synced', _time(snapshot.syncedAt!)),
          if (_arkProvider.syncError(widget.id) != null) ...[
            CoconutLayout.spacing_200h,
            Text(
              _arkProvider.syncError(widget.id)!,
              style: CoconutTypography.body3_12.setColor(context.coconutColors.danger),
            ),
          ],
        ],
      ),
    );
  }

  List<(String, int)> _breakdown(ArkBalance balance) => [
    ('Spendable', balance.spendable),
    ('Pending in round', balance.pendingInRound),
    ('Pending board', balance.pendingBoard),
    ('Pending Lightning send', balance.pendingLightningSend),
    ('Claimable Lightning receive', balance.claimableLightningReceive),
    ('Pending exit', balance.pendingExit),
  ];

  Widget _buildRecovery(ArkSnapshot snapshot, {required bool canRetry}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _label('Recovery'),
        _muted(snapshot.recovery.description),
        if (canRetry) ...[CoconutLayout.spacing_200h, _button('Retry recovery', _retryRecovery)],
      ],
    );
  }

  Widget _buildVtxoList(ArkSnapshot snapshot, BitcoinUnit unit, int? tipHeight) {
    final vtxos = List<ArkVtxo>.of(snapshot.vtxos)..sort((a, b) => a.expiryHeight.compareTo(b.expiryHeight));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _label('VTXO · ${vtxos.length}'),
        if (vtxos.isEmpty) _muted('No VTXOs.'),
        for (final vtxo in vtxos) _buildVtxoRow(vtxo, unit, tipHeight),
      ],
    );
  }

  Widget _buildVtxoRow(ArkVtxo vtxo, BitcoinUnit unit, int? tipHeight) {
    final isSelected = _selectedIds.contains(vtxo.id);
    final colors = context.coconutColors;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: colors.surface,
        borderRadius: BorderRadius.circular(CoconutStyles.radius_300),
        child: InkWell(
          borderRadius: BorderRadius.circular(CoconutStyles.radius_300),
          onTap:
              _isSelecting
                  ? (vtxo.isLocked
                      ? null
                      : () => setState(() => isSelected ? _selectedIds.remove(vtxo.id) : _selectedIds.add(vtxo.id)))
                  : () => _showVtxoDetails(vtxo, unit, tipHeight),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                if (_isSelecting) ...[
                  Icon(
                    isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
                    size: 20,
                    color: vtxo.isLocked ? colors.iconDisabled : colors.iconPrimary,
                  ),
                  CoconutLayout.spacing_300w,
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _amount(unit, vtxo.amountSats),
                        style: CoconutTypography.body1_16_Number.setColor(colors.primaryText),
                      ),
                      Text(
                        'Expires ${_blocks(vtxo.expiryHeight, tipHeight)}',
                        style: CoconutTypography.body3_12.setColor(colors.secondaryText),
                      ),
                    ],
                  ),
                ),
                _badge(vtxo.isLocked ? 'Locked' : 'Spendable', highlighted: !vtxo.isLocked),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget? _buildBottomBar(bool isBusy) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child:
            _isSelecting
                ? Row(
                  children: [
                    Expanded(
                      child: _button(
                        t.cancel,
                        _isRefreshing
                            ? null
                            : () => setState(() {
                              _isSelecting = false;
                              _selectedIds.clear();
                            }),
                      ),
                    ),
                    CoconutLayout.spacing_300w,
                    Expanded(
                      child: _button(
                        _isRefreshing ? 'Refreshing…' : 'Refresh ${_selectedIds.length}',
                        _isRefreshing || _selectedIds.isEmpty ? null : _confirmRefresh,
                      ),
                    ),
                  ],
                )
                : _button('Refresh VTXOs', isBusy ? null : _startSelecting),
      ),
    );
  }

  void _showVtxoDetails(ArkVtxo vtxo, BitcoinUnit unit, int? tipHeight) {
    CommonBottomSheets.showBottomSheet(
      context: context,
      title: 'VTXO',
      screenName: '${AppRouteNames.arkWallet}/vtxo',
      showCloseButton: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CopyTextContainer(text: vtxo.id),
            CoconutLayout.spacing_300h,
            _row('Amount', _amount(unit, vtxo.amountSats)),
            _row('Expiry', 'block ${vtxo.expiryHeight} (${_blocks(vtxo.expiryHeight, tipHeight)})'),
            _row('State', vtxo.isLocked ? 'Locked by an operation in progress' : 'Spendable'),
            _row('Kind', vtxo.kind),
            _row('Exit depth', '${vtxo.exitDepth}'),
          ],
        ),
      ),
    );
  }

  static String _blocks(int height, int? tipHeight) {
    if (tipHeight == null) return 'at block $height';
    final left = height - tipHeight;
    if (left <= 0) return 'expired (block $height)';
    return 'in $left blocks';
  }

  static String _time(DateTime time) {
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(text, style: CoconutTypography.body2_14_Bold.setColor(context.coconutColors.primaryText)),
  );

  Widget _muted(String text) =>
      Text(text, style: CoconutTypography.body2_14.setColor(context.coconutColors.secondaryText));

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Expanded(child: Text(label, style: CoconutTypography.body3_12.setColor(context.coconutColors.secondaryText))),
        Text(value, style: CoconutTypography.body3_12_Number.setColor(context.coconutColors.primaryText)),
      ],
    ),
  );

  Widget _badge(String text, {required bool highlighted}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: highlighted ? context.coconutColors.surfaceMuted : Colors.transparent,
      border: Border.all(color: context.coconutColors.surfaceMuted),
      borderRadius: BorderRadius.circular(CoconutStyles.radius_100),
    ),
    child: Text(text, style: CoconutTypography.caption_10.setColor(context.coconutColors.secondaryText)),
  );

  Widget _button(String text, VoidCallback? onPressed) => CoconutButton(
    text: text,
    isActive: onPressed != null,
    onPressed: onPressed ?? () {},
    height: 48,
    backgroundColor: context.coconutColors.surfaceButton,
    foregroundColor: context.coconutColors.surfaceButtonText,
  );
}
