# Quota Task 2 Red/Green Report

## Scope

- Tauri quota freshness, in-flight coalescing, canonical Home/account identity, explicit unavailable quota, and quota UI/compact projections only.
- No Swift implementation, Provider implementation, `platform/settings.rs`, release metadata, network, real auth, real app-server, or reset-card consume/redeem/use request.

## RED

1. `node --test src/components/quota/quotaStripSsr.test.mjs src/surfaces/compactPanelLabels.test.mjs`
   - Failed because unavailable `null` percentages rendered as `剩 0%` with `width:0%`.
   - Failed because compact quota had no availability-aware projection.
2. Focused Rust quota compile after adding behavior tests
   - Missing `QuotaAvailability`, nullable percentages, cadence freshness policy, stable account key, and canonical cache scope.
3. Isolated focused Rust test `identity_change_during_read_does_not_reuse_previous_success`
   - Failed because an auth subject change during a forced read still reused account A's successful quota as stale data for account B.

## GREEN

- Rust availability shape: `QuotaLimit { availability: measured | unavailable, remaining_percent: Option<f64>, used_percent: Option<f64>, ... }`; serde emits camel-case nullable fields and snake-case discriminator values.
- TypeScript availability shape: `availability: "measured" | "unavailable"`, `remainingPercent: number | null`, and `usedPercent: number | null`.
- Automatic success freshness: sanitize persisted cadence to `30s/1m/3m/5m/10m`, then use `min(30s, cadence / 2)` (`15s/30s/30s/30s/30s`).
- The backend reads the persisted shared cadence through `read_app_settings` behind an injectable policy/loader seam.
- Manual refresh bypasses an already-completed cache entry. Concurrent callers for the same canonical Home join the in-flight read, including forced and independently phased automatic callers.
- Successful/stale reuse requires the same canonical Home and the same established local ID-token `sub`/account key. Missing, changed, or mid-read-changing identity cannot reuse prior success.
- Unavailable failures never load or attach global history. Same-identity stale success preserves its trusted history; full stable-identity history schema migration remains Task 3.
- Main and compact/floating accessibility render unavailable quota as pending/failure status with no `0%`, empty measured bar, or `aria-valuenow=0`; a real measured zero remains `0%`.

## Verification

- Isolated clean-HEAD Rust quota filter after applying only Task 2 diff: `86 passed`; follow-up identity-transition RED failed on stale reuse, then GREEN passed.
- Target-worktree Rust quota filter: `87 passed`.
- Target-worktree expanded Node/SSR/compact/cadence quota filter: `32 passed`.
- Target-worktree frontend build (`tsc --noEmit && vite build`): passed.

## Review Fix

### Root Causes Confirmed

- Successful quota acquisition was finalized before the outer pre/post auth observation was compared, so history writes/loads and mixed A-quota/B-account publication could happen before rejection.
- Long-lived cache identity and short-lived flight identity were the same optional stable account key. Missing `sub/account_id` therefore prevented waiters from sharing an unchanged in-flight result.
- History memory and database selection were process-global/latest-account. A cached A bundle could refresh from B, and a fresh A query could follow a concurrently newer B row.
- History normalization copied a prior measured window into a new row whose corresponding window was unavailable.
- Compact snapshots carried percentages without availability, allowing compatibility `unavailable + 0` payloads to render as measured meters.
- Dashboard aggregate cache version `10` remained implicit after the required quota availability field changed the persisted snapshot shape.

### RED Evidence

1. `node --test src/floating/floatingQuotaSsr.test.mjs`
   - `1 failed`: `unavailable + 0` rendered `role="meter"`, `aria-valuenow="0"`, and `剩余 0%` instead of an unavailable status.
2. `node --test src/status/statusQuotaSsr.test.mjs`
   - `1 failed`: the required status quota projection module did not exist.
3. `cargo test successful_identity_change_skips_history_finalization_side_effects -- --exact --nocapture`
   - Compile RED: the raw-loader/finalizer seam, scope-aware history cache signature, and current-account history query did not exist. The new successful A -> B fixture also showed the old coordinator had no path that could suppress finalization before identity validation.
4. `cargo test legacy_history_scope_is_claimed_before_recording_and_invalidated_on_collision -- --nocapture`
   - Compile RED: `QuotaHistoryMemoryCache` had no pre-record scope claim, leaving concurrent same-name rows able to contaminate a legacy filter before attachment.
5. `cargo test cache_version_tests -- --nocapture`
   - Compile RED: no decode seam existed to assert explicit rejection of version `10`; a concurrent Provider worker also temporarily left an unrelated compile error, which was not modified or staged by this task.
6. `cargo test unavailable_window_ignores_compatibility_zero_when_building_history_row -- --nocapture`
   - `1 failed`: an unavailable window carrying compatibility `usedPercent=1` was converted to `Some(100)` and retained a reset timestamp.
7. Final `cargo test quota -- --nocapture` stress run before the database gate
   - Concurrent A/B record/load hit `SqliteFailure(DatabaseBusy)` during simultaneous history database access. This exposed a real production concurrency boundary, fixed with one process-local record/load gate rather than weakening the test.

All behavior tests were added before their production paths. Rust compilation was temporarily blocked twice by concurrent settings/Provider edits in the shared worktree; reruns after those workers advanced isolated the Task 2 RED failures above.

### Correction

- Added a process-local SHA-256 auth observation over `auth.json` bytes. Raw token material is never logged, persisted, or exposed; stable account IDs remain required for long-lived success reuse, while an unchanged bounded digest permits only short-lived flight sharing.
- Split raw quota acquisition from finalization. The coordinator compares pre/post Home/auth observations before any history record/load, cache insertion, stale fallback, or measured publication. Identity changes return a typed unavailable bundle for the completed local identity with empty history and no additional reset-credit request.
- Scoped history memory by canonical Home plus account/auth observation, preserved history already attached to same-scope cached/stale bundles, and changed database loading to query the current bundle filter instead of the globally latest account.
- Added a pre-record legacy identity claim. Concurrent/same-display-name scopes mark the legacy filter ambiguous and publish empty history rather than recording/loading cross-scope rows. The existing schema remains unchanged; Task 3 retains ownership of versioned stable-sub persistence/migration.
- Preserved `None` for an unavailable window during normalization and series generation; later measured rows resume normally without synthesizing a measurement at the partial timestamp.
- History row construction now requires per-window `availability == measured`; compatibility unavailable zeros and reset timestamps are discarded before persistence. Concurrent record/load operations share a narrow process-local SQLite gate.
- Carried both window availability discriminators through compact snapshots. Floating bars and status text require `measured` plus a finite percentage; `unavailable + 0/null` stays unavailable while measured `0/100` remains visible and accessible.
- Bumped the dashboard aggregate cache to version `11` and routed persistent loading through a directly tested version-rejection decoder.

### GREEN Evidence

- `cargo test cache_version_tests -- --nocapture`: `1 passed` after explicit v10 decode rejection.
- `cargo test unavailable_window_ignores_compatibility_zero_when_building_history_row -- --nocapture`: `1 passed`.
- `cargo test concurrent_account_record_and_load_stays_on_each_account_filter -- --nocapture`: `1 passed` after the database gate.
- `cargo test quota`: `105 passed`; includes successful A -> B quarantine, zero history finalization calls, no-id-token/id-token-without-sub automatic/manual/mixed coalescing, auth mutation rejection, concurrent A/B record/load, same-name fail-closed publication, partial windows, compatibility unavailable zero, and cache v11.
- `node --test src/components/quota/quotaStripSsr.test.mjs src/surfaces/compactPanelLabels.test.mjs src/floating/floatingQuotaSsr.test.mjs src/status/statusQuotaSsr.test.mjs src/settings/quotaRefreshCadence.test.mjs src/state/quotaAutoRefreshModel.test.mjs src/utils/quota.test.mjs src/utils/quotaRefresh.test.mjs`: `33 passed`.
- `npm run build`: passed (`tsc --noEmit && vite build`, 142 modules transformed).
- `rustfmt --check` could not run because the installed stable toolchain lacks the `rustfmt` component; no component was installed in this shared task. `git diff --check` is used as the formatting/whitespace gate below.
- `git diff --cached --check`: passed.
- Original Task 2 package `beea449..2f1c4c8` and the staged correction package were inspected together. Neither package contains Swift, Provider, Tauri settings, Cargo dependency/lock, release/updater, reset-card endpoint, `.orig`, `.rej`, build artifact, or real secret changes. Intervening shared-branch Swift/settings commits are separate commits and are not staged in this correction.
- Secret-pattern and artifact guards returned no matches. Added auth fixtures are local synthetic JSON only; no real auth file, app-server, network, user database, or reset-card endpoint was read or invoked.

### Changed Files

- Coordinator/auth/history: `tauri-app/src-tauri/src/core/quota.rs`, `quota/auth.rs`, `quota_history.rs`, `quota_history/database.rs`, `quota_history_tests.rs`.
- Aggregate invalidation: `tauri-app/src-tauri/src/core/usage/token_count_jsonl.rs`, `token_count_jsonl/cache_version_tests.rs`.
- Compact/floating/status availability: `tauri-app/src/types/live.ts`, `src/api/fallback/liveFallback.ts`, `src/surfaces/compactPanelSnapshotModel.ts`, `src/surfaces/useCompactPanelData.ts`, `src/floating/FloatingPanelPreview.tsx`, `src/status/StatusPanelApp.tsx`, `src/status/StatusQuotaProjection.tsx`, `src/utils/quota.ts`, plus focused SSR tests.

### Residual

- Correctness is closed without Task 3 schema work. The process-global quota read cache, history cache/legacy ownership map, and per-Home gate map still have process-lifetime entries with no bounded eviction. This is queued as Post-Correctness Maintenance Task 8; it must preserve in-flight ownership and trusted same-scope history semantics.
