# Usage Discovery And Streak Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILLS: Use `superpowers:systematic-debugging` and `superpowers:test-driven-development`. Implement one task at a time, keep Swift and Tauri commits separate, and send each task through an independent review before the next task touches the same files.

**Goal:** Prevent selected-Home contamination and unbounded session traversal in trusted usage metrics, then align both lanes on a truthful current-streak definition.

**Architecture:** Each lane owns a small file-discovery boundary that accepts only regular JSONL files resolved inside the canonical selected Codex Home, never descends directory symlinks, and reports skipped/failed entries without inventing totals. Streak calculation remains a pure aggregate rule and is tested independently from file discovery.

**Tech Stack:** Swift/Foundation/XCTest, Rust/std/rusqlite/cargo test.

## Global Constraints

- Trusted `总/今/次`, charts, cache rankings, and streaks remain derived from parsed `token_count` JSONL events.
- A `state_5.sqlite` active rollout may live outside `sessions/`, but its resolved file must remain inside the canonical selected Codex Home.
- Do not count `archived_sessions` unless the separate product-policy decision explicitly changes.
- Do not follow directory or file symlinks during recursive session discovery; skipped entries produce a bounded diagnostic where that lane already exposes scan warnings.
- Do not substitute SQLite `tokens_used`, live-rate totals, or prior-source cache values when discovery rejects a path.
- Discovery must be iterative or otherwise bounded against deeply nested/adversarial trees; no full-disk or arbitrary-parent scan.
- Existing fork replay, local-date/UTC-offset cache signatures, active-rollout dedupe, and metadata-only fallback semantics remain unchanged.
- Tests use disposable Homes only. No real user session, Codex app-server, network, Provider mutation, release, or app runtime action.

---

### Task 1: Swift Selected-Home Usage File Boundary

**Files:**
- Modify: `Sources/CodexTokenBar/CodexUsageAnalyzer+SessionParsing.swift`
- Modify/add focused fixtures in: `Tests/CodexTokenBarTests/CodexUsageAnalyzerTests.swift`
- Add one small Swift file-discovery helper only if it materially separates traversal policy from parsing.

**Produces:** A source-owned JSONL discovery result whose session and active-rollout files are regular, non-symlink files resolved under the canonical selected Home.

- [ ] Add red fixtures for a directory-symlink cycle, directory-symlink escape, file-symlink escape, and absolute active rollout outside the selected Home. Each must contribute zero events from the escaped file and must terminate promptly.
- [ ] Add green characterization fixtures for ordinary nested `sessions/YYYY/MM/DD`, an active rollout outside `sessions/` but inside the selected Home, and dedupe when the active rollout is already under `sessions/`.
- [ ] Verify the new negative fixtures fail for the expected source-contamination reason before editing production code.
- [ ] Implement no-follow discovery and canonical-Home containment before session signatures/cache keys are built. Keep active-rollout selection read-only and preserve current ordering/dedupe.
- [ ] Run `swift test --disable-sandbox --filter CodexUsageAnalyzerTests`, `git diff --check`, and the tracked-artifact guard.
- [ ] Commit only Swift usage discovery source/tests with a concise Chinese message.

### Task 2: Tauri Selected-Home Bounded Usage/Unread Discovery

**Files:**
- Modify: `tauri-app/src-tauri/src/core/usage/token_count_jsonl/session_files.rs`
- Modify: `tauri-app/src-tauri/src/core/unread/session_files.rs`
- Modify/add: `tauri-app/src-tauri/src/core/usage/token_count_jsonl/tests.rs`
- Modify/add focused unread session-discovery tests.
- Add one neutral bounded JSONL walker only if usage and unread have exactly the same traversal/root-containment policy; do not couple their parsing semantics.

**Produces:** One bounded, non-following traversal policy shared by usage and unread, plus selected-Home containment for SQLite active-rollout paths.

- [ ] Add red fixtures for a directory-symlink cycle, directory-symlink escape, file-symlink escape, excessive/deep traversal boundary, and external absolute active rollout. Prove calls terminate, external JSONL is excluded, and the existing warning channel reports a bounded reason where available.
- [ ] Add green fixtures for normal nested sessions, an internal active rollout outside `sessions/`, active-rollout/session dedupe, and unread visibility over ordinary nested files.
- [ ] Observe the current recursive collectors follow at least the symlink-directory fixture before editing production code.
- [ ] Implement an iterative walker using no-follow metadata, a deterministic entry budget, and canonical selected-Home containment. Re-check every returned file before it enters a trusted signature/parser; do not silently scan a parent/full disk.
- [ ] Run `cargo test --manifest-path tauri-app/src-tauri/Cargo.toml token_count_jsonl -- --test-threads=1`, focused unread Rust tests, `git diff --check`, and the tracked-artifact guard.
- [ ] Commit only Tauri discovery source/tests with a concise Chinese message.

### Task 3: Swift Current-Streak Semantics

**Files:**
- Modify: `Sources/CodexTokenBar/CodexUsageAnalyzer+Aggregates.swift`
- Modify/add: `Tests/CodexTokenBarTests/CodexUsageAnalyzerTests.swift` or a focused aggregate test file.

**Produces:** A pure current-streak rule that cannot revive a streak after two or more trailing inactive days.

- [ ] Add red tests for: today active; today inactive/yesterday active; today and yesterday inactive after a historical positive run; all inactive; and an active run broken before yesterday.
- [ ] Target exact semantics: if the final day is active, count backward from today; if only today is inactive and yesterday is active, count backward from yesterday; otherwise return zero. Longest streak remains unchanged.
- [ ] Observe the historical-run fixture fail because the current implementation skips unlimited trailing zeros.
- [ ] Implement the minimal pure aggregate change and keep date generation/cache logic untouched.
- [ ] Run focused aggregate/usage analyzer tests and `git diff --check`.
- [ ] Commit only the Swift streak source/tests.

### Task 4: Tauri Current-Streak Semantics

**Files:**
- Modify: `tauri-app/src-tauri/src/core/usage/token_count_jsonl/aggregates.rs`
- Modify/add focused aggregate tests in the same module or existing token-count test module.

**Produces:** The same target rule as Swift, implemented independently in Rust rather than copied mechanically.

- [ ] Add the identical behavior matrix as Task 3 using `ActivityDay` fixtures and observe the historical-run case fail first.
- [ ] Implement: count from today when active; otherwise allow exactly one trailing inactive day only when yesterday is active; otherwise zero. Do not change longest streak.
- [ ] Run focused aggregate tests, then `cargo test --manifest-path tauri-app/src-tauri/Cargo.toml token_count_jsonl -- --test-threads=1` and `git diff --check`.
- [ ] Commit only the Tauri streak source/tests.

### Task 5: Tauri Cache-Hit Normalization Parity

**Files:**
- Modify: `tauri-app/src-tauri/src/core/usage/token_count_jsonl/aggregates.rs`
- Modify/add focused Rust token-count aggregate tests.
- Modify: `tauri-app/src/components/recentUsageChart/model.ts`
- Modify/add: `tauri-app/src/components/recentUsageChart/model.test.mjs`
- Modify token-activity tests only if the backend-normalized fixture reaches their public model boundary.

**Produces:** Cache-hit input/rates bounded to the physical invariant `0 <= cached input <= input`, matching Swift across activity, recent charts, tooltips, ranking, and range/cost summaries.

- [ ] Add a red Rust event fixture where cached input exceeds input; daily and recent output must expose cached input no greater than input and a hit rate no greater than `1.0`.
- [ ] Add red Node fixtures proving malformed external/mock points cannot display `>100%`, cannot produce a combined cached total above input, and do not change ordinary `0..1` behavior.
- [ ] Observe the current daily/recent percentage or combined-summary assertion fail before production edits.
- [ ] In Rust, clamp each event's cached input before accumulator addition and keep `cache_hit_rate` defensively bounded. In TypeScript, normalize only at the data-model boundary; do not hide a wrong backend value solely in CSS intensity.
- [ ] Run focused Rust aggregate/token-count tests, recent-chart and token-activity Node tests, `npm run build`, and `git diff --check`.
- [ ] Commit Tauri Rust/TypeScript cache normalization separately from streak and discovery.

### Task 6: Tauri Windows-Safe Usage Cache Persistence

**Files:**
- Modify: `tauri-app/src-tauri/src/core/usage/cache_lifecycle.rs`
- Modify: `tauri-app/src-tauri/src/core/usage/token_count_jsonl.rs`
- Modify/add focused cache lifecycle and token-count persistence tests.
- Reuse or extract a neutral cross-platform atomic-file helper only after the accepted settings/Provider work establishes its final contract; usage code must not depend on Provider UI/domain modules.

**Produces:** Repeated cache marker and dashboard aggregate saves that durably replace an existing destination on Windows, clean task-owned temporary files, and surface a bounded persistence diagnostic without blocking correct in-memory totals.

- [ ] Add red second-save fixtures for both `cache-state.json` and `dashboard-aggregate.json` under injectable Windows replacement semantics; the second payload must replace the first and no task-owned temp remains.
- [ ] Add red failure fixtures for write, file-sync, replacement, and parent-directory-sync stages. The marker must not claim ready when persistence failed; the aggregate must retain correct in-memory data while exposing/logging the persistence failure once rather than rebuilding forever without evidence.
- [ ] Observe the existing rename-over-destination path fail in the Windows-semantics fixture before production edits.
- [ ] Implement unique temp creation, complete write/file sync, platform-correct replace, parent-directory durability where supported, and exact task-owned cleanup. Do not delete an unrelated temp or a valid prior cache on failed replacement.
- [ ] Run focused cache lifecycle/token-count tests, full `cargo test --manifest-path tauri-app/src-tauri/Cargo.toml -- --test-threads=1` once after the task is otherwise green, and `git diff --check`.
- [ ] Commit usage-cache persistence independently from settings and Provider transactions.

## Review And Integration Gates

- File-discovery tasks are high-risk core-total changes and use a high-reasoning implementer/reviewer. Streak tasks use GPT-5.6 medium.
- Commander reads the actual diff and tests before dispatching one fresh independent reviewer per task; worker reports are not acceptance.
- Reviewers verify that a rejected path cannot enter a cache signature, trusted aggregate, unread result, or later fallback under a different label.
- After all six tasks are accepted, run the full Swift suite once and the full Rust/Node suites once, serially within each lane, then compare one deterministic disposable-Home fixture across languages.
- UI/runtime acceptance confirms totals remain visible after a normal scan and that streak labels match, but UI evidence does not replace source tests.
- Do not merge stable/release branches or publish an update during this batch.
