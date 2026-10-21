# Local regtest stack

A self-hosted regtest network for developing the bark (Ark) proof of concept.
The Ark server (`captaind`) needs Bitcoin Core RPC on the chain it serves, so
the PoC runs on its own regtest rather than Coconut's hosted one.

`regtest.sh` runs the regtest stack from the [Ark faucet repo](https://gitlab.com/ark-bitcoin/faucet)
with `compose.override.yml` on top, as a separate compose project
(`coconut-regtest`). Clone the faucet repo next to this repo (or its parent
directory), or set `FAUCET_DIR`.

```bash
./contrib/regtest/regtest.sh up -d --build   # first run compiles captaind, CLN and the faucet
./contrib/regtest/regtest.sh fund 5          # fund captaind, the faucet and the watchman
./contrib/regtest/regtest.sh ps              # any other docker compose command
./contrib/regtest/regtest.sh down            # stop (add -v to wipe the chain)
```

A block is mined every 5 seconds.

| Service | Host port | Use |
|---|---|---|
| bitcoind (RPC user `second`, password `ark`) | 18443 | chain, `bitcoin-cli` |
| captaind | 3535 | Ark server (gRPC) |
| electrs (Blockstream) | 50001 / 3002 | Electrum for Coconut / Esplora REST for bark |
| mempool | 8082 | block explorer, mempool API, fee estimates |
| faucet / faucet admin | 8080 / 8081 | test coins |

The override swaps the faucet stack's mempool electrs fork for Blockstream's
electrs built with the `electrum-discovery` feature (`electrs.Dockerfile`),
since Coconut needs `server.features` to check which chain a server is on. The
first build compiles it from source.

## Pointing the app at the stack

In `regtest.env` (`10.0.2.2` is the host machine as seen from the Android emulator):

```env
NETWORK_TYPE=regtest
MEMPOOL_URL=http://10.0.2.2:8082
ELECTRUM_SERVER=tcp://10.0.2.2:50001
# Ark (bark): the Ark server and the Esplora API bark uses as its chain source
ARK_SERVER_URL=http://10.0.2.2:3535
ARK_ESPLORA_URL=http://10.0.2.2:3002
```

Leave `API_HOST` unset: Coconut's hosted faucet pays out on its own chain, not this one.

To send test coins to an address:

```bash
./contrib/regtest/regtest.sh exec -u bitcoin bitcoind bitcoin-cli -regtest sendtoaddress <address> 1
```

To send Ark funds to an Ark address (`tark1…`), use the stack's bark CLI. Fund and board it
once:

```bash
./contrib/regtest/regtest.sh run --rm bark onchain address
./contrib/regtest/regtest.sh exec -u bitcoin bitcoind bitcoin-cli -regtest sendtoaddress <bark address> 0.01
./contrib/regtest/regtest.sh run --rm bark board "500000 sats"
```

Then, a few blocks later (one every 5 seconds):

```bash
./contrib/regtest/regtest.sh run --rm bark send <ark address> "50000 sats"
```

The app's bark logs are in logcat: `adb logcat -s bark`.
