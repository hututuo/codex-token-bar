# Post-Correctness Maintenance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILLS: Use `superpowers:test-driven-development` for behavior-preserving refactors and `superpowers:verification-before-completion` before each commit. Start only after the referenced correctness task is independently accepted.

**Goal:** Remove confirmed dead code and reduce high-risk duplication/architectural inversion without mixing cleanup into core correctness repairs.

**Architecture:** Every task preserves public behavior and has a small rollback surface. Shared helpers are extracted only after both callers have identical, tested policy; domain models move downward so API and UI depend on neutral code rather than each other.

**Tech Stack:** Swift/XCTest, Rust/cargo test, TypeScript/React/Node SSR tests.

## Global Constraints

- Automatic tools supply candidates only; every deletion/refactor requires manual call-site and release-history confirmation.
- No repository-wide formatting/import churn and no raw SwiftLint/Biome/Knip output as a gate.
- No task changes token totals, fork replay, quota identity, unread semantics, live-rate counting, Radar endpoint/auth separation, or UI copy/layout unless its brief explicitly says so.
- Keep Swift and Tauri commits separate. Do not touch release metadata, updater manifests, real user data, network, or running apps for source-only cleanup.

---

### Task 1: Swift Disconnected Legacy Usage-Cache Loader Removal

**Files:**
- Modify: `Sources/CodexTokenBar/CodexUsageAnalyzerModels.swift`
- Modify focused cache tests only where they characterize retained cleanup/migration behavior.

- [ ] Use history/call-site evidence to prove `loadLegacyV5SessionCache`, raw legacy conversion helpers, and their private-only types have no production caller in the supported upgrade path.
- [ ] Add/retain a test proving obsolete v2-v5 cache artifacts are still deleted and current v8/v3 cache files still load; do not resurrect raw prompt/response persistence.
- [ ] Remove only unreachable loader/converter code. Keep deliberate legacy cleanup URLs until the supported cleanup window is separately retired.
- [ ] Run `CodexUsageAnalyzerTests`, full Swift build/typecheck, `git diff --check`, and commit.

### Task 2: Tauri Dead Production Source Removal

**Files:**
- Delete: `tauri-app/src/diagnostics/useCommandDiagnostics.ts`
- Modify: `tauri-app/src/components/CodexRadarStrip.tsx` to remove private uncalled `modelPointSummary` only.
- Modify focused source/SSR tests that intentionally document the active path.

- [ ] Confirm with TypeScript graph and repository search that neither symbol is imported, dynamically referenced, or part of a public barrel.
- [ ] Add/adjust one behavior/source guard that names the active diagnostic/Radar presentation seam rather than the removed dead symbol.
- [ ] Delete the dead code, run focused tests plus `npm run build`, and commit.

### Task 3: Tauri Radar Neutral Domain Boundary

**Files:**
- Move parsing/types/status logic from `tauri-app/src/components/codexRadar/model.ts` into a neutral `tauri-app/src/domain/codexRadar/` module following existing domain conventions.
- Modify Radar API clients and components to import the neutral module.
- Move/update model tests without changing fixtures or endpoint policy.

- [ ] Add an architecture test rejecting API-to-component imports while allowing component/API dependencies on the neutral domain module.
- [ ] Preserve public `current.json` no-auth behavior, Rust-only full-detail auth, stale/partial diagnostics, and the 08:00/18:00 attempt schedule exactly.
- [ ] Move symbols without redesigning the UI or payload schema; run all Radar Node/Rust tests and frontend build, then commit.

### Task 4: JSONL Reader Policy Consolidation

**Files:**
- Swift: usage/unread/task JSONL helper files only after usage discovery and Task Completion Task 4 are accepted.
- Tauri: usage/unread JSONL helper files only after usage discovery and Unread Task 5 are accepted.
- Focused malformed/tail/symlink/size-limit tests in each lane.

- [ ] Build a policy matrix first: first-line read, incremental tail retention, malformed-row skip, timestamp requirement, subagent filtering, size bound, symlink/root containment. Extract only cells whose behavior is identical.
- [ ] Add characterization tests before moving code; a helper must not make task completion consume incomplete tails or make usage/unread silently share different warning rules.
- [ ] Introduce one small lane-local bounded JSONL primitive, migrate one caller at a time, and keep each lane green after every move.
- [ ] Commit Swift and Tauri consolidations separately.

### Task 5: Tauri Quota-History Query Deduplication

**Files:**
- Modify: `tauri-app/src-tauri/src/core/quota_history/database.rs`
- Modify focused quota-history tests.

- [ ] Start only after shared identity migration and long-chart horizon Tasks 3/8 are accepted.
- [ ] Characterize every current/legacy account/source/plan query branch with two same-name accounts, known/unknown plan, and legacy fake-Pro rows.
- [ ] Extract one typed query/row mapping builder so selected columns, account predicates, source compatibility, and ordering cannot drift between branches.
- [ ] Run the full quota-history Rust suite and commit without schema or visible-history changes.

### Task 6: Live-Rate Parser Decomposition After Correctness

**Files:**
- Tauri rollout line metric/parser helpers after Live Task 6 is accepted.
- Swift parsing helpers only if the accepted Live Task 7 leaves equivalent complexity.
- Existing live-rate behavior fixtures plus newly accepted WAL/dedupe/generation tests.

- [ ] Freeze the accepted event-category, attribution, duplicate identity, per-session cap, and tool-output/reasoning exclusions in tests.
- [ ] Split parsing, normalization, attribution, and accumulation decisions into pure helpers; do not change event order or fallback precedence.
- [ ] Run focused live/rate suites, compare one shared fixture across lanes, and commit each lane separately.

### Task 7: Replace High-Value Source-Shape Tests With Behavior Seams

**Files:**
- Tauri status/floating/source/updater source-smoke clusters after their runtime tasks are accepted.
- Swift dashboard/Radar/floating placement source-reading clusters only where a small presentation/coordinator seam already exists.

- [ ] Rank source-shape assertions by user-impact behavior, then convert one cohesive cluster per commit to pure model, SSR, coordinator, or native-boundary tests.
- [ ] Keep release/native checks as explicit source smoke when executable runtime automation cannot prove them; do not delete coverage merely to reduce brittleness.
- [ ] Run the owning focused suites and build after each cluster; record remaining source-shape tests and why they remain.

### Task 8: Bound Tauri Quota Process Caches And Gates

**Files:**
- Modify: `tauri-app/src-tauri/src/core/quota.rs` only after Tauri Quota Task 2 and the shared identity migration are independently accepted.
- Modify focused quota cache/gate lifecycle tests.

- [ ] Characterize active owner/waiter lifetime, forced coalescing, stable-account success reuse, unavailable failure TTL, same-scope trusted history, and ambiguous legacy-name behavior before cleanup.
- [ ] Add bounded eviction for expired `QUOTA_READ_CACHE` entries, idle `QUOTA_READ_GATES`, and expired/unreachable `QUOTA_HISTORY_CACHE` entries including legacy ownership markers.
- [ ] Never evict an active gate owner/waiter, never re-enable cross-account history, and do not introduce the Task 3 schema migration here.
- [ ] Run focused quota/history concurrency tests, full Rust quota filter, `git diff --check`, and commit separately from correctness work.

## Review And Integration Gates

- These tasks never preempt unaccepted P1/P2 correctness work.
- Commander reviews actual diffs and covering tests; each task gets a fresh independent medium-reasoning review.
- Final cleanup integration runs full Swift, Rust, Node, and frontend build once, then the whole-branch human review checks for accidental behavior drift.
