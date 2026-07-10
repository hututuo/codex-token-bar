# Source Provenance And Settings Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:test-driven-development` for every behavior change. Work only in the assigned lane and commit cohesive changes.

**Goal:** Make every usage, quota, live-rate, unread, and compact projection switch Codex Home atomically without relabeling or leaking data from the prior source.

**Architecture:** Persist settings with one locked atomic read-modify-write service. Emit one canonical source-change event after durable save. Each lane consumes that event through a source-transition coordinator that cancels obsolete work, resets source-local state, and controls whether prior data is cleared or retained with explicit provenance.

**Tech Stack:** Rust/Tauri, TypeScript/React, Swift/SwiftUI, XCTest.

## Global Constraints

- `总/今/次` remain precise JSONL-derived values; do not use live-rate totals or SQLite `tokens_used` as fallback.
- Old-source data must never be presented under the new source label.
- Same-source rebuild may retain a trusted total; source changes clear source-owned metrics immediately.
- Date/UTC-offset changes are not source changes: preserve only semantically valid fields and rebuild today/request once.
- Settings saves preserve unrelated fields and never expose partial JSON.
- Automatic/default Home and explicit Home transitions both carry a canonical source identity.
- Frontend generation guards supplement but do not replace backend/source identity checks.
- Tests must be red before production edits and green afterward.

---

### Task 1: Tauri Atomic Settings Service

**Files:**
- Modify: `tauri-app/src-tauri/src/platform/settings.rs`
- Modify: `tauri-app/src-tauri/src/platform/mod.rs`
- Modify/add settings tests in the existing Rust settings test module.

**Produces:**
- One process-wide settings mutex.
- Unique temp write, flush/sync, platform-correct atomic replace, and bounded corrupt-file recovery/diagnostic.
- One mutation helper that reads, mutates, persists, and returns the exact saved snapshot while holding the lock.

- [ ] Add a barrier test where floating position and display surfaces save from the same old snapshot; final JSON must contain both updates.
- [ ] Add reader-during-write, interrupted temp, corrupt primary, and repeated Windows-destination fixtures.
- [ ] Observe correct red failures.
- [ ] Implement the locked atomic mutation service and route every setter through it.
- [ ] Run focused settings/window-auth tests and full Rust persistence-adjacent tests.
- [ ] Commit the settings transaction.

### Task 2: Tauri Source-Change Event And Dashboard Reload Matrix

**Files:**
- Modify: `tauri-app/src-tauri/src/commands/settings.rs`
- Modify: `tauri-app/src-tauri/src/lib.rs` only if command/event registration changes.
- Modify: `tauri-app/src/api/settingsClient.ts`
- Modify: `tauri-app/src/platform/desktopEvents.ts`
- Modify: `tauri-app/src/state/useDashboardActions.ts`
- Modify: `tauri-app/src/state/useDashboardData.ts` and focused pure refresh model/helper files.
- Add focused Node behavior tests; update `surfaceState.test.mjs` only to remove superseded source-string assertions.

**Produces:**
- A durable-save-then-publish `app-settings-changed` event for set and reset Home.
- A source transition that advances precise usage, quota, thread-option, unread, and live-rate generations immediately.

- [ ] Add controlled A -> B and A -> automatic tests proving the event carries the saved canonical source snapshot.
- [ ] Add delayed old-source usage/quota/thread results and prove they cannot publish after transition.
- [ ] Observe red failures.
- [ ] Implement event publication after save and one dashboard source-transition action matrix.
- [ ] Run focused Node tests, window-auth/settings Rust tests, and frontend build.
- [ ] Commit the Tauri main-surface transition.

### Task 3: Tauri Compact Quota/Usage Source Ownership

**Files:**
- Modify: `tauri-app/src/surfaces/useCompactPanelData.ts`
- Modify: `tauri-app/src/surfaces/useCompactPanelQuota.ts`
- Modify: `tauri-app/src/surfaces/useCompactPanelSnapshot.ts`
- Modify: `tauri-app/src/surfaces/compactPanelSnapshotModel.ts`
- Modify: `tauri-app/src/floating/FloatingWindowApp.tsx`
- Modify: `tauri-app/src/status/StatusPanelApp.tsx`
- Add controlled-promise/model tests in the existing compact test files.

**Produces:**
- Source key/request generation for compact quota and usage.
- Immediate clear on canonical source change, including explicit -> automatic.
- Inactive surfaces stop work without destroying the last same-source trusted presentation.

- [ ] Add A -> B and A -> automatic tests with delayed A quota/summary responses.
- [ ] Add status hide/reopen test: same-source trusted metrics remain, timers/stream stop while inactive.
- [ ] Observe red failures.
- [ ] Implement source-keyed generation and separate “inactive” from “source reset”.
- [ ] Run compact/floating/status Node tests and frontend build.
- [ ] Commit compact provenance/lifecycle behavior.

### Task 4: Tauri Same-Source Calendar Projection

**Files:**
- Modify: `tauri-app/src-tauri/src/core/usage/token_count_jsonl.rs`
- Modify: focused token-count tests.
- Modify compact model tests only if the backend response shape changes.

**Produces:**
- A scope model separating canonical Home from local date/UTC projection.
- At midnight/offset change, total remains trusted while today/request are reset or recomputed from available events and one rebuild is scheduled.

- [ ] Add pre-midnight trusted summary -> post-midnight request fixture; total survives, today/request do not retain yesterday's values, one rebuild runs.
- [ ] Add UTC-offset-change characterization and choose the same conservative projection unless current cached events can recompute exactly.
- [ ] Observe red failures.
- [ ] Implement transformed trusted summary plus single-flight rebuild.
- [ ] Run token-count/live-rate/compact tests.
- [ ] Commit calendar projection separately.

### Task 5: Swift Source Transition Coordinator

**Files:**
- Modify: `Sources/CodexTokenBar/DashboardView.swift`
- Modify: `Sources/CodexTokenBar/CodexUsageStore.swift`
- Modify: `Sources/CodexTokenBar/AccountQuotaStore.swift`
- Modify: `Sources/CodexTokenBar/LiveRateMonitor.swift` only if its existing reset API needs a narrow coordinator interface.
- Modify: task-completion/provider source wiring only through the coordinator.
- Modify/add: `CodexUsageStoreTests.swift`, `AccountQuotaStoreTests.swift`, `LiveRateMonitorTests.swift`, `DashboardRefreshPlanTests.swift`.

**Produces:**
- One source transition method invoked by Dashboard composition.
- Live monitor reset on every actual source identity change and no reset on the same source.
- Prior usage/quota snapshots either remain explicitly attributed to the old source or clear; they are never republished/relabelled as new source.

- [ ] Add an integration model test for A -> nil -> B covering usage, quota, live monitor, task completion, and Provider source wiring.
- [ ] Add failed B load after successful A and prove A values are not labeled B.
- [ ] Add same-source refresh and prove live-rate state is not reset unnecessarily.
- [ ] Observe red failures.
- [ ] Implement a small coordinator/transition API following existing generation guards.
- [ ] Run focused source/store/live tests and `git diff --check`.
- [ ] Commit the Swift source transition.

## Review And Integration Gates

- Review each task against its own brief and diff package before the next task touching the same lane.
- Commander checks transition ordering, canonical source identity, cancellation, and stale-publication tests.
- Run full Rust/Node suites after integrated Tauri Tasks 1-4, not after every small task.
- Run the full Swift suite after integrated Task 5 and its review.
- Runtime acceptance uses two disposable Homes with visibly different totals/quota/thread IDs; never change the user's real selected Home during automated tests.
- Do not merge stable/release branches or publish an update during this batch.
