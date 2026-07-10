# Commander Core-Flow Review

Status: in progress. This report records Commander findings formed independently of worker and tool reports.

## Findings

### [P1] Tauri Codex Home changes do not invalidate already-open compact surfaces

**Commander validation**

- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src/state/useDashboardActions.ts:124` saves or resets Codex Home and reloads only the main dashboard state. It does not publish the shared app-settings event.
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src/floating/FloatingWindowApp.tsx:110` and `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src/status/StatusPanelApp.tsx:68` update their source key only from the missing event or their first settings read.
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src/surfaces/useCompactPanelQuota.ts:15` has no source/generation input at all, so it retains old-account quota state across a source switch.

**Impact**

After switching Codex Home in the dashboard, an already-open floating or status surface can label old-home totals and quota as if they belong to the newly selected source until later reads happen to replace them. This is a cross-account correctness issue, not merely a stale timestamp.

**Required target**

Publish the resolved canonical Codex Home after both save and auto-reset, and make usage, quota, unread, and live-rate compact state source-generation aware. A two-home integration fixture must prove immediate invalidation and reject late completions from source A after switching to B.

The main dashboard has the same propagation gap: `reloadInitialSnapshot` reloads only the fast snapshot, while the precise usage, quota, and live-thread loaders guard on generations that are not incremented by the Home-change action. The repair fixture must therefore cover main plus floating/status, not only the compact event.

### [P1] Tauri ProviderRepair backup/rollback is not a consistent SQLite snapshot

**Commander validation**

- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/provider_repair/backups.rs:36` copies the main SQLite file and then separately copies WAL/SHM; WAL/SHM copy failures are ignored.
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/provider_repair/backups.rs:117` restores only the main database and deletes the live WAL/SHM. The backed-up WAL is never replayed or restored.
- Swift already uses `VACUUM main INTO ?` at `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/Sources/CodexTokenBar/ProviderSyncEngine+Backups.swift:43`, producing a self-contained SQLite snapshot before writes.

**Impact**

A backup created while Codex has committed rows in WAL can omit those rows from the main-file copy. Rollback then deletes sidecars and permanently loses the omitted committed data. The UI recommendation to exit Codex is not a consistency guarantee.

**Required target**

Use SQLite online backup or a self-contained `VACUUM INTO` equivalent on both supported platforms, fail the backup if a consistent snapshot cannot be created, and add a WAL-mode fixture with uncheckpointed committed rows plus integrity verification.

Backup IDs also use only a second-resolution timestamp in Tauri. The new backend operation should use a collision-resistant suffix, matching Swift's timestamp-plus-UUID policy.

### [P1] ProviderRepair timeout ends only the frontend operation, allowing overlapping Rust writes

**Commander validation**

- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src/api/providerRepairClient.ts:17` applies 60-second Promise timeouts to destructive commands.
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src/platform/runtime.ts:5` races the Promise but cannot cancel the Rust command.
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src/components/ProviderRepairCard.tsx:105` clears the card-local busy state after the rejected timeout.
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/commands/provider_repair.rs:27` and the core operations have no backend operation gate.

**Impact**

If a large backup/sync exceeds the frontend timeout, the user can start a second sync or rollback while the first Rust operation is still mutating JSONL/SQLite/index files.

**Required target**

Serialize destructive operations in Rust per canonical Codex Home and surface timeout as an uncertain still-running state, not idle. Add a controlled blocked-operation test that proves a second command is rejected or joins the first.

### [P1] Tauri sync reuses an arbitrary older backup despite promising a fresh pre-sync backup

- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src/components/ProviderRepairCard.tsx:88` selects an existing backup and passes its ID into sync.
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/provider_repair.rs:42` validates that old backup but does not create a new one before mutation.
- Swift creates a fresh backup at the start of every sync in `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/Sources/CodexTokenBar/ProviderSyncEngine.swift:114` and automatically restores it on failure.

**Impact**

The visible promise that every sync has a complete safety point is false; rollback may discard valid changes made after the selected old backup.

**Required target**

Move fresh backup creation into the same backend-gated sync operation and return that backup as the rollback point. A failed backup must prevent all mutation.

### [P1] Tauri settings updates can lose fields and expose partial JSON

- Every setter in `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/platform/settings.rs:16` performs an independent read-modify-write of the complete settings object.
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/platform/settings.rs:82` writes directly to the destination file without a shared lock or temp-file rename.

**Impact**

Floating-position saves and dashboard setting changes can race: both read the old snapshot, and the later full-file write silently restores the earlier value of the other field. A reader can also observe truncated JSON during an overwrite.

**Required target**

Use one process-wide settings lock, perform field mutation under that lock, and commit with a unique temp file plus atomic rename. Add concurrent field-update and parse-during-write tests.

### [P1] Tauri quota cadence options below five minutes are masked by a fixed backend success cache

**Evidence**

- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/quota.rs:20` sets `SUCCESS_CACHE_TTL` to five minutes.
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/quota.rs:170` reuses a successful cached result for that TTL whenever `force_refresh` is false.
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src/state/useDashboardData.ts:321` advances the dashboard quota generation at the selected UI cadence without setting `forceNextQuotaLoad`.
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src/surfaces/useCompactPanelQuota.ts:53` and `:56` also perform initial/interval reads with `forceRefresh = false`.
- The selectable values include 30 seconds, 1 minute, and 3 minutes, all shorter than the fixed five-minute backend cache.
- Swift's `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/Sources/CodexTokenBar/AccountQuotaStore.swift:133` performs an actual reader refresh after a cadence-derived cooldown; `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/Sources/CodexTokenBar/AccountQuotaRefreshCadence.swift:38` deliberately keeps the 30-second option from being swallowed by a fixed cooldown.

**Impact**

On Tauri, choosing 30 seconds, 1 minute, or 3 minutes usually polls the Rust cache rather than Codex app-server. Visible quota can therefore remain unchanged for roughly five minutes while the UI claims a shorter refresh interval. Swift and Tauri do not implement the same user setting.

**Required reproduction before repair**

Add a backend/loader test with a counted fake quota loader: successful read at T0 followed by automatic ticks at the five configured intervals. The selected cadence must control the maximum accepted age of a real quota read, while simultaneous dashboard/floating/status requests coalesce into one process read.

**Repair caution**

Blindly changing every timer tick to `force=true` can make the independently phased dashboard and floating timers start duplicate app-server processes. Prefer one shared backend freshness policy or a single coordinator keyed by Codex Home and selected cadence; manual refresh must remain genuinely forced, and in-flight calls must still coalesce.

### [P1] Tauri drops trusted compact usage at local-day or UTC-offset changes

**Evidence**

- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/usage/token_count_jsonl.rs:303` defines the lightweight trusted-summary scope as Codex Home + local date + UTC offset.
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/usage/token_count_jsonl.rs:319` returns a trusted summary only when the entire scope matches.
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/usage/token_count_jsonl.rs:155` performs a full signature check, schedules a background aggregate rebuild, and returns an error when there is no matching-scope summary.
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/usage/token_count_jsonl/tests.rs:984` explicitly locks rejection of the previous summary after a date or offset change, but does not assert a non-pending transformed fallback.
- Swift keeps a precise `CodexUsageStore.snapshot`; `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/Sources/CodexTokenBar/TokenDisplaySurface.swift:183` derives the current day from that retained precise snapshot, so a missing new-day bucket becomes zero without downgrading total/today/request to pending.

**Impact**

At local midnight, or after a timezone/DST offset change, a continuously running Tauri app can show `总/今/次 待读取` until the background full scan completes. This violates the accepted product invariant that pending usage labels are allowed only at the first cold start or a genuine local read failure. It also diverges from Swift.

**Required reproduction before repair**

Add a deterministic Rust/model fixture with a trusted pre-midnight aggregate and an after-midnight request. The target state should preserve total, reset today/request to values derivable for the new day (initially zero when no new-day event has been observed), schedule one rebuild, and replace the transformed summary after rebuild. Add an offset-change case and decide whether it follows the same transformation or requires an immediate precise recomputation.

**Repair caution**

Do not simply reuse yesterday's full summary: that would keep stale today/request values. Split source identity from calendar projection, or preserve only fields whose semantics remain valid while the new-day aggregate rebuilds.

### [P1] Tauri permanently suppresses an acknowledged thread ID even after it leaves and later re-enters Codex unread state

**Evidence**

- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/unread.rs:18` subtracts the persisted acknowledged thread-ID set from every current native unread set.
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/unread.rs:31` only extends that acknowledged set. No read path intersects/prunes it against the current Codex unread set.
- Existing coverage at `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/unread.rs:231` proves a different later thread becomes visible, but does not cover `A acknowledged -> native set empty -> A unread again`.
- Swift explicitly calls `acknowledgedUnreadThreadIDs.formIntersection(threadIDs)` at `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/Sources/CodexTokenBar/TaskCompletionReadBaseline.swift:7`, so an ID that leaves the native unread set can become new again later.

**Impact**

After one-click mark-all-read, any previously acknowledged Tauri thread can remain invisible to Token Bar forever, even if the user later clears it in Codex and a genuinely new unread completion re-adds the same thread ID. The persisted set also grows without a lifecycle bound.

**Required reproduction before repair**

Add a Tauri state-sequence test: unread `{A}`, acknowledge, unread `{}`, then unread `{A}`. The last state must be active. Persisted pruning must remain scoped by canonical Codex Home and must not mutate Codex's own unread-state file.

### [P2] Both lanes miss new completion events while an acknowledged thread remains continuously native-unread

**Evidence**

- Swift skips the JSONL completion scan whenever native Codex unread state is available at `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/Sources/CodexTokenBar/TaskCompletionMonitor.swift:118` and counts only native unread thread IDs at `:189`.
- Tauri uses recent `task_complete` markers only when native unread state is unavailable at `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/unread.rs:14`.
- Both baselines can distinguish completion event/turn IDs, but that information is not consulted while native unread state is available.

**Impact**

If mark-all-read is only an app-side baseline and Codex continues to expose thread A as unread, a later task completion in the same thread does not change the native unread ID set. Token Bar can therefore keep suppressing A even though a genuinely new unread completion occurred after the baseline.

**Status**

The control-flow gap is confirmed; the real Codex state transition needs a fixture/runtime trace to establish how often a thread remains continuously unread. The target state should combine native unread identity with post-baseline completion markers without double-counting or notifying for subagents.

### [P2] Tauri status-panel close/reopen discards its in-memory usage presentation

**Evidence**

- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src/status/StatusPanelApp.tsx:113` marks the panel inactive when hidden or blurred.
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src/surfaces/useCompactPanelSnapshot.ts:73` clears `usageSummaryRef`, the visible snapshot, and live activity whenever `active` is false.
- Reopening makes `active` true and starts an asynchronous summary read; the first render therefore has the empty/pending snapshot even when the process already owns a trusted summary.
- Swift compact/status surfaces are projections of the long-lived `CodexUsageStore.snapshot`, rather than panel-local ownership of the trusted totals.

**Impact**

Opening the Tauri status panel can briefly flash pending total/today/request labels on every reopen. The backend C26 O(1) cache makes the flash short, but it is still a lifecycle mismatch and can become visible under WebView scheduling or command delay.

**Status**

Suspected until a rendered lifecycle test or runtime capture reproduces the flash. The likely target is to stop polling/stream work while inactive without destroying the last trusted usage projection; a Codex Home change must still clear cross-source data.

### [P2] Both quota readers can back-pressure on an undrained stderr pipe

**Evidence**

- Tauri configures `stderr(Stdio::piped())` at `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/quota.rs:608`, but only drains it after the deadline and child cleanup at `:692`.
- Swift configures a separate error `Pipe` at `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/Sources/CodexTokenBar/AccountQuotaReader.swift:96`, but reads it only after timeout/termination at `:184`.
- Both implementations drain stdout concurrently while leaving stderr bounded until completion. A sufficiently noisy app-server can fill the OS pipe and block before emitting the quota response.

**Impact**

Plugin/model warnings or future app-server logging growth can turn an otherwise healthy quota read into repeated 12-second timeouts. Existing timeout classification preserves the diagnostic category, but it does not prevent the process-level stall.

**Status**

Structurally confirmed risk; user-visible reproduction still needs a fake child/process seam that writes more than pipe capacity to stderr before returning JSON-RPC id 2. The target state is continuous bounded stderr draining with captured tail text retained for timeout diagnostics.

### [P2] A running Tauri app does not check again when a new release is published

**Evidence**

- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src/app/DashboardApp.tsx:132` schedules one silent update check five seconds after `DashboardApp` mounts.
- That effect has no interval, focus, wake, or visibility listener. The remaining update path at `:183` is user-triggered.
- Swift starts Sparkle through `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/Sources/CodexTokenBar/CodexTokenBarApp.swift:13` and exposes Sparkle's automatic-check setting through `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/Sources/CodexTokenBar/AppUpdateSettingsStore.swift:26`.

**Impact**

Users who leave the Tauri app running do not receive an in-app update reminder for a release published after that one startup check. They must restart/remount the dashboard or manually check. This does not satisfy the requested publish-to-reminder behavior and diverges from Swift.

**Required target-state decision**

Choose a bounded automatic policy, such as startup plus wake/focus and a several-hour minimum interval, persisted by last-attempt time so multiple surfaces cannot spam the endpoint. Update availability should be surfaced without an automatic install prompt during background checks; manual check/install behavior stays explicit.

### [P2] Quota history identity can collide across different accounts with the same display name and plan

- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/quota/auth.rs:21` extracts a display label but not a stable JWT subject/account ID.
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/quota_history.rs:186` keys history with account display name, plan, and `codex`, not a stable account identity or source.

**Impact**

Two Codex Homes signed into accounts with the same name and plan can merge/select each other's quota history while current quota remains source-correct.

**Repair caution**

This requires an explicit identity migration. Add stable subject/source fields for new rows while preserving a bounded, documented legacy bridge; do not silently strand existing history or merge by display name indefinitely.

### [P2] Swift and Tauri write incompatible plan identities into their shared quota-history database

- Both lanes use the same `Application Support/CodexTokenBar/quota-history.sqlite` path.
- Swift's `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/Sources/CodexTokenBar/QuotaHistoryStore.swift:758` canonicalizes every readable Codex plan to `Pro|codex`.
- Tauri's `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/quota_history.rs:186` records the actual canonical Plus/Pro/Team/Enterprise plan, following the accepted no-fake-Pro behavior.

**Impact**

Alternating Swift and Tauri on a Plus/Team account splits one physical history into incompatible keys, so charts can appear discontinuous or platform-dependent even though both test suites pass separately.

**Required target**

Define one shared versioned identity schema using stable account ID plus actual plan and source scope. Add a cross-language fixture that alternates writes/reads for Plus, Pro, Team, unknown plan, and plan transitions; migrate or bridge old Swift fake-Pro rows explicitly.

### [P2] Tauri's scrollable 30-day five-minute usage chart has only 24 hours of quota overlay

- Tauri usage `recent_usage_24h` now contains `30 * 24 * 12` five-minute points at `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/usage/token_count_jsonl/aggregates.rs:7`.
- Tauri quota `recent_24h` remains 289 points at `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/quota_history.rs:23`.
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src/state/dashboardMergers.ts:106` overlays only exact matching timestamps, leaving the prior 29 days without quota lines.

**Impact**

The user can scroll through 30 days of usage, but the 5h/7d quota evidence disappears after the newest day. Swift supplies the long usage/quota timeline together.

**Required target**

Make the long-chart usage and quota series share one explicit horizon/bucket contract and a tested carry/interpolation policy. Do not merely rename `recent_24h`; fix backend generation, merge, selection, and estimator inputs together.

### [P2] Swift does not match the accepted always-visible mark-all-read control

- Tauri always renders the dashboard `一键已读` control and changes its tone with unread state at `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src/components/LiveRateCard.tsx:103`.
- Swift renders the dashboard `全部已读` button only when `unreadThreadCount > 0` at `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/Sources/CodexTokenBar/DashboardHeaderView.swift:164`.
- Both compact status panels also hide their action when there is no unread state, so the cross-surface target is not yet documented.

**Impact**

The Swift dashboard cannot be used to deliberately reset a phantom/uncertain baseline when the visible count is zero, and the two lanes present different affordance/state semantics.

**Required UI decision**

Lock the accepted target in the parity matrix: the primary dashboard control remains present in both lanes, active blue when unread and quiet gray when idle. Decide separately whether compact status panels need the same always-visible action or may remain conditional for space.

### [P2] Windows release script contradicts the accepted Mac-side updater-key custody flow

- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/scripts/build_tauri_windows_release.ps1:86` requires the long-lived updater private key on Windows.
- The v0.7.2 release ledger records the opposite accepted flow: build unsigned installers on Windows and sign updater artifacts on Mac after transfer.

**Impact**

The next maintainer cannot reproduce the accepted release by following the repository's primary script/README; they may copy the private key to Windows merely to satisfy the script.

**Required target**

Make the Windows script produce reviewed unsigned installers plus a manifest without the private key, and provide a Mac-side signing/metadata step with hash and architecture checks.

### [P2] Tauri unread baseline persistence is not atomic and silently resets on corruption

- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/unread.rs:88` maps malformed JSON to an empty acknowledgement with no diagnostic.
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/unread.rs:98` overwrites the file directly without a mutex or temp-file rename.

**Impact**

A crash or concurrent write can make all acknowledged sessions appear unread again and can lose one Codex Home's update while acknowledging another.

**Required target**

Reuse the settings-style atomic persistence helper after that helper is fixed, keep a bounded corrupt-file backup/diagnostic, and test concurrent A/B Home acknowledgements plus a truncate fault.

### [P2] The macOS Tauri debug surface exposes an unsupported Windows-updater error as raw header text

**Runtime and source evidence**

- The current Tauri dashboard capture at `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/audits/v0.7.2/screenshots/01-tauri-dashboard-baseline.jpeg` shows `检查更新失败：None of the fallback platforms ...` inline between the update and export buttons.
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/tauri.conf.json:38` points the Tauri updater exclusively at `latest-windows.json`.
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src/app/DashboardApp.tsx:225` prefixes and forwards the plugin's full error message, while `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src/components/DashboardHeader.tsx:137` places that unbounded message in the already dense source/action row.

**Impact**

The macOS comparison/debug build offers an update command that can never resolve a Darwin platform from the Windows-only metadata, then presents internal updater vocabulary as product copy. The header becomes crowded and visibly truncates both status and neighboring actions.

**Required target**

Make platform support explicit. If the Tauri updater remains Windows-only, hide/disable the update action on unsupported platforms and show no startup error. On supported platforms, map updater failures to bounded user-facing categories in a stable status slot, with raw detail available only through diagnostics.

### [P2] Tauri exposes every heat-map day as a separate accessibility control

**Runtime and source evidence**

- The current accessibility snapshot presents one toggle for every daily cell, producing hundreds of sequential controls before the chart/ranking content.
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src/components/tokenActivity/HeatmapGrid.tsx:27` maps every day to a `<button>` with `aria-pressed`.
- Swift deliberately combines its heat map into one accessibility element at `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/Sources/CodexTokenBar/TokenHeatmap.swift:165`.

**Impact**

Keyboard and screen-reader users must traverse roughly a year of cells to reach later analytics. The labels are individually descriptive, but the interaction model is not scalable.

**Required target**

Expose the heat map as one grouped chart with a concise summary and a deliberate keyboard point-selection mode, or implement a roving single tab stop. Preserve pointer range selection without making every cell a permanent tab stop.

### [P1] Tauri Provider repair can propagate the literal `(missing)` sentinel as a real provider

- `tauri-app/src-tauri/src/core/provider_repair/sqlite_state.rs:211` converts an empty SQLite provider into `(missing)`.
- `tauri-app/src-tauri/src/core/provider_repair/target_provider.rs:16` then prioritizes the newest SQLite provider over a valid JSONL fallback.
- The resulting ordinary `String` reaches the JSONL and SQLite write paths without a validity gate.

**Impact**

An advanced repair intended to normalize provider metadata can write `(missing)` across active history. Add a red fixture with empty newest SQLite provider plus valid JSONL provider, and make “missing” an absence state rather than a serializable provider value.

### [P1] Swift source switching does not reset the live monitor and can relabel old snapshots as the new source

- `Sources/CodexTokenBar/DashboardView.swift:297` updates task completion and quota source state, but does not call the existing `LiveRateMonitor.setDataSource` boundary.
- `CodexUsageStore` changes its current source identity before a new-source load succeeds, yet retains the previous displayable snapshot on failure.
- `AccountQuotaStore.setDataSource` cancels generations but does not clear the previous snapshot; failure preservation and normalization can therefore continue from old-source values.

**Impact**

After Codex Home A -> B, Swift can combine B's source label/path with A's usage, quota, selected thread, offsets, or fingerprints. The repair must coordinate all source-owned stores from one transition and either retain data explicitly as “old source” or clear it; it must never relabel it as B.

### [P1] Swift Provider mutations and rollback remain enabled while Codex is running

- `Sources/CodexTokenBar/ProviderSyncEngine.swift:231` detects a running Codex application and the UI only appends an advisory “建议退出” status.
- Destructive sync and rollback actions do not hard-disable on `codexRunning`, and the engine itself has no final process-open guard immediately before mutation.
- The same files and SQLite database can therefore be written concurrently by Codex and Token Bar.

**Impact**

This defeats the consistency assumptions of backup, rewrite, and rollback. Add engine-level rejection plus UI state tests; do not rely on advisory copy or a stale scan result.

### [P2] Tauri Provider and aggregate replacement uses Unix rename semantics on Windows

- `tauri-app/src-tauri/src/core/provider_repair/session_files.rs:136`, `core/usage/cache_lifecycle.rs:38`, and `core/usage/token_count_jsonl.rs:511` rename a temp path over an existing destination.
- On Windows, `std::fs::rename` does not replace an existing file. Provider sync fails on the first mismatching JSONL, while cache-state and aggregate persistence can fail silently after their first write.

**Impact**

The main Windows lane either cannot perform Provider repair or repeatedly rebuilds caches. Introduce one tested cross-platform atomic-replace helper with cleanup and surfaced errors.

### [P2] Tauri live-stream ownership is a global counter without task generation or subscriber tokens

- `tauri-app/src-tauri/src/commands/live.rs:75` tracks only `subscriber_count` and a global `running` flag.
- A stop followed quickly by a start can set `running=true` before the old loop observes the stop, leaving both loops alive.
- React cleanup in `useLiveRateFeed.ts` / `useCompactPanelSnapshot.ts` calls stop even when its own delayed start never successfully acquired a subscription, so one surface can decrement another surface's ownership.

**Impact**

Multiple background loops can duplicate CPU/IO and event publication, or one surface can stop streaming for another. Repair with per-subscriber leases and a loop generation/handle; test delayed start/unmount and stop-start races deterministically.

### [P2] Tauri recent-rollout discovery cache ignores the SQLite WAL

- `tauri-app/src-tauri/src/core/live_rate/rollout.rs:127` signs only `state_5.sqlite` length and modification date.
- `recent_rollout_threads` returns the cached thread list indefinitely while that main-file signature is unchanged.
- A new thread committed only to `state_5.sqlite-wal` is therefore invisible until checkpoint.

**Impact**

Live rate can stay on an old thread or at zero during active work. Include WAL identity and a bounded TTL in invalidation, with a WAL-only insertion fixture.

### [P2] Tauri can attach the previous account's quota history to a failed new-source read

- `tauri-app/src-tauri/src/core/quota.rs:232` builds a failure bundle for the newly selected source.
- `refresh_quota_histories` then calls the global `history_bundle(365)` without source/account identity.
- `QuotaHistoryDatabase.history_bundle` selects rows from the global database rather than the attempted account.

**Impact**

If B fails before recording a trusted row, B's failure surface can show A's historical chart. Make history reads identity-scoped and return no history when the new identity is not established.

### [P2] Tauri `currentStreakDays` reports an old streak after inactivity

- `tauri-app/src-tauri/src/core/usage/token_count_jsonl/aggregates.rs:168` skips all trailing zero days while `streak == 0`, then counts the first older non-zero run.

**Impact**

The dashboard can call a weeks-old streak “current”. Add trailing-zero fixtures and define the accepted today/yesterday grace explicitly before changing the algorithm.

### [P2] A hidden or disabled Tauri floating webview keeps background work active

- `FloatingWindowApp` calls `useCompactPanelData` without an `active` value, so it defaults to `true`.
- The mounted hidden window continues usage-summary reads, quota timers/wake refreshes, live-rate subscription, unread listeners, and a ten-minute Radar timer.
- On Windows the floating webview is created hidden at startup, so this work can begin before the user enables the surface.

**Impact**

The “off” surface still consumes CPU, disk, child-process, and network resources. Propagate real native visibility/enabled state and quiesce effects without discarding the last trusted presentation.

### [P2] Tauri's macOS status panel is implemented but unreachable, while tray live text is dashboard-owned

- `create_status_tray` routes both the tray click and its only open item to `show_dashboard_window`.
- CodeGraph finds no production caller for `show_status_panel_window`.
- `useStatusTray` is mounted through the dashboard hook, so destroying/removing that webview also removes the owner that updates tray text.

**Impact**

The advertised independent status surface cannot be opened and tray rate text can freeze when the dashboard is gone. Native tray ownership and status-panel reachability need a runtime-backed design, not another source-string test.

### [P2] Tauri represents unavailable quota as a measured 0% value

- `tauri-app/src-tauri/src/core/quota/rate_limits.rs:6` creates placeholder 5h/7d limits with `remaining_percent = 0.0`.
- `useCompactPanelData` and quota label helpers pass those values into normal bars/labels.

**Impact**

Startup, timeout, source-switch, and offline states can look like exhausted quota. Add an explicit availability/provenance state or nullable limits; “unknown” must never be encoded as a real zero.

### [P2] Tauri Provider target parsing is not TOML-safe

- `tauri-app/src-tauri/src/core/provider_repair/target_provider.rs:40` uses line prefix matching and quote splitting instead of a TOML parser.
- Keys such as `model_provider_backup`, section-local assignments, valid single-quoted strings, and escaped/commented values can select the wrong destructive target.

**Impact**

Provider repair can normalize history to an unintended value. Parse the structured top-level key with the existing language ecosystem and add representative TOML fixtures before any write-path change.

### [P2] Recursive session collectors can follow directory-symlink cycles

- `tauri-app/src-tauri/src/core/provider_repair/session_files.rs:37` calls `fs::metadata`, which follows symlinks, then recursively descends every directory without canonical visited-set or root-boundary checks.
- Similar recursive collectors must be audited together so usage, unread, and Provider behavior do not diverge.

**Impact**

A selected Codex Home containing a symlink loop can recurse indefinitely or leave the intended tree. Standardize bounded, non-following traversal with canonical-root containment tests.

### [P2] Swift task-completion scanning consumes an incomplete final JSONL record

- `Sources/CodexTokenBar/TaskCompletionScanner.swift:160` splits the full appended chunk even when the final record has no newline.
- It then unconditionally advances `state.offset` to the current file size at `:224`.

**Impact**

When Codex finishes writing that partial line later, the scanner starts after its prefix and permanently misses the completion. Preserve the incomplete tail/offset and add two-phase append tests.

### [P2] Swift quota source cancellation does not stop the synchronous app-server read

- `AccountQuotaStore` cancels the surrounding Task/generation on source change, but `AccountQuotaReader.readOnce` is synchronous and has no cancellation checks while waiting up to 12 seconds.
- Retry sleep uses `try?`, so cancellation is swallowed and another attempt can still begin.

**Impact**

An old-source child process can continue after a source switch, delaying resources and complicating publication guards. Extract a cancellable process/stdio seam, terminate the child on cancellation, and stop retries immediately.

### [P2] Swift stream/rollout dedupe uses incompatible identities for the same visible output

- Stream deltas fingerprint item IDs plus delta text, while rollout `agent_message` events fingerprint timestamp plus full text.
- The rollout suppressor can retain an earlier `agent_message` and discard a later response-item representation, so the stream and rollout identities cannot match.

**Impact**

The same assistant output can count twice when both sources are active. Add a cross-source fixture for `agent_message` plus streamed response-item text and define a shared normalized identity without collapsing genuinely distinct repeated text.

### [P2] Swift does not invalidate a cached log reader when `logs_2.sqlite` is replaced at the same path

- `LiveRateMonitor` caches the reader by pathname and retains `lastGlobalLogID`.
- `lastLogsSignature` is assigned but not compared to trigger a reset.

**Impact**

After database rotation/replacement, rate rows can be skipped or attributed through stale state. Test inode/signature change at a stable path and reset only source-local log state.

### [P2] Swift keeps native unread state authoritative after it becomes unavailable

- `TaskCompletionMonitor.applyCodexUnreadRead` sets `hasCodexUnreadState = true` only on available reads and never clears it on `.unavailable`.
- Later polls run the fallback scanner, but `apply` still filters and recomputes through the stale native unread state.

**Impact**

A transient corrupt/missing global-state file can make new completion events invisible for the rest of the monitor lifetime. Add available -> unavailable -> fallback-event and recovery sequences.

### [P2] Swift Provider verification failures occur outside automatic rollback

- `ProviderSyncEngine.sync` catches and rolls back only the mutation block through line 148.
- The post-write `makeReport` and verification at `:151` can throw after files have changed, and that error escapes without rollback.
- Verification also treats `allSatisfy` over an empty provider map as success and does not include `invalidSessionFiles` in the success condition.

**Impact**

The UI can report a failed sync after leaving mutations in place, or report success while invalid session files were skipped. Include verification in the transactional recovery boundary and test malformed/empty session sets.

### [P2] Swift Provider tar rollback is not member-scoped to the selected Codex Home

- `createSessionTar` stores paths relative to filesystem root and `restoreBackup` extracts with `tar -C /`.
- The only pre-extraction trust check is a mutable `manifest.json` Codex Home string; archive members themselves are not inspected or constrained.

**Impact**

Normal app-created archives contain session files, but a damaged or modified local backup can overwrite paths outside the selected Home. Validate every member, extract into a staging directory, and restore only known files under the canonical source root.

### [P3] Tauri compact stream-start failure can be overwritten by the parallel initial snapshot

- `useCompactPanelSnapshot` launches `startLiveRateStreamCommand` and `readLiveRateSnapshot` independently.
- A start failure writes a failure snapshot, but a later fallback read unconditionally overwrites it with an ordinary snapshot.

**Impact**

The compact surface can hide a real stream failure. Replace the promise race with one authoritative startup state machine and controlled-order tests.

### [P3] Tauri Provider backup IDs collide within one second

- `timestamp_id()` has second precision and the backup directory is not created with collision rejection.

**Impact**

Two operations in one second can reuse one recovery point. Add random/monotonic uniqueness and `create_new` semantics; this should be fixed as part of the larger Provider transaction batch.

### [P2] Both lanes can report a historical streak as the current streak

- Swift `CodexUsageAnalyzer.currentStreakDays` and Tauri `current_streak_days` both scan backward across unlimited trailing zero-use days until they encounter the most recent positive day.
- Neither implementation has a focused test for the meaning of “current” when today and yesterday are both empty.

**Impact**

A streak that ended days or weeks ago can still be displayed as current. Use one shared target rule in both lanes: count through today when today is active; allow only the ordinary today-empty/yesterday-active grace; otherwise return zero. Add explicit today-active, today-empty/yesterday-active, two-trailing-empty, and historical-streak tests before changing production code.

### [P2] Usage and unread file discovery do not consistently enforce the selected Codex Home boundary

- Tauri usage and unread collectors recurse with `Path::is_dir()`, which follows directory symlinks, without a visited identity set, depth/entry bound, or canonical selected-Home containment.
- Both Swift and Tauri accept absolute `state_5.sqlite.threads.rollout_path` values after checking only that the target is a JSONL file; a stale or retargeted row can therefore mix another Home or arbitrary external file into the selected source.
- Swift's session enumerator and active-rollout dedupe canonicalize paths for identity but do not reject a resolved file outside the selected Home.

**Impact**

A symlink cycle can make Tauri scanning unbounded, and a stale/external rollout path can silently contaminate trusted totals, today/request metrics, unread visibility, and their caches. Define one per-lane bounded, non-following walker and require every resolved session/rollout file to remain under the canonical selected Codex Home. Preserve the valid case where an active rollout is outside `sessions/` but still inside that Home. Add symlink-cycle, symlink-escape, external absolute rollout, internal active-rollout, and normal nested-session fixtures before implementation.

### [P2] Tauri can publish cache-hit rates above 100%

- Swift clamps each event's cached input to its input tokens before accumulating cache usage.
- Tauri ranking output applies that clamp, but `TokenAccumulator::add`, daily activity, and recent usage preserve raw `cached_input_tokens`; `cache_hit_rate`, weighted range summaries, tooltip copy, and cost projections can therefore receive a ratio above `1.0`.
- The current frontend clamps only heat-map color intensity, not the displayed percentage or combined input/cached totals.

**Impact**

A malformed, migrated, or future schema row can render `>100%` hit rate and distort recent-range/cost summaries even though the ranking surface looks correct. Normalize cached input per event at the Rust aggregate boundary, retain a defensive `[0, 1]` clamp in presentation math, and add oversized-cached-input fixtures for daily, recent, range summary, tooltip, and ranking parity. This is a Tauri catch-up to the accepted Swift invariant, not a reason to change Swift.

## Scope Reviewed So Far

- Tauri source/settings, usage/cache, quota/history, live-rate/rollout registry, unread, ProviderRepair, floating/status/tray, Windows replacement/single-instance source, updater/release scripts, and current macOS rendered dashboard evidence.
- Swift source coordination, usage/cache/fork parsing, quota/history, live-rate dual-source behavior, task completion/unread, Provider sync/backup/rollback, floating/status presentation, and current rendered dashboard evidence.
- Automatic tool reports are still pending and do not count as human coverage; their output will only seed additional manual traces.

## Rejected Shortcuts

- Reusing the previous Tauri summary unchanged across midnight is incorrect because today/request would remain yesterday's values.
- Using live-rate totals or SQLite `threads.tokens_used` to avoid pending remains rejected; neither is a trusted source for compact `总/今/次`.
- Treating the backend's quick O(1) response as proof that the status-panel lifecycle cannot flash is insufficient; the React state is explicitly reset before the asynchronous read.

## Accepted Risks / Rejected Findings

- The full-detail Radar bearer material is reversibly obfuscated in the client. This is not being promoted as a defect: the user explicitly accepted light local obfuscation and accepted that a determined person can recover the key. The audit should verify that it is used only for full-detail requests, never public/basic requests, and can be rotated; it should not misrepresent the chosen boundary as secret storage.
- The history report's claim that the two-second fork replay grace is itself a confirmed bug is not accepted. It proves an unavoidable ambiguity and a hypothetical fast-branch loss, but the existing real dense-replay fixture proves that removing or naively shortening the grace reintroduces catastrophic duplicate totals. Keep the current rule until real logs reveal a stable turn/event boundary that distinguishes copied user messages from new branch work; test exact 1.999/2.000/2.001 boundaries only as characterization, not as a license to change behavior.
- Tauri currently omits archived sessions from usage aggregates. The source behavior is confirmed, but changing whether archived conversations count is a product-history policy decision, not a mechanical bugfix. Do not add `archived_sessions` until the target scope, dedupe, cache migration, and Swift parity are explicitly chosen.
- Windows updater metadata living under the unified GitHub `latest` release is currently an accepted unified-release architecture, not a defect by itself. It becomes a bug only if the product adopts independent platform release cadence without first moving Windows metadata to a stable channel URL.
