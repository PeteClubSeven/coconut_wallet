# Bark integration notes (proof of concept)

Notes from adding a bark (Ark) wallet to Coconut Wallet's hot wallets, kept as feedback on how
easy bark is to integrate.

- **Milestone 1:** an Ark wallet created and restored together with the hot wallet, plus a
  minimal Ark screen.
- **Milestone 2:** Ark folded into the hot wallet as one wallet: a Realm cache of Ark data,
  bark opened once per app session, one combined balance, a BIP321 receive code (Bitcoin, Ark,
  Lightning), a VTXO section with delegated refresh, and Ark movements in the transaction
  history.
- **Milestone 3:** one "Move" between the hot wallet's on-chain balance, its Ark balance and the
  user's vaults (watch-only wallets signed with Coconut Vault), including boarding straight from
  a vault, with each move shown as one history entry.
- **Milestone 4:** paying from Ark: Ark addresses, Lightning invoices and addresses, BIP321
  codes and plain Bitcoin addresses, from a Pay screen or handed over by Coconut's send screen
  and deep links.
- **Milestone 5:** one Send for hot wallets with Ark: the recipient first, then every way to pay
  it (Ark, Lightning, on-chain from the wallet, on-chain via Ark) with its fee, replacing the
  separate Pay screen.

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
- **On-chain wallet:** bark runs with `onchain: null`; Coconut's wallet stays the on-chain side.
- **Moving funds:** "Move" (replacing "Move to vault") moves between the on-chain balance, Ark
  and vaults; one end is always the hot wallet.
  - **On-chain or vault → Ark** reuses Coconut's send flow in a board mode: the recipient is
    bark's `boardFundingAddress()`, Coconut builds the PSBT (its coin selection and mempool fee
    rates) and signs it (hot wallet, or Coconut Vault over QR). Just before broadcasting,
    Coconut registers the board with `boardPsbt(unsigned PSBT)`, so bark gets the server's
    cosignature and leaves the broadcast to Coconut, then broadcasts it.
  - **Ark → on-chain or vault:** `offboardAll` for everything, `sendOnchain` for an amount.
  - **Vault → on-chain** is the vault's own send flow, receiving into the hot wallet.
  - A move is one history entry: the Ark movement carries the on-chain transaction its
    metadata names.
- **Paying:** Send on a hot wallet with Ark (and `bitcoin:` deep links to one) has two steps.
  1. **Who and how much:**
     - One row per recipient: an Ark or Bitcoin address, a BOLT11 invoice, a Lightning address or
       a BIP321 code, with its amount. Coconut parses it itself (37) and says what it is as it's
       typed.
     - The amount locks when the invoice or code carries one. Max (last row, on-chain) sends
       everything left.
     - "Add recipient" is a visible button, and what's available on-chain and in Ark is shown.
     - Several recipients need Bitcoin addresses: offboards and `sendOnchain` take one, so
       several are paid on-chain in one transaction.
  2. **Pay with:** one card per way to pay, with its fee. Until the user picks one, the cheapest
     is selected.
     - **Ark-funded cards** (one recipient only): `sendArkoorPayment`,
       `payLightningInvoice(wait: false)` (later syncs finish it), `payLightningAddress` and
       `sendOnchain`. Each is paid after a confirmation and biometrics/PIN.
     - **The on-chain card** builds the transaction from the wallet's UTXOs, with UTXO selection
       and fee rate, then goes to Coconut's confirm screen to sign and broadcast.

  Vaults and watch-only wallets keep Coconut's send screen. An Ark or Lightning code typed into
  that screen on a hot wallet goes back to step 1, along with the amount typed there.
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
  receive screen waits for a payment or a movement's detail screen is open. Every call into a
  wallet runs under a per-wallet lock.
- **One wallet:** balance screens show on-chain + Ark (the 0.7.1 fields summed; see 29); on-chain
  sends keep the on-chain balance. The receive QR is `bitcoin:<address>?ark=<Ark
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

9. **Boarding from a PSBT fits a host wallet well.** Coconut keeps its own coin selection,
    fee rates (sidestepping 5) and signing, and a vault signed air-gapped can fund Ark directly.
    The rough edges are 10–12.
10. **Who broadcasts a board is implicit.** bark broadcasts a finalized PSBT and otherwise
    waits for the transaction to appear (`bark/src/actions/board.rs`), with no flag saying
    which. A board whose transaction never reaches the network stays pending indefinitely:
    expiry is only handled once it's confirming. An explicit `broadcast: bool` and a way to
    cancel an un-broadcast board would help.
11. **The funding txid is pinned at `boardPsbt`.** bark only watches the txid it was given, so
    a fee bump (RBF) would leave the funds in an output no VTXO tracks. Coconut hides fee
    bumping on board funding transactions; CPFP remains.
12. **Each `boardFundingAddress()` burns a key** from the same keychain as Ark addresses (gap
    limit 250). Coconut reuses one per wallet until a board succeeds.

### Keys, custody and recovery

13. **Passphrases.** bark's mnemonic path assumes an empty passphrase; callers must pass the
   seed as hex instead. bark-cli/barkd can't restore a passphrase wallet.
14. **Custody model.** bark needs the seed in memory for the whole session (rounds, refresh,
   mailbox). Coconut otherwise unlocks secrets only per signature, behind authentication, and
   wipes them right after. Coconut compromises by opening bark once per app session (see 26).
15. **Recovery is server-trusted and partial.** Without the database, history and in-flight
    Lightning receives are lost, and recovery depends on the server returning the VTXOs.
16. **No "run recovery again".** Recovery runs only on the open that creates the database. If
    the server was unreachable at restore time, the only retry is deleting and recreating the
    (still unused) wallet. Confirmed: after a restore with captaind down, the daemon reconnected
    once captaind was back but the balance stayed at 0 until Coconut's "Retry recovery".

### Mobile lifecycle

17. **The app has to be online.** Rounds, refresh before expiry, Lightning claims and board
    registration need the app running. The daemon (`runDaemon`) suits a desktop process better
    than a backgrounded mobile app.
18. **The daemon only refreshes interactively.** On a round attempt the daemon joins with
    `join_round_for_maintenance_refresh`, an interactive participation the phone has to stay
    online for (`bark/src/daemon/mod.rs`). There's no setting to make it schedule delegated
    refreshes instead, so a mobile app has to turn the daemon's syncing off
    (`daemonManualSync`) and drive `maintenanceDelegated()` itself.
    `maintenanceDelegated()` may then spend refresh fees without the user confirming; only the
    manual Refresh shows a fee first.
19. **Lightning payments are claimed only during a sync.** `bolt11Invoice` registers the receive,
    and the HTLC is claimed by the next `sync()` (`try_claim_all_lightning_receives`). The
    receive screen polls with `sync_()` every 5 s; a payment made after the user leaves waits for
    the next maintenance tick or app launch.

### Observed at runtime (bark 0.7.1, bark-ffi 0.29.0)

20. **Misleading open-time warning.** Right after `bark::Wallet::open`, bark-ffi checks
    `ark_info()` and logs `[OPEN] Server connection FAILED - Lightning and Ark operations will not
    work!` if it isn't there yet (`src/core/wallet.rs:213`). Existing wallets and wallets created
    with `createWithoutServer` connect lazily through the daemon, so this fires on almost every
    open even though the daemon connects a moment later. The underlying error is discarded
    (`.ok()`), so a real failure would look the same.
21. **Esplora keep-alive failures.** electrs's Esplora server closes idle keep-alive connections
    after 10–35 s without advertising it. bark's Esplora client (reqwest) reuses the dead pooled
    connection and fails with `hyper::Error(IncompleteMessage)` on `GET /blocks/tip/height`,
    with no retry, so roughly every other maintenance refresh fails ("Failed to join round for
    maintenance refresh"). Suggestion: a pool idle timeout shorter than common server
    keep-alives, or retrying idempotent GETs.
22. **`stopDaemon()` returns before the daemon stops.** Deleting the datadir right after it led
    to one more round event failing with "unable to open database" before the daemon logged its
    shutdown. The bindings also export `stopDaemonWait()`, which Coconut now uses before
    `dispose()`; the name doesn't make the difference obvious.
23. **New databases replay every migration.** Creating a wallet runs 42 SQLite migrations one
    by one: 1.2 s on the emulator normally, about 10 s under load. A schema snapshot for fresh
    databases would make wallet creation (which Coconut does inside the hot wallet's create
    flow) cheaper.
24. **Fee fallback log units.** On regtest the fallback is logged as `falling back to 0.00001
    sat/kvB`, which looks like a BTC/kvB value with a sat/kvB label.

25. **Automatic refreshes show up as fees.** With delegated maintenance (18), bark scheduled
    refreshes on its own: two "Refresh" entries appeared in the history (−80 sats and 0) that the
    user never asked for.

### Keys on demand

26. **The seed is needed just to sync.** Reading the mailbox (Ark receives), claiming Lightning
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

27. **BIP321 build and parse aren't exposed.** bark has `Wallet::bip321_uri()` (on-chain + `ark=`
    + `lightning=` from one builder) and `parse_payment_request()` (BIP321, BOLT11, BOLT12,
    Lightning addresses, Bitcoin and Ark addresses), but bark-ffi exports neither. Coconut builds
    the URI in Dart, and a unified send would have to re-implement the parser.
28. **Movement details are untyped.** `Movement.metadataJson` is a JSON string whose keys depend
    on the subsystem (`chain_anchor` for boards, `offboard_txid`, `payment_hash`, …).
    `sentToAddresses` and `receivedOnAddresses` hold JSON-encoded payment methods
    (`{"type":"ark","value":"tark1…"}`), not addresses. Status and subsystem are strings and
    timestamps are RFC 3339 strings. Pairing a board with its on-chain transaction means parsing
    the outpoint out of `chain_anchor`.
29. **The 0.7.1 balance can count twice.** The fields come from independent lists: inputs of a
    delegated round the server hasn't picked up are both spendable and pending in round, and
    sats held by an offboard or an Ark send are in no field. Fixed on bark master (2026-09-22,
    with `Balance::total()`/`summary()`), but in no release and not in `bark_bitcoin`. Coconut
    sums the fields and accepts the over-count during a delegated refresh.
30. **Address reuse is the host's job.** `newAddress()` derives a new key on every call, and
    recovery stops after `vtxo_key_gap_limit` (250) unused keys. There's no "current unused
    address", so Coconut stores the shown address and only asks for a new one after a movement
    received on it.
31. **Use after `dispose()` crashes.** Every method clones the native pointer, so a call that
    starts after `dispose()` with a stale reference is a native crash, not a Dart exception. With
    a background sync loop the host has to serialize every call per wallet itself.
32. **Lightning invoices need an amount.** `bolt11Invoice` takes a required amount, so the receive
    code can only include Lightning once the user sets one.
33. **Error messages are lost in Dart.** bark-ffi's `Error` is a uniffi `flat_error` whose
    message follows the variant index on the wire, but the uniffi-dart reader only reads the
    index: every bark error reaches Dart as the bare `ErrorException.inner`. Found while a board
    broadcast failed and Coconut couldn't tell "already in utxo set" from a real failure.
    Coconut patches the vendored bindings to return a `BarkException` with the message
    (`third_party/bark_bitcoin/COCONUT_PATCH.md`). This is the SDK issue with the most impact
    found so far.
34. **A parked offboard is thrown as an error.** `offboardAll` / `sendOnchain` fail with "could
    not complete yet (parked …); it remains pending and will be retried on wallet sync" even
    though bark accepted the move. The host has to match the message (only possible with the
    patch in 33) to show it as pending rather than failed.

### Test environment

35. **Electrum servers.** Coconut needs Electrum `server.features`. mempool's electrs fork lacks
    it; Blockstream electrs needs the `electrum-discovery` build feature plus
    `--electrum-public-hosts` at runtime.
36. **A second bitcoind wallet stops block production.** The faucet stack's block generator
    calls `getnewaddress` without naming a wallet, so once another wallet is loaded it fails
    every tick (`-19: Multiple wallets are loaded`) and no blocks are mined until that wallet is
    unloaded. (Faucet repo, not bark.)

### Paying from Ark (bark 0.7.1, bark-ffi 0.29.0)

37. **Nothing to decode a payment request with.** bark-ffi pays BOLT11 invoices but has no
    decoder, and `parse_payment_request` isn't exported (27). Coconut classifies the string itself
    and reads an invoice's amount from its human-readable part, so it can't show the description,
    payee or expiry, and an expired invoice is only caught when bark tries to pay it.
38. **Payments don't say which movement they created.** `sendArkoorPayment` returns nothing;
    `payLightningInvoice(wait: false)` returns an in-progress `LightningSend` (invoice, amount,
    fee) with no payment hash or movement id; `sendOnchain` returns the txid. To open the
    payment's entry afterwards, Coconut compares `history()` before and after the call under its
    per-wallet lock.
39. **The Lightning send expiry allows one block of lag.** bark sets the HTLC expiry to its own
    chain tip + `htlc_send_expiry_delta` (258), and the server rejects anything below its tip +
    delta − 1: "requested expiry is too low. our tip is 7765. sync your node and try again". The
    wallet's tip comes from its chain source. With 5 s regtest blocks, electrs' Esplora was often
    a block behind bitcoind, so most first attempts failed, even right after a sync. Coconut syncs
    before a Lightning payment and retries twice on that message. bark could retry with the
    server's tip (the error already reports it), or the server could allow a few blocks. On
    mainnet this should be rare, but it can still happen right after a new block.
40. **A Lightning send the server refuses stays pending forever.** When the server rejects a
    payment at the start (as in 39), bark 0.7.1 leaves its movement `pending` with effective
    balance 0 and no HTLC VTXOs, and later syncs never resolve it. Retrying the same invoice
    creates a second movement with the same payment hash (movements 15 and 16 on the test
    device). Coconut hides pending Lightning sends that have nothing locked.
41. **bark's BIP321 codes key a regtest address as `tb=`.** `bark bip321 --all` writes
    `bitcoin:?amount=…&lightning=…&tb=bcrt1p…&ark=…`. BIP321 names address parameters after the
    address's human-readable part, which would be `bcrt=`. Coconut accepts `bc=`, `tb=` and
    `bcrt=` when the path is empty. With the path empty, a BIP21-only wallet finds no on-chain
    address to pay.
42. **A short claim window on regtest.** A receiver's HTLC recv expiry + `htlc_expiry_delta` (40)
    has to stay at or below the incoming HTLC's expiry. That left the receiver about 7 blocks
    (35 s at 5 s blocks) to claim. The stack's CLI, claiming a minute after Coconut paid, was
    refused ("Requested HTLC recv expiry too close to inbound HTLC expiry"). The server then failed
    the payment within about 3 minutes, and bark returned all 15,000 sats with no fee: a clean
    refund. On mainnet the window is over an hour, so this mostly affects tests.

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
| Manual refresh | Fee shown first (200 sats); `Delegated round participation submitted`; the round completed in 25 s. While it waited the Ark balance read 0.000998 BTC (0.0005 spendable + 0.000498 pending in round), the double count in 29 |
| Ark receive | 20,000 sats from the stack's bark CLI to the receive screen's Ark address arrived within about a second (`Received arkoor (movement 3)`), and the screen moved on to a new Ark address |
| Lightning receive | A 30,000-sat invoice (fee 0 on regtest) paid by the stack's bark CLI was claimed by the receive screen's 5 s sync; the row switched to "Paid" |
| History | The recent list, full list and home carousel show the Lightning receive, the Ark receive and the refresh (−200 sats) with Ark/Lightning badges; the detail screen lists the subsystem and the VTXOs spent and created |
| Backgrounding | No maintenance in 75 s in the background; one right after returning. Found on the way: `AppGuard`'s `paused` branch returns early because `inactive` already set its flag, so the Ark pause hook runs before that check |

Not checked on the device: decoding the QR (no decoder at hand; the URI is unit-tested and the
payments above used the shown addresses), and deleting a wallet (unit-tested).

Milestone 3, same setup (Wallet 1: 0.86745 BTC on-chain + 199,720 Ark sats; a watch-only
"vault" imported from a bitcoind descriptor):

| Scenario | Result |
|---|---|
| Move sheet | Offers On-chain, Ark and the vault as sources (empty ones disabled) and only valid destinations for each |
| On-chain → Ark, 0.001 BTC | The send screen shows bark's P2TR funding address as a read-only "Move to Ark" recipient, the server's minimum (20,000 sats) and "Arrives in Ark … after 3 confirmations". After signing, bark logged `funding tx not on the network yet: awaiting external funding broadcast`, then `Registered board` once it confirmed. One "Moved to Ark 0.001" entry; the total dropped by the 153-sat on-chain fee. Reopening reused the cached funding address |
| Lost broadcast reply | The first board broadcast got an "unknown error" from Coconut's Electrum connection although the node accepted it; retries were rejected with `-27 outputs already in utxo set`, and bark's error arrived as `ErrorException.inner` (see 33). The broadcast step now checks the node for the transaction before falling back to bark, and treats "already in utxo set" as sent |
| Ark → On-chain, 30,000 sats | `sendOnchain`: fee 2,580 sats shown first; one "Moved on-chain 0.0003" entry paired with the on-chain receive |
| Ark → On-chain, everything | `offboardAll` on Wallet 3: 20,000 sats in, 17,470 out after a 2,530-sat fee |
| Ark → Vault, 40,000 sats | "Sent on-chain" in the hot wallet; the vault received 0.0004 BTC |
| Vault → Ark / Vault → On-chain | Board mode and move mode open for the vault (Send All: 39,878 sats to the funding address, "Move to Wallet 1" labels) up to Coconut Vault's unsigned QR. Signing needs the camera, so the rest is covered by unit tests (board registered with the unsigned PSBT before broadcast; nothing sent if the server refuses) |

Milestone 4, same setup (Wallet 1 with about 0.25 BTC in Ark; the stack's bark CLI as the
other side):

| Scenario | Result |
|---|---|
| Ark address, 10,000 sats | Typed into Coconut's send screen, which handed it to Pay from Ark. bark validated the address and quoted a fee of 0; the app opened "Sent · Ark · successful" and the CLI received it |
| Lightning invoice, 12,000 sats | Fee 48 sats. The first attempt was rejected for a stale chain tip (39) and the automatic retry succeeded: "Sent · Lightning · successful" once the CLI claimed it |
| Unclaimed Lightning payment, 15,000 sats | The CLI claimed too late (42); the payment failed within about 3 minutes and the 15,000 sats came back. Earlier attempts rejected at the start left pending 0-sat movements (40), now hidden |
| bark's own BIP321 code, 8,000 sats | From `bark bip321 --all` (Lightning, a `tb=` address and Ark); paid over Ark, the cheapest option |
| Bitcoin address from Ark, 20,000 sats | `sendOnchain`: fee 2,530 sats, 22,530 sats left Ark |
| Deep link `bitcoin:?amount=0.00004&ark=…` | First opened the first wallet's send screen (a watch-only wallet, with no address). It now opens Wallet 1's and goes on to Pay from Ark with the amount and address; the fee shows once the session is open. Without an amount the screen asks for one |

Milestone 5 (the two-step Send), same setup:

| Scenario | Result |
|---|---|
| Bitcoin address | Detected as typed. Page 2 shows 0.1177 BTC on-chain (the 0.5 BTC UTXO is locked) and 0.2497 BTC in Ark. At 0.0002 BTC: On-chain ≈ 141 sats (preselected), On-chain via Ark 2,470 sats |
| On-chain card | 5 sat/vB from the fee sheet: fee 704 sats. Two hand-picked UTXOs (0.0167 BTC): fee 1,044 sats. Max: 0.01669111 BTC (no change, 889 sats). A second recipient of 0.003 BTC left the first 0.01368956 BTC and turned On-chain via Ark to "Ark pays one destination". The confirm screen listed both outputs; signed, broadcast, back on the wallet screen |
| Lightning invoice, 11,000 sats | "Set by the invoice", only Lightning, fee 22 sats; paid and claimed by the CLI: "Sent · Lightning · successful". Back returns to the wallet screen |
| `bark bip321 --all`, 9,000 sats, as a deep link | Opened on page 2 with all four cards: Ark 0, Lightning 20, On-chain ≈ 153, On-chain via Ark 2,568 sats. Ark was preselected and paid. Back returns home |
| Locked Ark (Wallet 3, unlock cancelled) | No prompt on page 2 for a Bitcoin address. On-chain via Ark shows "Ark is locked" with Unlock, and On-chain works |
| Vault | Its Send still opens Coconut's send screen |

Not checked on the device: the hand-back from Coconut's send screen (its UTXO-list entry wasn't
reachable in the time) and an Ark address on its own (Ark was paid through the BIP321 code).
The first build hid the Next/Pay button behind the keyboard; it now sits above it.

Then recipients and amounts moved to step 1. Upstream Coconut hides batch sends behind a sideways
swipe on its send screen. Results:

| Scenario | Result |
|---|---|
| Three Bitcoin recipients, one removed | Each row has its own amount, Max only on the last. An Ark address in a later row shows "Several recipients are paid on-chain: use a Bitcoin address" and Next stays off |
| Two recipients (0.001 and 0.002 BTC) | Step 2 lists both and only On-chain (≈ 172 sats); the confirm screen shows both outputs plus change; signed and broadcast |
| Bitcoin address with an amount | On-chain ≈ 141 sats and On-chain via Ark 2,580 sats |
| Max on a Bitcoin address | "Everything left" on step 1; step 2 offers only On-chain with the computed amount (available − 314 sats fee) |
| Lightning invoice, 7,000 sats | Amount locked on step 1 ("Set by the invoice"); Lightning paid on step 2, fee 35 sats |

Not checked on the device: Lightning addresses (the stack has no LNURL server), BOLT12 and
LNURL (reported as unsupported), and an amountless invoice.

Unit tests: milestone 1 added 7 `WalletProvider` tests (Ark creation before activation,
rollback, the missing-seed guard, conversions, deletion, startup cleanup). Milestone 2 adds 29:
Ark models (balance total, movement kinds, linked txid, destinations, snapshot comparison), the
Realm cache (round trip, replacement, per-wallet isolation, no write after delete, deletion with
the wallet), `ArkProvider` (cached data while locked, sync to Realm, offline sync, cancelled
unlock, open vs. create, shared prompt, delegated refresh), display balances, the BIP321 URI and
the merged history order. Milestone 3 adds 18: board and offboard calls (sync requested
mid-sync, funding address reuse, parked moves), broadcasting a board (registered before the
broadcast, nothing sent when refused, retry and fallbacks, a transaction already on the
network), the Move sheet's pairs, and pairing moves in the history. Milestone 4 adds 18: the
payment request parser (invoice amounts, networks, Ark and Lightning addresses, BIP321 with
encoded values, address parameters and `req-` parameters, unsupported kinds), payments by rail
with their movement, the stale-tip retry, and parked on-chain payments. Milestone 5 adds 11 for
the payment options: options per request kind, fixed vs entered amounts, balances with picked
UTXOs, the on-chain fee following the amount, UTXOs and fee rate, Max with several recipients,
on-chain-only extra recipients, the reasons an option can't be used, the cheapest default, stale
Ark estimates, and the hand-off to the confirm screen. Moving recipients to step 1 adds 6 for the
recipient rules (anything payable alone, Bitcoin addresses when several, fixed amounts from
invoices and codes, Max only last and on-chain, duplicates, more than the balance). The full suite matches the upstream
v0.20.0 baseline (the same 10 pre-existing failures).

### UI

The Ark screens are built from Coconut's own widgets and mirror their closest upstream screen:
- **Send, step 1 (recipients):** the send screen itself. It has the same app bar, swipe pages,
  keypad amount, address field, counter and tooltips. A visible "+ Add recipient" pill adds a
  page; upstream only has a swipe to a hidden last page.
- **Send, step 2 ("Pay with"):** the confirm screen.
- **VTXO overview:** the UTXO overview. It has the same collapsing header with the Ark balance and
  the Overview / List control. VTXOs show as coins in bucket rows, grouped by amount (the UTXO
  tiers) or by expiry (expired, a day, a week, 30 days, later), above a bar chart.
  Balance details, recovery and Refresh VTXOs are in a header menu. Recovery is on the page only
  when it failed.
- **Movement detail:** the transaction detail.
- **Ark → on-chain:** UTXO merge.
- **Move sheet:** Coconut's selectable sheets.

The building blocks are `CoconutTextField`, `CoconutOptionPicker`, `FixedBottomButton`,
`ShrinkAnimationButton` cards, `UnderlineButtonItemCard`, `CoconutChip` and the SVG icons. The few
shared Ark pieces are in `lib/widgets/features/ark/`. The logic returns codes (problems, labels),
and the widgets turn them into slang strings.

The UTXO overview's widgets are tied to `UtxoState`, so the coin stack, coin card, chart and
bucket row are adapted copies in `lib/widgets/features/ark/vtxo_overview_widgets.dart`. A shared
"coin" model across UTXOs and VTXOs would remove them. The send screen's keypad rules are in
`SendViewModel`, so step 1 uses a small port (`SendAmountText`).

## Known PoC limitations

- No exits, BOLT12 offers or LNURL yet. Lightning addresses are untested on the device.
- A Lightning payment that fails after starting disappears from the history (failed movements
  with no balance change are hidden). The detail screen it opened shows "failed" while open.
- Deep links with Ark or Lightning go to the first hot wallet with Ark; there's no wallet picker.
- Max is on-chain only (bark's fee depends on the amount), and the fee-from-amount switch is only
  in Coconut's send screen.
- Vault → Ark and Vault → On-chain were driven on the emulator only up to Coconut Vault's QR.
- After an upgrade, a hot wallet shows its on-chain balance only until its Ark wallet has been
  unlocked once; afterwards locked wallets show the last synced Ark data.
- The Ark total over-counts while a delegated refresh waits for its round (29).
- Lightning payments are claimed while the app is open (5 s on the receive screen, else the
  60 s maintenance or the next launch). Delegated maintenance may spend refresh fees without
  asking.
- Ark rows have no memos and the home analysis widget is on-chain only. A board funded by a
  vault shows as a plain send in the vault's history.
- The Ark strings are in an `ark` namespace in every locale file, in English for now (not yet
  translated). The reused passphrase sheet's button says "Sign".
- "Retry recovery" (in the VTXO overview's menu) is also offered on newly created wallets, whose
  recovery status is "not run"; running it is harmless.
- Step 1 of send has no address board (own wallets): Move covers those.
- Android only: iOS hasn't been built with `bark_bitcoin`.
