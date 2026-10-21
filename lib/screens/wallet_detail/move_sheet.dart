import 'package:coconut_design_system/coconut_design_system.dart';
import 'package:coconut_lib/coconut_lib.dart';
import 'package:coconut_wallet/design_system/context/coconut_theme_context_extension.dart';
import 'package:coconut_wallet/enums/fiat_enums.dart';
import 'package:coconut_wallet/localization/strings.g.dart';
import 'package:coconut_wallet/model/wallet/wallet_item_base.dart';
import 'package:coconut_wallet/widgets/common/buttons/fixed_bottom_button.dart';
import 'package:coconut_wallet/widgets/common/overlays/common_bottom_sheets.dart';
import 'package:coconut_wallet/widgets/features/ark/ark_texts.dart';
import 'package:flutter/material.dart';

enum MoveEndpointKind { onchain, ark, vault }

/// One place funds can move from or to: this hot wallet's on-chain balance, its Ark balance, or
/// a vault (a watch-only wallet signed with Coconut Vault).
class MoveEndpoint {
  const MoveEndpoint({required this.kind, required this.walletId, required this.walletName, required this.balanceSats});

  final MoveEndpointKind kind;
  final int walletId;
  final String walletName;
  final int balanceSats;

  @override
  bool operator ==(Object other) => other is MoveEndpoint && other.kind == kind && other.walletId == walletId;

  @override
  int get hashCode => Object.hash(kind, walletId);
}

class MoveSelection {
  const MoveSelection(this.from, this.to);

  final MoveEndpoint from;
  final MoveEndpoint to;
}

/// The places [hotWallet] can move funds between. One end of a move is always the hot wallet
/// (its on-chain or Ark side): vault-to-vault moves stay in the vault's own Send.
class MoveOptions {
  MoveOptions({
    required WalletItemBase hotWallet,
    required int onchainBalanceSats,
    required int? arkBalanceSats,
    required List<({WalletItemBase wallet, int balanceSats})> vaults,
  }) : onchain = MoveEndpoint(
         kind: MoveEndpointKind.onchain,
         walletId: hotWallet.id,
         walletName: hotWallet.name,
         balanceSats: onchainBalanceSats,
       ),
       ark =
           arkBalanceSats == null
               ? null
               : MoveEndpoint(
                 kind: MoveEndpointKind.ark,
                 walletId: hotWallet.id,
                 walletName: hotWallet.name,
                 balanceSats: arkBalanceSats,
               ),
       vaults = [
         for (final vault in vaults)
           MoveEndpoint(
             kind: MoveEndpointKind.vault,
             walletId: vault.wallet.id,
             walletName: vault.wallet.name,
             balanceSats: vault.balanceSats,
           ),
       ],
       _boardableVaultIds = {
         for (final vault in vaults)
           if (_hasNativeSegwitInputs(vault.wallet)) vault.wallet.id,
       };

  final MoveEndpoint onchain;
  final MoveEndpoint? ark;
  final List<MoveEndpoint> vaults;
  final Set<int> _boardableVaultIds;

  List<MoveEndpoint> get all => [onchain, if (ark != null) ark!, ...vaults];

  /// Whether there is anywhere to move between at all.
  bool get hasChoices => ark != null || vaults.isNotEmpty;

  /// Where funds from [from] can go.
  List<MoveEndpoint> destinationsFor(MoveEndpoint from) => switch (from.kind) {
    MoveEndpointKind.onchain => [if (ark != null) ark!, ...vaults],
    MoveEndpointKind.ark => [onchain, ...vaults],
    MoveEndpointKind.vault => [
      onchain,
      // bark only boards from native segwit inputs: a nested-segwit input's txid changes once signed.
      if (ark != null && _boardableVaultIds.contains(from.walletId)) ark!,
    ],
  };

  bool canMoveFrom(MoveEndpoint from) => from.balanceSats > 0 && destinationsFor(from).isNotEmpty;

  static bool _hasNativeSegwitInputs(WalletItemBase wallet) {
    final name = wallet.walletBase.addressType.name;
    return name == AddressType.p2wpkh.name || name == AddressType.p2wsh.name || name == AddressType.p2tr.name;
  }
}

/// Picks where to move funds from and to. Pops with a [MoveSelection].
class MoveSheet extends StatefulWidget {
  const MoveSheet({super.key, required this.options, required this.currentUnit});

  final MoveOptions options;
  final BitcoinUnit currentUnit;

  @override
  State<MoveSheet> createState() => _MoveSheetState();
}

class _MoveSheetState extends State<MoveSheet> {
  MoveEndpoint? _from;
  MoveEndpoint? _to;

  @override
  void initState() {
    super.initState();
    final options = widget.options;
    _from = options.all.where(options.canMoveFrom).firstOrNull;
    _to = _from == null ? null : options.destinationsFor(_from!).firstOrNull;
  }

  void _selectFrom(MoveEndpoint from) {
    setState(() {
      _from = from;
      final destinations = widget.options.destinationsFor(from);
      if (!destinations.contains(_to)) _to = destinations.firstOrNull;
    });
  }

  @override
  Widget build(BuildContext context) {
    final options = widget.options;
    final from = _from;
    final destinations = from == null ? const <MoveEndpoint>[] : options.destinationsFor(from);
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _sectionTitle(t.ark.move.from),
            for (final endpoint in options.all)
              _option(
                endpoint,
                selected: endpoint == from,
                enabled: options.canMoveFrom(endpoint),
                onTap: () => _selectFrom(endpoint),
              ),
            CoconutLayout.spacing_400h,
            _sectionTitle(t.ark.move.to),
            for (final endpoint in options.all)
              if (endpoint != from)
                _option(
                  endpoint,
                  selected: endpoint == _to,
                  enabled: destinations.contains(endpoint),
                  onTap: () => setState(() => _to = endpoint),
                ),
            CoconutLayout.spacing_500h,
            InlineActionButton(
              text: t.next,
              isActive: from != null && _to != null,
              onPressed: () {
                if (from == null || _to == null) return;
                Navigator.pop(context, MoveSelection(from, _to!));
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 4),
    child: Text(text, style: CoconutTypography.body2_14_Bold.setColor(context.coconutColors.primaryText)),
  );

  /// A row of Coconut's selectable sheets: the place and its balance, with a check when picked.
  Widget _option(MoveEndpoint endpoint, {required bool selected, required bool enabled, required VoidCallback onTap}) {
    final colors = context.coconutColors;
    return SelectableBottomSheetTextItem(
      isSelected: selected,
      isDisabled: !enabled,
      reserveCheckIconSpace: true,
      onTap: onTap,
      child: Row(
        children: [
          Expanded(
            child: Text(
              moveEndpointText(endpoint),
              style: CoconutTypography.body2_14_Bold.setColor(colors.primaryText),
            ),
          ),
          Text(
            widget.currentUnit.displayBitcoinAmount(endpoint.balanceSats, withUnit: true),
            style: CoconutTypography.body3_12_Number.setColor(colors.secondaryText),
          ),
        ],
      ),
    );
  }
}
