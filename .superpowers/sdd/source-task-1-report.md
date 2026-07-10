# Source Task 1 Report: Tauri Atomic Settings Service

## Scope

- Branch: `audit/v0.7.2-full-project`
- Owned implementation: `tauri-app/src-tauri/src/platform/settings.rs`
- Required routing change: `tauri-app/src-tauri/src/platform/mod.rs`
- No App was built, opened, or killed.
- Existing Provider, frontend, and Swift worktree changes were not edited or staged.

## Implementation

- Added one process-wide `Mutex` for settings reads and read-modify-write transactions.
- Routed floating settings, position, display surfaces, quota cadence, account display name,
  setup completion, Codex Home save, and Codex Home reset through one mutation helper.
- The helper sanitizes once, writes the exact returned snapshot, and holds the lock until the
  durable save has completed.
- Writes use a same-directory `create_new` temporary file with process/counter uniqueness,
  `write_all`, `flush`, `sync_all`, and an atomic destination replacement.
- Unix uses rename-over-existing. Windows uses `MoveFileExW` with
  `MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH`.
- Corrupt or missing primaries inspect at most eight matching interrupted-write files, recover
  from the newest valid candidate, and include bounded candidate diagnostics on failure.
- A valid primary remains authoritative and ignores stale or corrupt interrupted-write files.

## TDD Evidence

### RED

Command:

```text
cargo test --lib platform::settings::tests::
```

Result: exit 101 before production implementation. Rust reported nine expected missing-feature
errors for `mutate_app_settings_at`, `read_app_settings_at_with_diagnostics`, and
`RECOVERY_CANDIDATE_LIMIT`.

### GREEN

- `cargo test --lib platform::settings::tests::`: 13 passed.
- `cargo test --lib platform::`: 24 passed.
- `cargo test --lib commands::window_auth::tests::`: 5 passed.
- `cargo test --lib core::usage::cache_lifecycle::tests:: -- --test-threads=1`: 4 passed.
- Aggregate-cache unique-temp regression: 1 passed.
- Token-event-cache in-flight-temp regression: 1 passed.
- `cargo test --lib core::unread::tests:: -- --test-threads=1`: 8 passed.
- `settings.rs` was formatted with the installed 1.92 rustfmt, followed by focused GREEN.
- `git diff --check` on the owned paths passed.

The first parallel `cache_lifecycle` run had two failures caused by that module's shared process
environment fixtures. Both failing tests passed in the immediate single-thread rerun; no
`cache_lifecycle` source was changed.

Running rustfmt on the module root also formatted two unowned sibling modules. That mechanical
formatting was fully reversed before staging; final status confirms neither sibling is modified.

## Residual Risks

- The lock is intentionally process-wide, not an inter-process file lock.
- Windows runtime replacement was not executed on this Mac. A full Windows-target `cargo check`
  was attempted but stopped in the third-party `ring` build script because this Mac lacks the
  Windows C SDK headers (`assert.h`); it did not reach this crate's settings code.
- Recovery is deliberately bounded to the eight newest matching temporary files. Older
  candidates remain untouched and are reported through the bounded diagnostic.
