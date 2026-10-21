# Bark integration notes (proof of concept)

Notes from adding a bark (Ark) wallet to Coconut Wallet's hot wallets, kept as feedback on how
easy bark is to integrate.

- **Milestone 1:** an Ark wallet created and restored together with the hot wallet, plus a
  minimal Ark screen.
- **Milestone 2:** Ark folded into the hot wallet as one wallet: a Realm cache of Ark data,
  bark opened once per app session, one combined balance, a BIP321 receive code (Bitcoin, Ark,
  Lightning), a VTXO section with delegated refresh, and Ark movements in the transaction
  history.

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
  the next milestone (board via `boardFundingAddress` + a Coconut-signed PSBT + `boardPsbt`;
  offboard to a Coconut address).
- **Unlocking:** bark keeps the seed for as long as a wallet is open. The first time a hot
  wallet is entered after launch, Coconut asks once (biometrics or PIN, plus the passphrase for
  "enter passphrase when signing" wallets) and keeps its Ark wallet open for the rest of the
  process. Declining isn't asked again until the next launch; the receive and VTXO screens offer
  an explicit unlock.
- **Cache:** after every sync the Ark balance, VTXOs and movements are copied into Realm
  (`RealmArkWalletState`, `RealmArkVtxo`, `RealmArkMovement`), so balances and history show while
  a wallet is locked or offline. bark's own database can only be read through an open wallet.
- **Sync:** bark is opened with `daemonManualSync: true` and the app drives it while in the
  foreground: `maintenanceDelegated()` every 60 s and on resume, `sync_()` every 5 s while the
  receive screen waits for a payment. Every call into a wallet runs under a per-wallet lock.
- **One wallet:** balance screens show on-chain + Ark (the 0.7.1 fields summed; see 24); spending
  and Move to Vault keep the on-chain balance. The receive QR is `bitcoin:<address>?ark=<Ark
  address>&lightning=<invoice>`, with one copy row per method. "VTXO · N" sits next to the UTXO
  section. Ark movements are merged into the recent list, the full list and the home carousel
  through a `WalletActivity` type in view models; sync and RBF/CPFP code still see only on-chain
  transactions.

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
   mailbox). Coconut otherwise unlocks secrets only per signature, behind authentication, and
   wipes them right after. Coconut compromises by opening bark once per app session (see 21).
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
14. **The daemon only refreshes interactively.** On a round attempt the daemon joins with
    `join_round_for_maintenance_refresh`, an interactive participation the phone has to stay
    online for (`bark/src/daemon/mod.rs`). There's no setting to make it schedule delegated
    refreshes instead, so a mobile app has to turn the daemon's syncing off
    (`daemonManualSync`) and drive `maintenanceDelegated()` itself.
    `maintenanceDelegated()` may then spend refresh fees without the user confirming; only the
    manual Refresh shows a fee first.
15. **Lightning payments are claimed only during a sync.** `bolt11Invoice` registers the receive,
    and the HTLC is claimed by the next `sync()` (`try_claim_all_lightning_receives`). The
    receive screen polls with `sync_()` every 5 s; a payment made after the user leaves waits for
    the next maintenance tick or app launch.

### Observed at runtime (bark 0.7.1, bark-ffi 0.29.0)

16. **Misleading open-time warning.** Right after `bark::Wallet::open`, bark-ffi checks
    `ark_info()` and logs `[OPEN] Server connection FAILED - Lightning and Ark operations will not
    work!` if it isn't there yet (`src/core/wallet.rs:213`). Existing wallets and wallets created
    with `createWithoutServer` connect lazily through the daemon, so this fires on almost every
    open even though the daemon connects a moment later. The underlying error is discarded
    (`.ok()`), so a real failure would look the same.
17. **Esplora keep-alive failures.** electrs's Esplora server closes idle keep-alive connections
    after 10–35 s without advertising it. bark's Esplora client (reqwest) reuses the dead pooled
    connection and fails with `hyper::Error(IncompleteMessage)` on `GET /blocks/tip/height`,
    with no retry, so roughly every other maintenance refresh fails ("Failed to join round for
    maintenance refresh"). Suggestion: a pool idle timeout shorter than common server
    keep-alives, or retrying idempotent GETs.
18. **`stopDaemon()` returns before the daemon stops.** Deleting the datadir right after it led
    to one more round event failing with "unable to open database" before the daemon logged its
    shutdown. The bindings also export `stopDaemonWait()`, which Coconut now uses before
    `dispose()`; the name doesn't make the difference obvious.
19. **New databases replay every migration.** Creating a wallet runs 42 SQLite migrations one
    by one: 1.2 s on the emulator normally, about 10 s under load. A schema snapshot for fresh
    databases would make wallet creation (which Coconut does inside the hot wallet's create
    flow) cheaper.
20. **Fee fallback log units.** On regtest the fallback is logged as `falling back to 0.00001
    sat/kvB`, which looks like a BTC/kvB value with a sat/kvB label.

### Keys on demand

21. **The seed is needed just to sync.** Reading the mailbox (Ark receives), claiming Lightning
    and even reading balances need an open wallet, and opening needs the seed. A wallet that
    unlocks keys per operation, as Coconut does, either keeps the seed in memory anyway or shows
    stale data. Coconut keeps a Realm copy of everything bark reports.
    - **Proposal (bigger change):** let the host supply keys on demand. bark would hold public
      data (VTXO pubkeys, mailbox identifier, server info) and ask the host, through an async
      callback, to unlock keys when an operation needs a signature or the mailbox key, so the
      app can authenticate the user and wipe the key afterwards.
    - **Smaller steps:** a read-only open of the database without the seed (balance, VTXOs,
      history), and a sync-only mode holding just the mailbox key.

### API shape (bark-ffi 0.29.0)

22. **BIP321 build and parse aren't exposed.** bark has `Wallet::bip321_uri()` (on-chain + `ark=`
    + `lightning=` from one builder) and `parse_payment_request()` (BIP321, BOLT11, BOLT12,
    Lightning addresses, Bitcoin and Ark addresses), but bark-ffi exports neither. Coconut builds
    the URI in Dart, and a unified send would have to re-implement the parser.
23. **Movement details are untyped.** `Movement.metadataJson` is a JSON string whose keys depend
    on the subsystem (`chain_anchor` for boards, `offboard_txid`, `payment_hash`, …).
    `sentToAddresses` and `receivedOnAddresses` hold JSON-encoded payment methods
    (`{"type":"ark","value":"tark1…"}`), not addresses. Status and subsystem are strings and
    timestamps are RFC 3339 strings. Pairing a board with its on-chain transaction means parsing
    the outpoint out of `chain_anchor`.
24. **The 0.7.1 balance can count twice.** The fields come from independent lists: inputs of a
    delegated round the server hasn't picked up are both spendable and pending in round, and
    sats held by an offboard or an Ark send are in no field. Fixed on bark master (2026-09-22,
    with `Balance::total()`/`summary()`), but in no release and not in `bark_bitcoin`. Coconut
    sums the fields and accepts the over-count during a delegated refresh.
25. **Address reuse is the host's job.** `newAddress()` derives a new key on every call, and
    recovery stops after `vtxo_key_gap_limit` (250) unused keys. There's no "current unused
    address", so Coconut stores the shown address and only asks for a new one after a movement
    received on it.
26. **Use after `dispose()` crashes.** Every method clones the native pointer, so a call that
    starts after `dispose()` with a stale reference is a native crash, not a Dart exception. With
    a background sync loop the host has to serialize every call per wallet itself.
27. **Lightning invoices need an amount.** `bolt11Invoice` takes a required amount, so the receive
    code can only include Lightning once the user sets one.

### Test environment

28. **Electrum servers.** Coconut needs Electrum `server.features`. mempool's electrs fork lacks
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

Milestone 2, same setup:

| Scenario | Result |
|---|---|
| Upgrade with existing wallets | Realm migrates 10 → 11 on launch. Until a hot wallet's Ark wallet is unlocked once, its cache is empty, so it shows its on-chain balance only (Wallet 3 showed 0 until unlocked) |
| Session unlock | Wallet 1 (app lock off) opened on entry without a prompt. Wallet 3 ("enter passphrase when signing") asked on entry; after cancelling, re-entering didn't ask again, and the VTXO page's Unlock opened it (268 ms) with its 20,000 sats |
| Delegated only | bark logs `Daemon running in manual-sync mode; background sync disabled` and `Starting wallet maintenance in delegated mode` |
| One balance | Header, home card and home total show 0.86844800 BTC = 0.86745 on-chain + 99,800 Ark sats. After a cold restart the home screen showed it from the cache before bark was opened |
| Manual refresh | Fee shown first (200 sats); `Delegated round participation submitted`; the round completed in 25 s. While it waited the Ark balance read 0.000998 BTC (0.0005 spendable + 0.000498 pending in round), the double count in 24 |
| Ark receive | 20,000 sats from the stack's bark CLI to the receive screen's Ark address arrived within about a second (`Received arkoor (movement 3)`), and the screen moved on to a new Ark address |
| Lightning receive | A 30,000-sat invoice (fee 0 on regtest) paid by the stack's bark CLI was claimed by the receive screen's 5 s sync; the row switched to "Paid" |
| History | The recent list, full list and home carousel show the Lightning receive, the Ark receive and the refresh (−200 sats) with Ark/Lightning badges; the detail screen lists the subsystem and the VTXOs spent and created |
| Backgrounding | No maintenance in 75 s in the background; one right after returning. Found on the way: `AppGuard`'s `paused` branch returns early because `inactive` already set its flag, so the Ark pause hook runs before that check |

Not checked on the device: decoding the QR (no decoder at hand; the URI is unit-tested and the
payments above used the shown addresses), and deleting a wallet (unit-tested).

Unit tests: milestone 1 added 7 `WalletProvider` tests (Ark creation before activation,
rollback, the missing-seed guard, conversions, deletion, startup cleanup). Milestone 2 adds 29:
Ark models (balance total, movement kinds, linked txid, destinations, snapshot comparison), the
Realm cache (round trip, replacement, per-wallet isolation, no write after delete, deletion with
the wallet), `ArkProvider` (cached data while locked, sync to Realm, offline sync, cancelled
unlock, open vs. create, shared prompt, delegated refresh), display balances, the BIP321 URI and
the merged history order. The full suite matches the upstream v0.20.0 baseline (the same 10
pre-existing failures).

## Known PoC limitations

- No moving funds between on-chain and Ark (board, offboard), no unified send and no exits yet.
- After an upgrade, a hot wallet shows its on-chain balance only until its Ark wallet has been
  unlocked once; afterwards locked wallets show the last synced Ark data.
- The Ark total over-counts while a delegated refresh waits for its round (24).
- Lightning payments are claimed while the app is open (5 s on the receive screen, else the
  60 s maintenance or the next launch). Delegated maintenance may spend refresh fees without
  asking.
- Ark rows have no memos, the home analysis widget is on-chain only, and boards/offboards aren't
  paired with their on-chain transactions yet.
- Strings are plain English, not localized. The reused passphrase sheet's button says "Sign".
- "Retry recovery" is also offered on newly created wallets, whose recovery status is "not run";
  running it is harmless.
- Android only: iOS hasn't been built with `bark_bitcoin`.
