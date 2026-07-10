# Quota, Unread, And Live-Rate Core Repair Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:test-driven-development`. Implement one task at a time with task-scoped review before another task touches the same lane.

**Goal:** Stabilize the three continuously running core chains: quota app-server/history, unread/task-completion baseline, and live-rate source/stream ownership.

**Architecture:** External process and filesystem readers gain injectable transport/file-state seams. Persisted identities are source/account scoped and atomically updated. Live streaming uses explicit subscriber leases and file generations rather than global booleans or path-only caches.

**Tech Stack:** Swift/XCTest, Rust/Tauri, TypeScript/Node tests, SQLite fixtures.

## Global Constraints

- Quota reads never consume/redeem/reset a card; reset-credit network behavior remains inventory GET only.
- Quota failure may preserve only a previous success from the same canonical source/account and must mark it stale.
- Unavailable quota is not numerical zero.
- Unread baseline writes only app-owned state and never modifies Codex unread files.
- Selected-session cap remains per-session; all-session rate remains the sum of per-session rates with no global 80 tok/s cap.
- Hidden/inactive surfaces do no polling/stream/network work but may keep same-source trusted presentation in memory.
- No production code before a failing behavior test.

---

### Task 1: Swift Quota Process Transport And Cancellation

**Files:**
- Modify: `Sources/CodexTokenBar/AccountQuotaReader.swift`
- Modify: `Sources/CodexTokenBar/AccountQuotaDiagnostics.swift`
- Add/modify: `Tests/CodexTokenBarTests/AccountQuotaReaderTests.swift`, `AccountQuotaDiagnosticsTests.swift`

**Produces:** injectable child/stdio transport, continuous bounded stderr drain, cancellation-owned termination, and an explicit JSON-RPC state machine.

- [ ] Red tests: noisy stderr larger than pipe capacity before id=2; cancellation after initialize; timeout with stderr; id=2 server error; ignored stdout logs; supported response shapes.
- [ ] Implement bounded stderr-tail draining concurrently with stdout and stop retrying on cancellation.
- [ ] Run quota reader/diagnostic/store tests and commit.

### Task 2: Tauri Quota Freshness And Unavailable State

**Files:**
- Modify: `tauri-app/src-tauri/src/core/quota.rs`
- Modify: `tauri-app/src-tauri/src/core/quota/rate_limits.rs`
- Modify: quota models only to represent availability explicitly.
- Modify: `tauri-app/src/components/QuotaStrip.tsx`, compact quota models/helpers and focused tests.

**Produces:** cadence-derived backend freshness, source/account-keyed stale success, and nullable/typed unavailable quota.

- [ ] Red tests for 30s/1m/3m cadence not masked by five-minute cache and in-flight reads still deduped.
- [ ] Red model/SSR tests proving unknown quota renders pending/failure, never `0%`.
- [ ] Implement freshness policy driven by requested cadence and explicit availability through Rust/TS boundary.
- [ ] Run quota Rust tests, quota Node tests, frontend build, and commit.

### Task 3: Shared Quota-History Identity Migration

**Files:**
- Modify Swift `QuotaHistoryStore.swift` and tests.
- Modify Tauri `quota/auth.rs`, `quota_history.rs`, `quota_history/database.rs`, and tests.
- Add one cross-language fixture document/data file consumed by both suites.

**Produces:** versioned identity using stable account subject, canonical source identity, actual plan, and limit; bounded legacy bridge for display-name/fake-Pro rows.

- [ ] Fixture alternates Swift/Tauri writes for two same-name accounts, Plus/Pro/Team, unknown plan, source switch failure, and plan transition.
- [ ] Observe current split/collision/failure-history tests red in both lanes.
- [ ] Implement additive schema migration and identity-scoped reads; never attach previous account history when new identity is unknown.
- [ ] Run both quota-history suites serially against isolated databases and commit lane changes separately.

### Task 4: Swift Task-Completion Tail And Native-State Recovery

**Files:**
- Modify: `Sources/CodexTokenBar/TaskCompletionScanner.swift`
- Modify: `Sources/CodexTokenBar/TaskCompletionMonitor.swift`
- Modify: `Sources/CodexTokenBar/TaskCompletionReadBaseline.swift`
- Modify/add focused task-completion tests.

**Produces:** incomplete-line retention, available -> unavailable fallback recovery, and post-baseline same-thread completion detection.

- [ ] Red two-phase append test proves a completion split before newline is emitted exactly once after completion.
- [ ] Red available -> unavailable -> fallback completion -> available recovery sequence.
- [ ] Red continuously native-unread A -> acknowledge -> new completion marker for A sequence.
- [ ] Implement tail state and combined native-ID/post-baseline marker model without subagent notifications.
- [ ] Run focused task/unread tests and commit.

### Task 5: Tauri Atomic Unread Baseline And Re-entry Semantics

**Files:**
- Modify: `tauri-app/src-tauri/src/core/unread.rs` and recent-completion modules.
- Reuse the corrected atomic settings persistence primitive without coupling schemas.
- Modify focused Rust unread tests and compact Node state tests.

**Produces:** atomic source-keyed acknowledgement, corrupt-file diagnostic/backup, pruning when IDs leave native state, and same-thread post-baseline completion visibility.

- [ ] Red sequence `{A}` -> acknowledge -> `{}` -> `{A}`; final A is unread.
- [ ] Red concurrent Home A/B acknowledgement and truncate/corrupt recovery tests.
- [ ] Red continuously unread A plus new completion marker test.
- [ ] Implement bounded lifecycle/pruning and atomic merge; run unread/live tests and commit.

### Task 6: Tauri Live Stream Lease, WAL Invalidation, And Startup Race

**Files:**
- Modify: `tauri-app/src-tauri/src/commands/live.rs`
- Modify: `tauri-app/src-tauri/src/core/live_rate/rollout.rs`, state/monitor helpers and tests.
- Modify: `tauri-app/src/state/useLiveRateFeed.ts`
- Modify: `tauri-app/src/surfaces/useCompactPanelSnapshot.ts` and controlled-promise tests.

**Produces:** per-subscriber leases, one generation-owned loop, WAL/TTL-aware thread cache, and authoritative startup failure state.

- [ ] Red start -> stop -> start task-generation test proves one loop.
- [ ] Red failed/delayed start cleanup proves one surface cannot decrement another lease.
- [ ] Red WAL-only new-thread insertion refresh test.
- [ ] Red start-failure then fallback-read ordering test preserves the failure until successful stream evidence.
- [ ] Implement leases, generation handle, WAL signature/TTL, and startup reducer; run Rust live and Node compact tests, then commit.

### Task 7: Swift Live Database Replacement And Cross-Source Dedupe

**Files:**
- Modify: `Sources/CodexTokenBar/LiveRateMonitor.swift` and log/rollout parsing extensions.
- Modify: `Sources/CodexTokenBar/RateAccumulator.swift` only if the normalized event interface requires it.
- Modify: `Tests/CodexTokenBarTests/LiveRateMonitorTests.swift`, `RateAccumulatorTests.swift`.

**Produces:** signature-based same-path DB replacement reset and one normalized visible-event identity across stream/rollout.

- [ ] Red stable-path database replacement fixture proves old log IDs are not reused.
- [ ] Red stream delta plus rollout `agent_message` duplicate fixture counts once.
- [ ] Repeated identical genuine outputs with distinct event identity still count separately.
- [ ] Implement source-local reset and normalized fingerprint; run live/rate tests and commit.

## Integration Gates

- Commander reviews every task diff and red/green evidence; worker reports alone are insufficient.
- Full Swift suite runs once after integrated Swift Tasks 1, 3, 4, and 7.
- Full Rust/Node/frontend suites run once after integrated Tauri Tasks 2, 3, 5, and 6.
- Fake child processes, temporary Homes, and isolated SQLite files only; no real reset-credit consumption, Provider mutation, or user-source switch in automated tests.
- Runtime closure includes long stderr, sleep/wake, WAL-only thread creation, database replacement, hidden surface CPU/IO, and multi-surface stream ownership.
