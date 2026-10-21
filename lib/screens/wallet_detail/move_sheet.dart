import 'package:coconut_design_system/coconut_design_system.dart';
import 'package:coconut_wallet/constants/icon_path.dart';
import 'package:coconut_wallet/design_system/context/coconut_theme_context_extension.dart';
import 'package:coconut_wallet/enums/fiat_enums.dart';
import 'package:coconut_wallet/localization/strings.g.dart';
import 'package:coconut_wallet/model/ark/move.dart';
import 'package:coconut_wallet/providers/wallet_provider.dart';
import 'package:coconut_wallet/screens/home/wallet_add/wallet_add_dialog.dart';
import 'package:coconut_wallet/utils/dashed_border_painter.dart';
import 'package:coconut_wallet/widgets/common/buttons/fixed_bottom_button.dart';
import 'package:coconut_wallet/widgets/common/buttons/shrink_animation_button.dart';
import 'package:coconut_wallet/widgets/features/ark/ark_texts.dart';
import 'package:coconut_wallet/widgets/features/wallet/icon/wallet_icon_small.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

/// Picks where to move funds, in two steps in the style of the vault sheet: first where from,
/// then where to, each a list of wallet cards with a radio mark. Without a vault, step two offers
/// to create one. Pops with a [MoveSelection].
class MoveSheet extends StatefulWidget {
  const MoveSheet({super.key, required this.options, required this.currentUnit, this.scrollController});

  final MoveOptions options;
  final BitcoinUnit currentUnit;
  final ScrollController? scrollController;

  @override
  State<MoveSheet> createState() => _MoveSheetState();
}

class _MoveSheetState extends State<MoveSheet> {
  MoveEndpoint? _from;
  MoveEndpoint? _to;
  bool _isPickingDestination = false;

  @override
  void initState() {
    super.initState();
    final options = widget.options;
    _from = options.all.where(options.canMoveFrom).firstOrNull;
  }

  void _next() {
    final from = _from;
    if (from == null) return;
    if (!_isPickingDestination) {
      final destinations = widget.options.destinationsFor(from);
      setState(() {
        _isPickingDestination = true;
        if (!destinations.contains(_to)) _to = destinations.firstOrNull;
      });
      return;
    }
    if (_to != null) Navigator.pop(context, MoveSelection(from, _to!));
  }

  /// Closes the sheet and opens the watch-only wallet sources, as the vault sheet does.
  Future<void> _createVault() async {
    final navigator = Navigator.of(context);
    final sheetRoute = ModalRoute.of(context);
    navigator.pop();
    await sheetRoute?.completed;
    if (!navigator.mounted) return;
    WalletAddDialog.showBottomSheet(navigator.context, WalletAddDialogMode.watchOnlySource);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.coconutColors;
    final options = widget.options;
    final from = _from;
    final List<Widget> cards;
    if (_isPickingDestination && from != null) {
      cards = [
        for (final endpoint in options.destinationsFor(from))
          _endpointCard(
            endpoint,
            selected: endpoint == _to,
            enabled: true,
            onTap: () => setState(() => _to = endpoint),
          ),
        if (options.vaults.isEmpty) _buildCreateVault(),
      ];
    } else {
      cards = [
        for (final endpoint in options.all)
          _endpointCard(
            endpoint,
            selected: endpoint == from,
            enabled: options.canMoveFrom(endpoint),
            onTap: () => setState(() => _from = endpoint),
          ),
      ];
    }
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildHeader(),
          Flexible(
            child: SingleChildScrollView(
              controller: widget.scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [for (final card in cards) Padding(padding: const EdgeInsets.only(bottom: 12), child: card)],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: InlineActionButton(
              text: t.next,
              isActive: from != null && (!_isPickingDestination || _to != null),
              backgroundColor: colors.primary,
              onPressed: _next,
            ),
          ),
        ],
      ),
    );
  }

  /// The vault sheet's header: the step's title, with close (or back, on step two) on the left.
  Widget _buildHeader() {
    final colors = context.coconutColors;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              _isPickingDestination ? t.ark.move.to_title : t.ark.move.from_title,
              style: CoconutTypography.body2_14_Bold.setColor(colors.primaryText),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (_isPickingDestination) {
                  setState(() => _isPickingDestination = false);
                } else {
                  Navigator.pop(context);
                }
              },
              child:
                  _isPickingDestination
                      ? SvgPicture.asset(
                        CommonNavigationIconPath.arrowBack,
                        width: 24,
                        colorFilter: ColorFilter.mode(colors.iconPrimary, BlendMode.srcIn),
                      )
                      : Icon(Icons.close_rounded, size: 24, color: colors.iconPrimary),
            ),
          ),
        ],
      ),
    );
  }

  /// A wallet card as the vault sheet lists them (icon, balance, name), with a radio mark where
  /// that sheet has an arrow. The Ark side wears the boat as its badge.
  Widget _endpointCard(
    MoveEndpoint endpoint, {
    required bool selected,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final colors = context.coconutColors;
    final wallet = context.read<WalletProvider>().getWalletById(endpoint.walletId);
    return AnimatedOpacity(
      opacity: enabled ? 1 : 0.4,
      duration: const Duration(milliseconds: 150),
      child: ShrinkAnimationButton(
        onPressed: enabled ? onTap : () {},
        defaultColor: colors.homeSurface,
        pressedOverlayColor: colors.homeSurfacePressOverlay,
        pressedOverlayOpacity: colors.homeSurfacePressOverlayOpacity,
        borderRadius: 12,
        borderWidth: 0,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          child: Row(
            children: [
              WalletIconSmall(
                walletImportSource: wallet.walletImportSource,
                iconIndex: wallet.iconIndex,
                colorIndex: wallet.colorIndex,
                isHotWallet: wallet.hasLocalKey,
                badgeSvgAssetPath: endpoint.kind == MoveEndpointKind.ark ? FeatureArkIconPath.boat : null,
                badgeBorderColor: colors.homeSurface,
              ),
              CoconutLayout.spacing_200w,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        widget.currentUnit.displayBitcoinAmount(endpoint.balanceSats, withUnit: true),
                        style: CoconutTypography.body2_14_NumberBold.setColor(colors.primaryText),
                      ),
                    ),
                    Text(moveEndpointText(endpoint), style: CoconutTypography.body3_12.setColor(colors.secondaryText)),
                  ],
                ),
              ),
              CoconutLayout.spacing_200w,
              SvgPicture.asset(
                selected ? CommonFormIconPath.circleCheck : CommonFormIconPath.circle,
                width: 20,
                height: 20,
                colorFilter: ColorFilter.mode(selected ? colors.primaryText : colors.iconSecondary, BlendMode.srcIn),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// No vault yet: the dashed "add a wallet" card, opening the watch-only wallet sources.
  Widget _buildCreateVault() {
    final colors = context.coconutColors;
    return ShrinkAnimationButton(
      onPressed: _createVault,
      defaultColor: colors.homeSurface,
      pressedOverlayColor: colors.homeSurfacePressOverlay,
      pressedOverlayOpacity: colors.homeSurfacePressOverlayOpacity,
      borderRadius: 12,
      borderWidth: 0,
      child: CustomPaint(
        painter: DashedBorderPainter(dashSpace: 4.0, dashWidth: 4.0, color: colors.border),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          child: Row(
            children: [
              SvgPicture.asset(
                FeatureWalletIconPath.walletEyes,
                width: 30,
                colorFilter: ColorFilter.mode(colors.iconSecondary, BlendMode.srcIn),
              ),
              CoconutLayout.spacing_200w,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.ark.move.create_vault, style: CoconutTypography.body2_14_Bold.setColor(colors.primaryText)),
                    Text(
                      t.ark.move.create_vault_description,
                      style: CoconutTypography.body3_12.setColor(colors.secondaryText),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
