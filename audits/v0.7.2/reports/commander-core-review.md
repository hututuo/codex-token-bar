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

## Scope Reviewed So Far

- Tauri Codex Home command boundary, aggregate signature, persistent aggregate, trusted-summary scope, background refresh coordinator, compact usage hook, floating surface, and status-panel lifecycle.
- Swift data-source resolver, persistent session signature, metadata-only fallback, usage-store projection, floating/status metric provenance.

## Rejected Shortcuts

- Reusing the previous Tauri summary unchanged across midnight is incorrect because today/request would remain yesterday's values.
- Using live-rate totals or SQLite `threads.tokens_used` to avoid pending remains rejected; neither is a trusted source for compact `总/今/次`.
- Treating the backend's quick O(1) response as proof that the status-panel lifecycle cannot flash is insufficient; the React state is explicitly reset before the asynchronous read.

## Accepted Risks / Rejected Findings

- The full-detail Radar bearer material is reversibly obfuscated in the client. This is not being promoted as a defect: the user explicitly accepted light local obfuscation and accepted that a determined person can recover the key. The audit should verify that it is used only for full-detail requests, never public/basic requests, and can be rotated; it should not misrepresent the chosen boundary as secret storage.
- The history report's claim that the two-second fork replay grace is itself a confirmed bug is not accepted. It proves an unavoidable ambiguity and a hypothetical fast-branch loss, but the existing real dense-replay fixture proves that removing or naively shortening the grace reintroduces catastrophic duplicate totals. Keep the current rule until real logs reveal a stable turn/event boundary that distinguishes copied user messages from new branch work; test exact 1.999/2.000/2.001 boundaries only as characterization, not as a license to change behavior.
- Windows updater metadata living under the unified GitHub `latest` release is currently an accepted unified-release architecture, not a defect by itself. It becomes a bug only if the product adopts independent platform release cadence without first moving Windows metadata to a stable channel URL.
