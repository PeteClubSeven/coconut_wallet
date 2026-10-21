# Bark integration notes (proof of concept)

Notes from adding a bark (Ark) wallet to Coconut Wallet's hot wallets, kept as feedback on how
easy bark is to integrate. Covers milestone 1: an Ark wallet created and restored together with
the hot wallet, plus a minimal Ark screen (status, recovery result, balance, Ark address).

## Setup

- **SDK:** `bark_bitcoin 0.25.0+bark-0.7.1` (pub.dev), Second's Dart bindings, generated with
  `uniffi-dart` from `bark-ffi`. Matches the bark 0.7.1 Ark server in `contrib/regtest`.
- **Chain:** a self-hosted regtest stack (`contrib/regtest`). The Ark server (captaind) needs
  Bitcoin Core RPC on the chain it serves, which Coconut's hosted regtest doesn't offer.
- **App config:** `ARK_SERVER_URL` and `ARK_ESPLORA_URL` in `regtest.env`. Ark is off when
  `ARK_SERVER_URL` is unset.

## How it fits Coconut

- **Keys:** bark derives everything under `m/350'` from the 64-byte BIP39 seed; Coconut hot
  wallets are BIP84. The app passes `Seed.fromMnemonic(mnemonic, passphrase).rootSeed` as hex to
  `Wallet.open(mnemonicOrSeed:)`, so passphrase wallets work.
- **Identity:** an Ark wallet is keyed by the hot wallet's master fingerprint (seed +
  passphrase), not Coconut's row id. Data lives in `<app support>/bark/<fingerprint>/`.
- **Lifecycle:** `WalletProvider` creates the Ark wallet inside the hot wallet's create/restore
  operation, before the wallet becomes `active`. Any failure rolls back the Realm row, the secret
  and the Ark data. Deletion, hot→watch-only conversion, startup reconciliation and the
  forgot-PIN reset all remove Ark data.
- **Offline creation:** creation uses `createWithoutServer: true`, so adding a hot wallet doesn't
  depend on the Ark server. On restore, bark's seed recovery runs in the same open when the
  server is reachable. If it wasn't, the Ark screen offers "Retry recovery" (recreates the
  still-unused wallet).
- **On-chain wallet:** bark runs with `onchain: null`. Moving funds between the two wallets is
  milestone 2 (board via `boardFundingAddress` + a Coconut-signed PSBT + `boardPsbt`; offboard
  to a Coconut address).
- **Unlocking:** bark keeps the seed for as long as a wallet is open. After an app restart the
  Ark screen unlocks the hot wallet (authentication, plus the passphrase for "enter passphrase
  when signing" wallets) and opens the Ark wallet for the rest of the session.

## Pain points

### Toolchain and build

1. **Flutter/Dart floor.** `bark_bitcoin` requires Dart ≥ 3.10 (Flutter ≥ 3.38). It loads its
   library through build hooks: 341 `@Native(assetId: …)` declarations plus `hook/build.dart`.
   Flutter 3.35 has native assets disabled on the stable channel
   (`flutter_tools/lib/src/features.dart`), so apps on older Flutter can't adopt it without a
   toolchain upgrade. Coconut was on 3.35.7.
   - The bindings themselves are plain `dart:ffi`; the floor comes from the loading mechanism.
     `hooks` 1.0.0–1.0.1 and `native_toolchain_rust` allow Dart 3.9.
   - Suggestion: a second loading mode with prebuilt per-platform libraries and
     `DynamicLibrary.open`, as Flutter plugins traditionally ship.
   - For Coconut, upgrading to 3.38.10 needed nothing beyond `.fvmrc`.
2. **Every build compiles Rust.** Native Assets builds bark-ffi from source in every consuming
   app, so every developer and CI machine needs rustup, the pinned toolchain (1.90.0) and the
   target triples.
   - First Android arm64 build: about 7.5 minutes.
   - **Unit tests too:** `flutter test` builds the library for the host (`aarch64-apple-darwin`)
     even though no test imports bark. The first test run went from seconds to about 7 minutes.
   - Adds about 12.9 MB per ABI to the APK (`libbark_ffi_dart.so`, 16 MB unpacked).
   - Suggestion: prebuilt binaries, downloaded by the hook, with source build as a fallback.
3. **Version lockstep.** The package version pins the bark version, which has to match the
   server's protocol. Upgrades bring breaking API changes (Alby Hub history: `WalletCreate` →
   `WalletOpen` at 0.12.1, a forced protocol bump at 0.15.0).

### Chain and fees

4. **No Electrum chain source.** bark supports Esplora or bitcoind only, while many wallets run
   on Electrum (Coconut does). Coconut now talks to Electrum for its own wallets and bark needs a
   separate Esplora endpoint for the same chain. There's an unmerged, stale Electrum branch.
5. **Fees come from the chain source.** bark uses Esplora `/fee-estimates` (or bitcoind).
   Wallets commonly use mempool's `/api/v1/fees/recommended`, and mempool's `/api` lacks
   `/fee-estimates`, so a mempool instance can't stand in for Esplora. On regtest, Esplora
   returns `{}` and bark falls back to its configured rate.

### On-chain wallet integration

6. **Custom on-chain wallet: CPFP is the blocker.** `CustomOnchainWalletCallbacks` asks the host
   for `makeSignedP2aCpfp`: a version-3 (TRUC) transaction spending the 0-value P2A anchor at a
   computed package fee. Typical wallet libraries (Coconut's coconut_lib) can't build that.
   - **Proposed fix:** a PSBT flow. bark already accepts host-built children
     (`exits_needing_cpfp()` + `provide_cpfp_tx()`). A `prepare_cpfp_psbt(exit, host_utxos,
     change_address)` that selects from host-described UTXOs and builds the transaction (version,
     P2A input, package fee) would leave the host only signing its own inputs, like `boardPsbt`.
7. **Callbacks are synchronous and thread-bound.** bark's `OnchainWalletTrait` is async, but
   bark-ffi exports the foreign trait as plain `fn`
   (`bark-ffi src/muniffi/custom_onchain_wallet.rs:24`). In Dart they become sync methods
   (`int getBalance()`, `String prepareTx(...)`).
   - That doesn't fit wallets whose coin selection, unlock and signing are async and may prompt
     the user.
   - The Dart bindings create every callback (logger and custom on-chain wallet) with
     `Pointer.fromFunction`. Dart only allows those to run on the isolate's own thread, and
     bark-ffi calls them from whichever thread is working, usually a tokio worker.
   - Question for the maintainers: is the sync choice a generator limitation (uniffi-dart, Go)?
     Could async foreign methods, or `NativeCallable.listener`-style delivery, be offered?
8. **The SDK's logger crashes the app.** Confirmed in a host test: `barkAttachPrintLogger()`
   (which the package recommends for development) followed by `Wallet.open` aborts the process
   with SIGABRT on the first record. Stack: `bark_ffi::muniffi::db::open_sqlite_db` →
   `log` → `UniFFICallbackHandlerBarkLogger::log` → Dart's `DLRT_GetFfiCallbackMetadata`
   assertion, on a tokio worker thread. Without a logger, bark is silent, which makes
   debugging impossible.
   - Coconut's workaround: `bark_bitcoin` is vendored (`third_party/bark_bitcoin`) with a
     Rust-side `log::Log` that writes to Android logcat (tag `bark`), installed when the library
     loads. See `third_party/bark_bitcoin/COCONUT_PATCH.md`.
   - Suggestions: deliver log records to Dart with `NativeCallable.listener` (async, any
     thread), and/or have bark-ffi offer a built-in platform logger (logcat, os_log, stderr,
     file) that needs no foreign callback.

### Keys, custody and recovery

9. **Passphrases.** bark's mnemonic path assumes an empty passphrase; callers must pass the
   seed as hex instead. bark-cli/barkd can't restore a passphrase wallet.
10. **Custody model.** bark needs the seed in memory for the whole session (rounds, refresh,
   mailbox). Coconut otherwise unlocks secrets only per signature, behind authentication, so Ark
   wallets are opened explicitly from the Ark screen after an unlock.
11. **Recovery is server-trusted and partial.** Without the database, history and in-flight
    Lightning receives are lost, and recovery depends on the server returning the VTXOs.
12. **No "run recovery again".** Recovery runs only on the open that creates the database. If
    the server was unreachable at restore time, the only retry is deleting and recreating the
    (still unused) wallet. Confirmed: after a restore with captaind down, the daemon reconnected
    once captaind was back but the balance stayed at 0 until Coconut's "Retry recovery".

### Mobile lifecycle

13. **The app has to be online.** Rounds, refresh before expiry, Lightning claims and board
    registration need the app running. The daemon (`runDaemon`) suits a desktop process better
    than a backgrounded mobile app.

### Observed at runtime (bark 0.7.1, bark-ffi 0.29.0)

14. **Misleading open-time warning.** Right after `bark::Wallet::open`, bark-ffi checks
    `ark_info()` and logs `[OPEN] Server connection FAILED - Lightning and Ark operations will not
    work!` if it isn't there yet (`src/core/wallet.rs:213`). Existing wallets and wallets created
    with `createWithoutServer` connect lazily through the daemon, so this fires on almost every
    open even though the daemon connects a moment later. The underlying error is discarded
    (`.ok()`), so a real failure would look the same.
15. **Esplora keep-alive failures.** electrs's Esplora server closes idle keep-alive connections
    after 10–35 s without advertising it. bark's Esplora client (reqwest) reuses the dead pooled
    connection and fails with `hyper::Error(IncompleteMessage)` on `GET /blocks/tip/height`,
    with no retry, so roughly every other maintenance refresh fails ("Failed to join round for
    maintenance refresh"). Suggestion: a pool idle timeout shorter than common server
    keep-alives, or retrying idempotent GETs.
16. **`stopDaemon()` returns before the daemon stops.** Deleting the datadir right after it led
    to one more round event failing with "unable to open database" before the daemon logged its
    shutdown. Harmless here, but callers can't tell when it's safe to remove a wallet's files.
17. **New databases replay every migration.** Creating a wallet runs 42 SQLite migrations one
    by one: 1.2 s on the emulator normally, about 10 s under load. A schema snapshot for fresh
    databases would make wallet creation (which Coconut does inside the hot wallet's create
    flow) cheaper.
18. **Fee fallback log units.** On regtest the fallback is logged as `falling back to 0.00001
    sat/kvB`, which looks like a BTC/kvB value with a sat/kvB label.

### Test environment

19. **Electrum servers.** Coconut needs Electrum `server.features`. mempool's electrs fork lacks
    it; Blockstream electrs needs the `electrum-discovery` build feature plus
    `--electrum-public-hosts` at runtime.

## Verification results

On the Pixel 10 emulator (Android 37.2, 16 KB pages) against `contrib/regtest`, 2026-10-19:

| Scenario | Result |
|---|---|
| Create a hot wallet | Ark wallet created inside the same operation (`bark/<fingerprint>/db.sqlite`); about 3 s from tap to Ark wallet, of which bark took 1.2 s |
| Receive over Ark | 50,000 and 30,000 sats sent from the stack's bark CLI arrived through the mailbox; the receiving wallet posted the VTXO id to the recovery mailbox |
| Delete the hot wallet | Ark datadir removed; the delete flow asks "Have you backed up your mnemonic?" when the Ark wallet holds funds or is locked |
| Restore from the mnemonic | `Seed recovery finished: 1 recovered (30000 sats) … complete=true`; the Ark screen shows 30,000 sats |
| Restore with captaind stopped | Restore succeeds; recovery reported as failed; after starting captaind, "Retry recovery" recovers the 30,000 sats |
| Passphrase wallet across an app restart | Ark screen asks to unlock; a wrong passphrase is rejected before bark is called; the right one reopens the existing database with its 20,000 sats |
| Logging | bark logs in `adb logcat -s bark` via the patched library, no crashes |

Unit tests: 7 new `WalletProvider` tests cover creating the Ark wallet before activation,
rollback when Ark creation fails, the missing-seed guard, watch-only→hot conversion, deletion,
hot→watch-only conversion and startup cleanup. The full suite matches the upstream v0.20.0
baseline (the same 10 pre-existing failures).

## Known PoC limitations

- No boarding, sending or offboarding yet (milestone 2), and no exits.
- Ark balances aren't included in Coconut's wallet or total balances.
- Strings are plain English, not localized. The reused passphrase sheet's button says "Sign".
- "Retry recovery" is also offered on newly created wallets, whose recovery status is "not run";
  running it is harmless.
- Android only: iOS hasn't been built with `bark_bitcoin`.
