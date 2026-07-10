# Provider Data-Safety Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:test-driven-development` for every behavior change. Work only in the assigned lane and commit cohesive changes. Do not alter release metadata or the other platform.

**Goal:** Make Provider inspection, sync, verification, backup, and rollback fail closed under invalid target metadata, active Codex writers, overlapping operations, failed verification, and untrusted/stale recovery points.

**Architecture:** Each lane keeps its existing Provider UI and core engine, but moves safety invariants into the backend engine where every caller must pass them. Mutations run under a canonical-Codex-Home operation lease, start from a fresh consistent backup, verify before the lease ends, and roll back on either mutation or verification failure. Backup restore is canonical-root scoped.

**Tech Stack:** Rust/Tauri, TypeScript/React tests, Swift/AppKit, XCTest, SQLite.

## Global Constraints

- Provider mutations remain explicit user actions; no automatic scan may mutate Codex files.
- Do not issue reset-credit consume/redeem requests.
- Do not weaken Tauri main-window command authorization.
- A running Codex application is a backend mutation blocker, not advisory copy.
- No operation may write `(missing)`, blank, malformed, or section-confused provider values.
- Every sync uses a newly created recovery point for the current canonical Codex Home.
- Backend operation serialization is scoped by canonical Codex Home and survives frontend timeout/retry.
- Verification failure is part of the mutation transaction and triggers rollback.
- Restore may write only validated members under the selected canonical Codex Home.
- Tests must be red before production edits and green afterward.
- Workers are not alone in the repository: do not revert unrelated audit or other-worker changes.

---

### Task 1: Tauri Target Selection And Provider Validation

**Files:**
- Modify: `tauri-app/src-tauri/src/core/provider_repair/target_provider.rs`
- Modify: `tauri-app/src-tauri/src/core/provider_repair/sqlite_state.rs`
- Modify: `tauri-app/src-tauri/src/core/provider_repair.rs`
- Modify: `tauri-app/src-tauri/src/core/provider_repair_tests.rs`
- Modify: `tauri-app/src-tauri/Cargo.toml`, `tauri-app/src-tauri/Cargo.lock` (add the structured TOML parser dependency used by production and fixtures)

**Interfaces:**
- Produces an optional validated provider candidate; absence must remain `None`, never a display sentinel.
- `detect_target_provider` may select only a non-empty validated config/SQLite/JSONL provider or the explicit accepted default.

- [ ] Add a fixture where newest SQLite provider is empty, JSONL provider is `openai`, and config has no target; verify target is `openai`, never `(missing)`.
- [ ] Add fixtures proving `model_provider_backup`, table-local lookalikes, comments, single/double-quoted valid TOML, blank values, and malformed TOML cannot become destructive targets.
- [ ] Run the focused tests and observe the expected failures against v0.7.2.
- [ ] Replace ad-hoc line parsing with structured top-level TOML parsing and keep missing provider as `None`.
- [ ] Add a final provider-value guard immediately before mutation entry.
- [ ] Run focused Provider tests and the Rust quota/Provider-adjacent suite.
- [ ] Commit as one Tauri target-validation change.

### Task 2: Tauri Backend Operation Lease And Timeout Ownership

**Files:**
- Modify: `tauri-app/src-tauri/src/commands/provider_repair.rs`
- Modify: `tauri-app/src-tauri/src/core/provider_repair.rs`
- Modify: `tauri-app/src-tauri/src/core/provider_repair_tests.rs`
- Modify: `tauri-app/src/api/providerRepairClient.ts`
- Modify: `tauri-app/src/components/ProviderRepairCard.tsx`
- Modify/add focused Node tests beside Provider operation controller/client.

**Interfaces:**
- Produces a backend lease keyed by canonical Codex Home and operation ID.
- A second backup/sync/rollback for the same Home returns a typed busy result while the first still owns the lease.
- A frontend timeout must not change the backend operation to “finished”; UI enters an uncertain/busy state until status reconciliation.

- [ ] Add a controllable blocking core-operation test and prove a concurrent second mutation is rejected.
- [ ] Add a frontend controlled-promise test proving timeout does not re-enable another destructive action as if Rust had stopped.
- [ ] Observe both red failures.
- [ ] Implement the canonical-home backend lease with RAII release on every exit path.
- [ ] Add a read-only backend operation-status command keyed by canonical Home and operation ID; after a frontend timeout, keep destructive controls disabled until this command reports that the original lease ended. Do not attempt unsafe thread cancellation.
- [ ] Run focused Rust and Node tests, then `npm run build`.
- [ ] Commit backend serialization and frontend uncertain-state behavior together.

### Task 3: Tauri Fresh Consistent Backup, Verification, And Restore

**Files:**
- Modify: `tauri-app/src-tauri/src/core/provider_repair/backups.rs`
- Modify: `tauri-app/src-tauri/src/core/provider_repair/session_files.rs`
- Modify: `tauri-app/src-tauri/src/core/provider_repair.rs`
- Modify: `tauri-app/src-tauri/src/core/provider_repair_tests.rs`
- Modify Provider UI copy/tests only when it must reflect the exact returned backup.

**Interfaces:**
- Sync creates a fresh collision-resistant backup inside the operation lease and returns that exact backup ID.
- SQLite backup is a consistent database snapshot; sidecar-copy failure cannot be ignored or falsely reported complete.
- Mutation plus verification is one recovery boundary.
- Atomic replacement works when the destination already exists on Windows.

- [ ] Add a WAL fixture with an uncheckpointed committed row; backup/restore must preserve it and pass `PRAGMA integrity_check`.
- [ ] Add a stale-backup fixture proving sync creates a newer recovery point instead of reusing it.
- [ ] Add verification-throws and verification-mismatch fixtures proving automatic rollback occurs.
- [ ] Add repeated existing-destination replacement coverage under a platform-neutral helper and a Windows-specific assertion where feasible.
- [ ] Add same-second backup creation coverage; IDs must differ and directories use create-new semantics.
- [ ] Observe red failures.
- [ ] Implement a consistent SQLite backup API, fresh backup creation, verified rollback boundary, atomic replace helper, and collision-resistant IDs.
- [ ] Run focused Provider tests, then the full Rust suite because these helpers touch shared persistence behavior.
- [ ] Commit the Tauri recovery-point transaction.

### Task 4: Swift Running-App Guard And Operation Serialization

**Files:**
- Modify: `Sources/CodexTokenBar/ProviderSyncEngine.swift`
- Modify: `Sources/CodexTokenBar/ProviderSyncStore.swift`
- Modify: Provider sync UI only for disabled-state/copy accuracy.
- Modify: `Tests/CodexTokenBarTests/ProviderSyncEngineTests.swift`
- Modify: `Tests/CodexTokenBarTests/ProviderSyncStoreTests.swift`

**Interfaces:**
- Produces an engine-level mutation preflight that rejects sync/rollback while Codex is running.
- Produces a canonical-home operation lease shared by every Swift Provider caller.

- [ ] Inject the application-running probe and write red engine tests for sync and rollback rejection.
- [ ] Add a delayed concurrent-operation test proving the second mutation for the same Home is rejected.
- [ ] Confirm scan/verify remain read-only and usable while Codex runs.
- [ ] Implement the backend preflight immediately before mutation and the scoped lease with guaranteed release.
- [ ] Wire UI disabled/diagnostic state to the backend result without making UI the authority.
- [ ] Run focused engine/store/UI model tests.
- [ ] Commit the Swift mutation guard.

### Task 5: Swift Verification Transaction And Backup Member Scope

**Files:**
- Modify: `Sources/CodexTokenBar/ProviderSyncEngine.swift`
- Modify: `Sources/CodexTokenBar/ProviderSyncEngine+Backups.swift`
- Modify: `Tests/CodexTokenBarTests/ProviderSyncEngineTests.swift`

**Interfaces:**
- Mutation and post-write `makeReport` verification share one catch/rollback boundary.
- Verification success requires zero invalid session files, non-vacuous checked data where expected, matching providers, SQLite integrity, and no workspace issues.
- Restore stages and validates archive members under the canonical Codex Home before replacing known files.

- [ ] Add red tests for thrown post-write report, invalid session file, and empty/vacuous provider set.
- [ ] Add a modified-archive fixture containing an out-of-root member; restore must reject it without touching the destination.
- [ ] Add a normal app-created archive round-trip fixture.
- [ ] Move post-write verification inside the recoverable transaction and strengthen success predicates.
- [ ] Replace root extraction with member validation plus staging/canonical-root restore.
- [ ] Run focused Provider tests and `git diff --check`.
- [ ] Commit the Swift verification/restore hardening separately from Task 4.

## Review And Integration Gates

- Each task gets a separate spec/code-quality review against its task section and diff package.
- Commander checks changed-file scope, red/green evidence, and rollback behavior; do not merely accept worker summaries.
- After Tasks 1-3, run Tauri Provider tests, full Rust tests, focused Node tests, and frontend build once on the integrated Tauri lane.
- After Tasks 4-5, run focused Swift Provider tests and the broader Swift suite once on the integrated Swift lane.
- Perform only disposable-fixture Provider writes; never mutate the user's real `~/.codex` during automated verification.
- Do not merge to stable/release branches or publish an update during this batch.
