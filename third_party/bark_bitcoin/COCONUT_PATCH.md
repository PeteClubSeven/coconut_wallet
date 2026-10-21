# Coconut patch to bark_bitcoin

This is `bark_bitcoin 0.25.0+bark-0.7.1` from pub.dev (without its `example/`), with one change.

## Logcat logger (`rust/src/lib.rs`, `rust/Cargo.toml`)

bark's `log` records go straight to Android logcat with the tag `bark`: debug level for
`bark`, `bark_ffi`, `ark`, `server_rpc` and `bitcoin_ext`, info for everything else. Panics are
logged too. It is installed when the library loads (`.init_array`), on Android only.

```bash
adb logcat -s bark
```

Why: the SDK's only log sink is `setLogger`, which bark-ffi calls synchronously on whichever
thread logs, usually a tokio worker. The Dart bindings implement that callback with
`Pointer.fromFunction`, which Dart only allows on the isolate's own thread, so the SDK's own
`barkAttachPrintLogger()` aborts the process with SIGABRT on the first log record (in
`Wallet.open`, from `bark_ffi::muniffi::db::open_sqlite_db`). Don't call `setLogger` with this
patch: the `log` crate accepts a single logger per process.

## Updating

Copy the new release from the pub cache (or the `dart/` directory of
https://gitlab.com/ark-bitcoin/bark-ffi-bindings at the matching tag), drop `example/`, and
re-apply the two `COCONUT PATCH` hunks. The bark version must match the Ark server's.
