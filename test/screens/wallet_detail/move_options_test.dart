import 'package:coconut_lib/coconut_lib.dart';
import 'package:coconut_wallet/model/wallet/singlesig_wallet_item.dart';
import 'package:coconut_wallet/screens/wallet_detail/move_sheet.dart';
import 'package:flutter_test/flutter_test.dart';

const _descriptor =
    "wpkh([D45AA182/84'/1'/0']vpub5YtEovN9MqeUZxWqdpUKngsiaLCPFY34KpWGQVk9Tjq8G5SYcRFj9s5aCKeAQYGunG7LrFkA5obtH8kPJiv92JtWHfRvnir6PDvhd4p93Pp/<0;1>/*)#rcn2hj6y";

SinglesigWalletItem _wallet(int id, String name) =>
    SinglesigWalletItem(id: id, name: name, colorIndex: 0, iconIndex: 0, descriptor: _descriptor);

void main() {
  setUpAll(() => NetworkType.setNetworkType(NetworkType.regtest));

  final hot = _wallet(1, 'Hot');
  final vault = _wallet(2, 'Vault');

  List<MoveEndpointKind> kinds(List<MoveEndpoint> endpoints) => endpoints.map((e) => e.kind).toList();

  test('with Ark and a vault, every pair touching the hot wallet is offered', () {
    final options = MoveOptions(
      hotWallet: hot,
      onchainBalanceSats: 100000,
      arkBalanceSats: 50000,
      vaults: [(wallet: vault, balanceSats: 70000)],
    );

    expect(options.hasChoices, isTrue);
    expect(kinds(options.destinationsFor(options.onchain)), [MoveEndpointKind.ark, MoveEndpointKind.vault]);
    expect(kinds(options.destinationsFor(options.ark!)), [MoveEndpointKind.onchain, MoveEndpointKind.vault]);
    expect(kinds(options.destinationsFor(options.vaults.single)), [MoveEndpointKind.onchain, MoveEndpointKind.ark]);
  });

  test('empty sources can\'t be moved from', () {
    final options = MoveOptions(
      hotWallet: hot,
      onchainBalanceSats: 100000,
      arkBalanceSats: 0,
      vaults: [(wallet: vault, balanceSats: 0)],
    );

    expect(options.canMoveFrom(options.onchain), isTrue);
    expect(options.canMoveFrom(options.ark!), isFalse);
    expect(options.canMoveFrom(options.vaults.single), isFalse);
  });

  test('without Ark it is on-chain to and from vaults', () {
    final options = MoveOptions(
      hotWallet: hot,
      onchainBalanceSats: 100000,
      arkBalanceSats: null,
      vaults: [(wallet: vault, balanceSats: 70000)],
    );

    expect(options.ark, isNull);
    expect(kinds(options.destinationsFor(options.onchain)), [MoveEndpointKind.vault]);
    expect(kinds(options.destinationsFor(options.vaults.single)), [MoveEndpointKind.onchain]);
  });

  test('without Ark or vaults there is nothing to choose', () {
    final options = MoveOptions(hotWallet: hot, onchainBalanceSats: 100000, arkBalanceSats: null, vaults: const []);

    expect(options.hasChoices, isFalse);
    expect(options.canMoveFrom(options.onchain), isFalse);
  });
}
