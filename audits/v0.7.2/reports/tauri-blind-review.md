# Codex Token Bar v0.7.2 - Independent Blind Tauri Review

## Review status

- **Baseline:** release tag `v0.7.2` at `e48930a626679230d5d52267c830812f254fdd26`.
- **Audit worktree HEAD:** `c7050b0537ea64a55dfcd04ceabf2f353a63bc9a`; `git diff v0.7.2..HEAD` contained only audit/planning, `.gitignore`, and release-ledger changes, not Tauri production or test changes.
- **Method:** manual source review and cross-boundary flow tracing. No automated scanners were used.
- **Execution constraints honored:** no build, app launch, test execution, process management, network request, Provider write, reset-credit consumption request, commit, push, or release action was performed.
- **Write boundary:** this report is the only file written.
- **Blind-review boundary:** no historical audit report, other reviewer output, or release-ledger content was read.

## Exact explored scope

The review started from the tagged tree and discovered the architecture from entrypoints, manifests, and imports rather than from a prescribed file list.

| Area | Explored scope |
|---|---|
| React/TypeScript production | All 128 non-test files under `tauri-app/src`, including the dashboard, floating window, status panel, all API/IPC clients, state hooks, settings, fallbacks, diagnostics, chart/ranking/radar/provider/quota components, utilities, types, and `global.css`. |
| Frontend tests | All 50 `*.test.mjs` files plus the SSR harness. The tree contains 265 top-level Node test cases. |
| Rust/Tauri production and tests | All 70 files under `tauri-app/src-tauri/src`: command registration/auth, dashboard data source, JSONL usage parser/caches, live-rate logs/rollouts/stream registry, quota and reset-credit readers, quota history, unread state, Provider repair, SQLite helpers, models, settings, native surfaces, and Windows/macOS integration. The source contains 195 Rust `#[test]` cases, including inline tests. |
| Packaging/capabilities | `tauri-app/package.json`, lockfile metadata, `Cargo.toml`, Cargo lock metadata, `tauri.conf.json`, `Info.plist`, all three Tauri capability files, and icon/bundle declarations. |
| Updater/release | `tauri-app/src/api/updateClient.ts`, update UI flow in `DashboardApp.tsx`, `scripts/build_tauri_windows_release.ps1`, and the shared `appcast.xml` lane declaration. |
| Size | 44,826 lines across reviewed TS, TSX, MJS, CSS, and Rust source/test files. |

Generated build outputs (`dist`, `target`, bundles, `node_modules`, and generated Tauri schemas), remote GitHub release assets, and live external service responses were not treated as production source.

## Architecture and flow maps

### Surface startup

`lib.rs` -> install process/autostart/updater plugins -> `setup_desktop_surfaces` -> create dashboard -> create hidden floating webview on Windows -> create tray.

`main.tsx` -> query `surface` -> `DashboardApp` / `FloatingWindowApp` / `StatusPanelApp` -> shared Tauri commands and global events.

### Usage totals

Dashboard/compact UI -> IPC -> `LocalCodexDataSource` -> discover JSONL files -> source-keyed event shard cache -> token delta parser -> aggregates/ranking/time series -> in-memory aggregate -> persistent aggregate cache -> React mergers/charts.

Fast startup uses a matching precise aggregate if available; otherwise it uses `state_5.sqlite` only for thread count and explicitly leaves token metrics as placeholders.

### Quota and reset credits

UI cadence/wake/reset timer -> `read_account_quota` -> global source-keyed quota gate/cache -> discovered Codex CLI -> child `app-server` JSON-RPC `account/rateLimits/read` -> parse 5h/7d -> HTTP GET for reset-credit inventory -> write/read local quota-history SQLite -> merge histories into dashboard/compact surfaces.

### Live rate and unread

Dashboard/compact subscription -> global Rust subscriber count -> one intended background loop -> source-resolved `LiveRateMonitorService` -> legacy `logs_2.sqlite` or recent rollout JSONL offsets -> estimated rate -> global `live-rate-snapshot` event.

Each live snapshot also uses the precise usage-summary cache and an unread cache. Unread comes from `.codex-global-state.json`, filtered through `state_5.sqlite` or session metadata, with recent `task_complete` JSONL scanning as fallback. Acknowledgement is stored in a Tauri-owned JSON file.

### Source and settings

Dashboard editor -> `set_codex_home` / `reset_codex_home` -> shared `settings.json` -> every Rust command resolves the current home from that file -> dashboard and compact views independently refresh local data.

Floating appearance, position, display-surface preferences, quota cadence, custom account name, setup completion, and Codex Home all share the same read-modify-write settings object.

### Provider repair

Scan config/SQLite/JSONL/index -> infer target provider -> create full-file backup -> rewrite every active/archived JSONL first line -> update all SQLite thread rows -> append latest missing index entry -> verify. Rollback copies backed-up files over current files.

### Radar and updater

Compact radar -> renderer fetch of public `current.json` and RSS with a ten-minute memory cache. Full detail -> main-window IPC -> Rust HTTP client with an embedded bearer token.

Updater -> Tauri signed metadata at `latest-windows.json` -> user confirmation -> `downloadAndInstall` -> relaunch. PowerShell release script builds x64/arm64 NSIS artifacts, copies `.sig` files, and generates updater JSON/checksums.

## Severity summary

| Severity | Count |
|---|---:|
| P0 | 0 |
| P1 | 6 |
| P2 | 12 |
| P3 | 4 |

## Confirmed findings

### P1-01 - Provider repair can select and propagate the literal sentinel `(missing)`

- **Files/lines:** `tauri-app/src-tauri/src/core/provider_repair/sqlite_state.rs:211-217`; `tauri-app/src-tauri/src/core/provider_repair/target_provider.rs:16-36`; `tauri-app/src-tauri/src/core/provider_repair.rs:42-57`.
- **Impact:** a repair intended to restore provider metadata can replace valid JSONL and SQLite providers with the invalid string `(missing)` across the complete history.
- **Trigger:** `config.toml` has no recognized top-level provider and the newest unarchived SQLite row has null/empty `model_provider`. `scan_sqlite` converts that absence into `(missing)`, and target selection gives the SQLite value priority over a valid newest JSONL provider.
- **Confidence:** high; the sentinel is returned as an ordinary `String` and is passed unchanged to both write paths.
- **Source-level reproduction:** create a state database whose newest row has an empty provider, retain an older JSONL with `openai`, omit the config setting, then trace scan -> target -> sync. No write was executed during this review.
- **Missing test:** target selection with an empty/null latest SQLite provider and a valid JSONL/config fallback; a test that forbids sentinel values from reaching write functions.

### P1-02 - Provider backup/rollback is not a consistent recovery point and can discard current Codex data

- **Files/lines:** `tauri-app/src-tauri/src/core/provider_repair/backups.rs:33-81,117-137,209-243`; `tauri-app/src-tauri/src/core/provider_repair/session_files.rs:85-109`; `tauri-app/src/components/ProviderRepairCard.tsx:57-103`; `tauri-app/src/components/providerRepair/ProviderRepairBackups.tsx:43-50`; `tauri-app/src/pages/dashboard/ProviderRepairPanel.tsx:55-57`.
- **Impact:** rollback can lose conversation records appended after the backup, discard uncheckpointed SQLite rows, or restore an internally inconsistent SQLite snapshot. A live Codex append racing a JSONL rewrite can also be lost before rollback is needed.
- **Trigger:** Codex remains open; a backup is taken while `state_5.sqlite` is in WAL mode; a historical backup is selected; or rollback is clicked after files have grown. Closing Codex is advisory only. Sync accepts any matching-home backup, not a fresh one, and rollback is a single unconfirmed click.
- **Evidence:** the main DB, WAL, and SHM are copied as independent live files; WAL/SHM copy errors are ignored; restore copies only the main DB and then deletes current WAL/SHM. JSONL rewrite and restore replace whole files without locking or re-stat checks. Backed-up WAL/SHM files are never restored.
- **Confidence:** high.
- **Source-level reproduction:** let a session file append after backup/read but before rewrite, or retain an uncheckpointed WAL and trace rollback. Select an old same-home backup and observe that full JSONLs are copied over newer files. No destructive operation was performed.
- **Missing test:** SQLite online-backup/WAL recovery, concurrent append detection, stale-backup rejection, atomic rollback, process-open guard, and confirmation-flow tests.

### P1-03 - Frontend timeouts do not cancel Provider writes and can enable overlapping destructive operations

- **Files/lines:** `tauri-app/src/platform/runtime.ts:5-17`; `tauri-app/src/api/providerRepairClient.ts:17-30`; `tauri-app/src/components/ProviderRepairCard.tsx:105-133`; `tauri-app/src-tauri/src/commands/provider_repair.rs:27-63`.
- **Impact:** two backup/sync/rollback operations can concurrently rewrite the same deterministic temp JSONL, database, index, manifest, or restore destination, causing partial repair or data loss.
- **Trigger:** a large backup/sync/rollback exceeds the 60-second UI timeout. `Promise.race` rejects but leaves the Tauri invocation running; the UI clears `busy`, and the backend has no operation mutex or idempotency token, so retry is accepted.
- **Confidence:** high for lifecycle and overlap possibility; elapsed time depends on history size and storage.
- **Source-level reproduction:** model a Provider command that resolves after 60 seconds, observe `run()` clearing `busy` on timeout, and invoke the action again while the first Rust call remains active.
- **Missing test:** cancellation/timeout ownership, backend single-flight exclusion, and delayed-operation retry tests.

### P1-04 - Archiving a session removes its tokens from every historical aggregate

- **Files/lines:** `tauri-app/src-tauri/src/core/usage/token_count_jsonl/session_files.rs:9-24,40-105`; `tauri-app/src-tauri/src/core/usage/token_count_jsonl/event_loader.rs:31-50`; `tauri-app/src-tauri/src/core/usage/token_count_jsonl.rs:66-119`.
- **Impact:** total tokens, total calls/threads, peak thread/day, streaks, heatmap, 24h/7d/30d curves, cache ranking, and cache-usage detail decrease when a user archives a conversation. Historical usage is therefore coupled to UI visibility rather than actual consumption.
- **Trigger:** Codex moves a rollout from `sessions/` to `archived_sessions/` and/or marks its SQLite thread archived.
- **Evidence:** usage discovery scans only `sessions/`; the SQLite supplemental query explicitly excludes archived rows. The cache then drops every unseen file with `retain_seen`.
- **Confidence:** high.
- **Source-level reproduction:** compare the discovered file/signature set before and after moving an otherwise unchanged rollout to `archived_sessions/`.
- **Missing test:** active-to-archived movement must preserve all usage aggregates and cached events.

### P1-05 - Shared settings persistence is non-atomic and can transiently switch the live data source

- **Files/lines:** `tauri-app/src-tauri/src/platform/settings.rs:16-63,66-105`; `tauri-app/src-tauri/src/platform/mod.rs:56-80`; `tauri-app/src-tauri/src/commands/live.rs:37-64`; `tauri-app/src/app/useDashboardShellSettings.ts:100-106`; `tauri-app/src/floating/useFloatingWindowPlacement.ts:24-30`; `tauri-app/src/components/liveRate/LiveRateSettingsPanel.tsx:230-250,479-488`.
- **Impact:** a crash/power loss can leave `settings.json` invalid and make all future read-modify-write saves fail. A concurrent live-rate/quota/usage reader can observe the truncate/write window, silently fall back to automatic `~/.codex`, and briefly display or query a different account. Concurrent writers can also lose unrelated fields.
- **Trigger:** any save, especially high-frequency range-input changes or floating-window move events, while background live snapshots resolve `default_codex_home`; process interruption during `std::fs::write` makes the damage persistent.
- **Evidence:** every setting command reads the entire object and directly truncates/writes the shared path; there is no temp-and-replace, fsync, lock, generation, or corrupt-file recovery. `saved_codex_home` converts every read/parse error to default settings.
- **Confidence:** high for non-atomicity and fallback behavior; race frequency is environment dependent.
- **Source-level reproduction:** trace a background `default_codex_home()` read between file truncation and payload completion, or inspect startup after an interrupted write.
- **Missing test:** atomic replacement on Windows/macOS, crash recovery, corrupt settings self-heal, concurrent reader/writer, concurrent field update, and slider/move debounce tests.

### P1-06 - Codex Home switching leaves stale or placeholder data across source boundaries

- **Files/lines:** `tauri-app/src/state/useDashboardActions.ts:50-63,124-136`; `tauri-app/src/state/usePreciseDashboardLoad.ts:30-39`; `tauri-app/src/state/useDeferredQuotaLoad.ts:30-41`; `tauri-app/src/state/useLiveThreadOptionsLoad.ts:26-39`; `tauri-app/src/floating/FloatingWindowApp.tsx:100-118`; `tauri-app/src/status/StatusPanelApp.tsx:58-77`; `tauri-app/src/surfaces/useCompactPanelData.ts:42-52`; `tauri-app/src/surfaces/compactPanelSnapshotModel.ts:121-127`.
- **Impact:** after an account/source switch, the dashboard may keep placeholder totals/quota and old thread options until periodic generations advance; floating/status quota can keep the previous account until its next poll, and an old in-flight quota can publish after the switch. Switching custom -> automatic does not clear a trusted compact usage summary.
- **Trigger:** save or reset Codex Home while dashboard and compact surfaces are mounted, especially with a quota request in flight.
- **Evidence:** the source action reloads only the fast snapshot and does not increment precise/quota/thread generations. Rust source commands emit no app-settings event. Compact quota receives no source key or request generation. Compact usage reset requires a truthy next key, so `null` automatic mode bypasses reset.
- **Confidence:** high.
- **Source-level reproduction:** trace custom A -> custom B and custom A -> automatic while generation refs already equal their current values and a compact quota request is unresolved.
- **Missing test:** an end-to-end dashboard command/event/hook test covering both switch directions, old-request suppression, compact quota reset, and immediate precise/quota/thread reload.

### P2-01 - Provider JSONL replacement fails on Windows when the destination exists

- **Files/lines:** `tauri-app/src-tauri/src/core/provider_repair/session_files.rs:136-139`; caller `tauri-app/src-tauri/src/core/provider_repair.rs:42-56`.
- **Impact:** the primary Windows Tauri lane cannot repair any mismatching existing JSONL; sync aborts on its first rewrite and leaves a temp file.
- **Trigger:** run sync on Windows with at least one provider mismatch.
- **Confidence:** high; `std::fs::rename` does not replace an existing destination on Windows.
- **Source-level reproduction:** apply the function's write-then-rename sequence to an existing destination using Windows rename semantics.
- **Missing test:** Windows replacement behavior and cleanup of failed temp files.

### P2-02 - Live-stream refcounting can duplicate loops or cancel another surface's subscription

- **Files/lines:** `tauri-app/src-tauri/src/commands/live.rs:75-107,109-168`; `tauri-app/src/state/useLiveRateFeed.ts:70-97`; `tauri-app/src/surfaces/useCompactPanelSnapshot.ts:137-183`; tests `tauri-app/src-tauri/src/commands/live.rs:360-399`.
- **Impact:** rapid stop/start can leave two background loops emitting and computing forever. Cleanup also decrements the global count even if that hook never successfully started, so one surface can stop the stream still needed by another.
- **Trigger:** selected-thread changes, source/loading transitions, remount/retry, or unmount while reset/start is still pending. If stop sets `running=false` and a new start sets it true before the old loop checks, both loops observe the new active state and continue.
- **Confidence:** high for the state-machine race.
- **Source-level reproduction:** sequence start -> stop -> start before the old loop reaches `stream_snapshot_request`; separately unmount before pending start increments and let unconditional cleanup stop another subscriber.
- **Missing test:** task-generation/handle ownership, per-subscriber tokens, delayed command ordering, and actual loop-count assertions. Existing tests check only synchronous counters.

### P2-03 - WAL-blind rollout discovery can miss newly created live sessions indefinitely

- **Files/lines:** `tauri-app/src-tauri/src/core/live_rate/rollout.rs:105-133`; `tauri-app/src-tauri/src/core/live_rate/monitor.rs:202-221`; `tauri-app/src-tauri/src/core/live_rate/state.rs:77-113`.
- **Impact:** on modern rollout fallback, live rate remains zero or follows an older thread even while a new thread is producing output.
- **Trigger:** `state_5.sqlite` is in WAL mode and the new thread/rollout path exists only in `state_5.sqlite-wal`. The cache has no TTL and signatures only the main DB file, not its WAL/SHM.
- **Confidence:** high for invalidation omission; checkpoint timing is external.
- **Source-level reproduction:** cache recent rollout threads, insert a newer thread through a WAL connection without checkpointing, and compare the unchanged signature/cache decision.
- **Missing test:** WAL-only thread insertion and refresh, plus a bounded TTL fallback.

### P2-04 - A failed new-source quota read can attach the previous account's history

- **Files/lines:** `tauri-app/src-tauri/src/core/quota.rs:54-88,285-309,340-356`; `tauri-app/src-tauri/src/core/quota_history/database.rs:70-79,234-264`.
- **Impact:** quota charts for account B can display account A's historical 5h/7d series, violating account provenance.
- **Trigger:** switch to B and have B's current rate-limit read fail before `record_bundle`. History refresh is global and asks the database for whichever account owns the latest row, still A.
- **Confidence:** high.
- **Source-level reproduction:** reason over a database whose latest trusted row is A, then build B's failure bundle and trace `history_bundle()` without an account parameter.
- **Missing test:** two accounts/sources where the second read fails, including memory-cache behavior.

### P2-05 - `currentStreakDays` reports the most recent old streak after any length of inactivity

- **Files/lines:** `tauri-app/src-tauri/src/core/usage/token_count_jsonl/aggregates.rs:168-177`.
- **Impact:** the dashboard and exported PNG can claim an active streak even when there has been no use for days or months.
- **Trigger:** one or more trailing zero-usage days after any historical non-zero run.
- **Evidence:** reverse iteration skips all trailing zeros while `streak == 0`, then counts the first historical run it encounters.
- **Confidence:** high.
- **Source-level reproduction:** pass `[active, active, zero, zero]`; the function returns 2 instead of 0.
- **Missing test:** trailing one-day and multi-day inactivity, today/yesterday semantics, and empty history.

### P2-06 - Disabled/hidden floating windows continue local scans, quota work, live subscription, and Radar requests

- **Files/lines:** `tauri-app/src-tauri/src/platform/surfaces.rs:40-56,517-569`; `tauri-app/src/floating/FloatingWindowApp.tsx:19-32,84-127,154-171`; `tauri-app/src/surfaces/useCompactPanelData.ts:34-52`.
- **Impact:** unnecessary battery, disk metadata scans, Codex child/network quota work, and ten-minute Radar requests continue when the user believes the floating surface is off. On Windows this starts from the hidden startup webview even before first enable.
- **Trigger:** Windows startup with floating disabled, or hide/disable an already-created floating window on either platform.
- **Evidence:** the webview remains mounted; `active` defaults to true and the display event updates only live-rate enablement, not floating visibility. Radar has no visibility gate.
- **Confidence:** high.
- **Source-level reproduction:** follow the hidden window creation and React mount path without calling `show`; all effects still start.
- **Missing test:** hidden/disabled surface quiescence and visibility-event lifecycle.

### P2-07 - macOS advertises a status popup that has no reachable tray action, and tray live text depends on the dashboard webview

- **Files/lines:** `tauri-app/src-tauri/src/platform/capabilities.rs:119-151`; `tauri-app/src-tauri/src/platform/surfaces.rs:205-243`; popup implementation `tauri-app/src-tauri/src/platform/surfaces.rs:144-159,587-609`; `tauri-app/src/tray/useStatusTray.ts:31-46`.
- **Impact:** the advertised independent status panel is unreachable from the tray. Closing the dashboard also removes the only React hook that updates tray live text, so the macOS menu-bar number freezes until the dashboard is recreated.
- **Trigger:** click the tray icon expecting the status panel, or close the dashboard while keeping the tray app alive.
- **Evidence:** both left-click and the sole open menu item call `show_dashboard_window`; no production caller invokes `show_status_panel_window`.
- **Confidence:** high from call graph; close/keep-alive behavior remains a runtime platform detail.
- **Source-level reproduction:** trace both tray callbacks and search production callers of the status-show command.
- **Missing test:** tray event -> panel reachability and dashboard-destroyed tray refresh ownership.

### P2-08 - Two cache replacement paths silently fail on Windows

- **Files/lines:** `tauri-app/src-tauri/src/core/usage/cache_lifecycle.rs:38-68`; `tauri-app/src-tauri/src/core/usage/token_count_jsonl.rs:511-532`.
- **Impact:** cache namespace upgrades can remain permanently marked uninitialized; persistent dashboard aggregate updates fail after the first file and leave unique temp files. Restarts then repeat expensive precise rebuilds.
- **Trigger:** a destination `cache-state.json` or `dashboard-aggregate.json` already exists on Windows.
- **Confidence:** high; both use rename-over-existing. Errors are ignored by the normal callers.
- **Source-level reproduction:** apply a second marker/aggregate save under Windows replacement semantics.
- **Missing test:** repeated Windows save, upgrade marker replacement, temp cleanup, and surfaced persistence failures.

### P2-09 - The full-detail Radar bearer credential is reversibly embedded in shipped source/binary

- **Files/lines:** `tauri-app/src-tauri/src/commands/codex_radar.rs:7-17,51-75`; test `tauri-app/src-tauri/src/commands/codex_radar.rs:90-103`.
- **Impact:** any user can recover and reuse the shared `crr_live_...` bearer token, enabling service abuse, quota exhaustion, credential revocation, and loss of the detail feature for all clients.
- **Trigger:** inspect the open source or binary and apply the included XOR decode routine.
- **Confidence:** high; the test confirms the decoded token format.
- **Source-level reproduction:** execute the deterministic byte transformation mentally or in an isolated read-only calculation; no network request was made.
- **Missing test/design gate:** client-distributed credentials must be classified as public and limited accordingly; use an unauthenticated public endpoint or user/device-scoped short-lived token.

### P2-10 - Windows release metadata can diverge from the binary version and create update loops

- **Files/lines:** `scripts/build_tauri_windows_release.ps1:1-7,49-107,146-161`; version sources `tauri-app/package.json:4`, `tauri-app/src-tauri/Cargo.toml:3`, `tauri-app/src-tauri/tauri.conf.json:4`.
- **Impact:** filenames and `latest-windows.json` can advertise version X while the built executable still embeds Y. If X > Y, clients can repeatedly offer/install the same older binary.
- **Trigger:** invoke the script with a version that was not identically updated in all three manifests/tag; the script performs no consistency check.
- **Confidence:** high.
- **Source-level reproduction:** trace `-Version 0.7.3` while manifests remain 0.7.2; build inputs do not consume the parameter, but output names/metadata do.
- **Missing test:** release preflight asserting tag, PowerShell parameter, npm, Cargo, and Tauri versions match before building.

### P2-11 - The release path does not execute the existing Rust or frontend tests

- **Files/lines:** `tauri-app/package.json:6-14`; `scripts/build_tauri_windows_release.ps1:109-143`; representative source-text tests `tauri-app/src/app/tauriCommandThreading.test.mjs:1-27` and `tauri-app/src/app/surfaceState.test.mjs:366-402`.
- **Impact:** 195 Rust and 265 Node test cases can all regress while the release script still succeeds. Many frontend tests assert source substrings/wiring, so even when manually run they do not exercise hooks, IPC ordering, cancellation, or native surfaces.
- **Trigger:** normal release build; no `test` package script, `node --test`, or `cargo test` invocation exists in the reviewed production/release path.
- **Confidence:** high.
- **Source-level reproduction:** follow the package and release script commands; they perform typecheck/Vite/Tauri build only.
- **Missing test:** a release-gating command that runs both suites, plus behavioral hook tests and Windows/macOS integration tests for the findings above.

### P2-12 - Unavailable quota is encoded and rendered as real 0% remaining

- **Files/lines:** `tauri-app/src-tauri/src/core/quota/rate_limits.rs:6-28`; `tauri-app/src/components/QuotaStrip.tsx:31-40`; `tauri-app/src/utils/quota.ts:5-8`; compact merge `tauri-app/src/surfaces/useCompactPanelData.ts:71-81`.
- **Impact:** startup, source-switch, timeout, auth failure, and offline states can look like exhausted 5h/7d quota, particularly in compact surfaces that do not show detailed diagnostics.
- **Trigger:** any placeholder/failure bundle before a successful quota read.
- **Confidence:** high.
- **Source-level reproduction:** pass the placeholder through `QuotaBar`/`compactQuotaLabel`; it emits `0%` plus a pending/reset label.
- **Missing test:** unavailable quota must have an explicit nullable/status representation and must never render as measured zero.

### P3-01 - Provider backup IDs collide within the same second

- **Files/lines:** `tauri-app/src-tauri/src/core/provider_repair/backups.rs:29-35,246-251`.
- **Impact:** a second backup reuses and overwrites the first directory/manifest instead of creating a distinct recovery point; cross-process Tauri/Swift use of the shared backup root increases the chance.
- **Trigger:** two backups in one local-clock second.
- **Confidence:** high.
- **Source-level reproduction:** evaluate `timestamp_id()` twice within one second.
- **Missing test:** collision-resistant IDs and create-new semantics.

### P3-02 - Unread acknowledgement persistence is a non-atomic, unbounded read-modify-write

- **Files/lines:** `tauri-app/src-tauri/src/core/unread.rs:31-42,64-106`.
- **Impact:** interruption or competing app instances can corrupt/lose acknowledgements and resurrect read notifications. Stored thread IDs/completion markers are never pruned, so the file grows with lifetime usage.
- **Trigger:** simultaneous acknowledgement or process interruption during `fs::write`.
- **Confidence:** high for persistence properties; ordinary single-window frequency is low.
- **Source-level reproduction:** trace two readers extending different IDs and writing in opposite order, or a truncated JSON read falling back to empty.
- **Missing test:** atomic replacement, multi-writer merge, corrupt recovery, and retention/pruning.

### P3-03 - Compact live-stream start failure can be overwritten by the parallel fallback read

- **Files/lines:** `tauri-app/src/surfaces/useCompactPanelSnapshot.ts:137-176`.
- **Impact:** compact UI can hide that streaming failed and display an ordinary fallback snapshot, removing the retry/failure signal.
- **Trigger:** `startLiveRateStreamCommand` fails first while the independently launched `readLiveRateSnapshot` resolves afterward.
- **Confidence:** high for promise ordering.
- **Source-level reproduction:** resolve the start promise to failure, then resolve the read promise; the second `setRawSnapshot` wins.
- **Missing test:** controlled promise-order tests and a single authoritative startup state machine.

### P3-04 - A second Windows launch cannot recreate a destroyed dashboard window

- **Files/lines:** `tauri-app/src-tauri/src/platform/windows.rs:23-65`; recreate-capable Tauri path `tauri-app/src-tauri/src/platform/surfaces.rs:132-142,391-421`.
- **Impact:** double-clicking the app can exit silently without reopening the dashboard when the first process remains alive via tray/hidden floating window but its main native window was closed. The user must know to use the tray.
- **Trigger:** close/destroy `main`, keep the first process alive, then launch again. The second instance only searches for a Win32 window by title and exits when the mutex already exists.
- **Confidence:** medium-high; exact close/keep-alive behavior needs Windows runtime confirmation.
- **Source-level reproduction:** compare the Win32 activation path, which cannot call `create_dashboard_window`, with the tray path, which can.
- **Missing test:** Windows single-instance IPC that instructs the existing Tauri process to create/show/focus `main`.

## Suspected issues requiring runtime or external-schema confirmation

1. **Quota history can fabricate long 100% spans after reset.** `quota_history/series.rs:184-203` returns `Some(1.0)` for every bin after a stale row's reset without the 90-minute carry limit used when reset metadata is absent. This may display days of inferred full quota after the app was offline. Confirm desired provenance semantics against product requirements.
2. **Provider config parsing is not TOML-safe.** `provider_repair/target_provider.rs:40-60` uses prefix and quote splitting, so similarly prefixed keys, section-local assignments, single quotes, or valid TOML edge cases can select the wrong destructive target. Confirm real Codex config variants and replace with a TOML parser.
3. **Windows installers appear updater-signed but not Authenticode-signed.** `tauri.conf.json:19-43` and the PowerShell script require the Tauri updater key but declare/check no Windows certificate. Confirm actual external signing stage and SmartScreen expectations.
4. **Recursive session discovery follows directory symlinks without cycle detection.** Usage, unread, and Provider collectors use recursive `is_dir`/metadata traversal. A symlink cycle inside a selected Codex Home could recurse indefinitely; confirm whether Codex can create or users can select such trees.
5. **Shared `CodexTokenBar/settings.json` may have cross-lane schema/write conflicts.** Tauri deliberately uses the non-Tauri support directory for settings while its cache/unread files use `CodexTokenBarTauri`. Swift source was outside this Tauri audit, so preservation of unknown Swift fields and simultaneous writer behavior remains unverified.

## Rejected false positives and positive safety conclusions

1. **No reset-card consumption write was found.** `core/quota/reset_credit.rs` performs authenticated GET inventory reads only; no consume/redeem/reset mutation endpoint is registered or called.
2. **Ordinary usage/live/unread scans open Codex SQLite databases read-only.** Writes to Codex-owned data are confined to the explicitly user-triggered Provider repair path; quota history writes to the app's own database.
3. **Main Provider commands are window-label guarded.** Scan, backup, sync, verify, and rollback call `require_window_label` and reject floating/status callers.
4. **Backup ID path traversal is rejected.** IDs containing slash, backslash, or `..` fail before joining the backup root.
5. **The sharded token-event directory does not share the Windows rename-over-existing defect.** It explicitly removes the destination directory before renaming; its crash window is a rebuildable cache-loss risk, not a failure to replace.
6. **Quota success cache is source-keyed.** A successful account quota bundle is not directly reused for a different Codex Home; the confirmed leak is the separately global history query on new-source failure.
7. **Usage aggregate/event caches include Codex Home identity.** Normal source separation exists in the parser caches; the confirmed source problem is UI lifecycle/event invalidation.
8. **Updater artifacts are cryptographically checked by Tauri.** The config pins a public updater key and the release script requires/copies `.sig`; findings concern version/test/release integration, not absence of Tauri updater signatures.
9. **Radar RSS URL is not an unrestricted renderer fetch in the shipped CSP.** `connect-src` allowlists only the expected Radar endpoints, limiting a malicious payload's ability to redirect feed fetches to arbitrary hosts.

## Test quality assessment

Strengths:

- Rust tests cover token delta/fork parsing, incremental caches, quota parsing/history normalization, unread filtering, Provider happy paths, command label policy, and several platform capability decisions.
- Frontend tests cover pure chart/ranking/quota/radar models and SSR presence/ARIA for major dashboard surfaces.
- The source has explicit fallback diagnostics and uses source identities in the heavy usage caches.

Weaknesses:

- Neither test suite is wired into the package or Windows release script.
- A substantial frontend subset reads source text and asserts substrings; these tests can pass while lifecycle ordering, IPC failure, and UI behavior are broken.
- No test owns a real live-stream task, Tauri event bus, request cancellation, multi-webview subscriber, or source-switch generation.
- Windows filesystem replacement semantics are not tested for Provider/settings/cache persistence.
- Provider tests exercise direct core happy paths and omit sentinel target selection, WAL backup/restore, stale backups, operation overlap, and active Codex writers.
- Usage tests omit archived-session preservation and trailing-zero current streaks.
- Quota tests omit two-account failure history provenance and unavailable-vs-zero rendering.
- Native tray/window reachability, close/reopen, autostart arguments, updater install, and Windows/macOS behavior have no integration harness in the reviewed lane.

## Uncovered areas

- **Requested tracked Tauri source/tests:** no known production module was intentionally skipped.
- **Runtime-only behavior:** not verified because builds and app launches were prohibited: actual Windows/macOS window focus/close semantics, DPI/multi-monitor placement, transparent rendering, tray title support, autostart startup visibility, CPU/disk/network measurements, and native updater installation/relaunch.
- **External state:** Codex CLI/app-server schema drift, live Codex SQLite/WAL timing, reset-credit/Radar response variants, Radar credential scope, and GitHub `latest-windows.json`/release asset availability were not queried.
- **Generated/artifact state:** compiled bundles, generated Tauri schemas, installer signatures, Authenticode status, target binaries, and remote checksums were not inspected because they are absent from tagged production source or require building/downloading.
- **Non-Tauri lane:** Swift production source was not audited. The shared appcast was read only to establish that macOS Swift and Windows Tauri use separate updater lanes; cross-lane shared settings/backup compatibility remains open.
- **Historical review material:** all other audit reports and reviewer/tool outputs remain intentionally unread.
