# Tauri Context-Rich Manual Review Brief

## Objective

Perform a new, human-led full-project review of the released Tauri/Windows product source across React, TypeScript, Rust, Tauri platform code, scripts, and updater boundaries. Historical knowledge may identify recurring patterns, but old reports do not count as current coverage.

## Source Boundary

- Released product: `v0.7.2` at `e48930a626679230d5d52267c830812f254fdd26`.
- Audit integration: `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2`.
- Review the released source state, not only the last Tauri commit diff.

## Method

- This is a manual source and history review. Use source reads, search, call tracing, Git history, and existing tests to navigate.
- Do not run Knip, Biome, JSCpd, Clippy, Cargo Machete, mutation tools, or other automatic scanners in this lane.
- Do not start from a prescribed file list. Explore the complete product and state what you actually covered.
- Trace behavior across TS/Rust/IPC/platform boundaries and all surfaces.
- Inspect tests for false confidence, source-shape assertions, missing lifecycle behavior, and patch-specific expectations.

## Required Review Dimensions

- Logic correctness, data provenance, cache signatures and persistence.
- Promise/task cancellation, stale completions, timers, listeners and monitor lifecycle.
- IPC command semantics, surface authorization and failure containment.
- Codex Home/CLI discovery and source propagation.
- Dashboard/floating/status/tray state synchronization.
- Windows and macOS platform differences that can alter product behavior.
- Performance, repeated scans, high-frequency IPC and UI re-render paths.
- Architecture debt and duplicate sources of truth.
- Packaging/updater behavior only where it affects current product reliability.

## Forbidden Actions

- No production/test edits, commits, builds, app launches, process management, push, release, or updater action.
- No reset-card consume/redeem request.
- No Provider write operation against a real Codex Home.
- Do not touch the Swift worktree or runtime.

## Report

Write the report to:

`/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/audits/v0.7.2/reports/tauri-context-review.md`

The report must contain:

1. Exact branch/commit and final git status.
2. Actual exploration scope and why it is sufficient or incomplete.
3. Flow maps and invariants discovered.
4. Findings ordered by severity with file/line evidence, impact, trigger, confidence, suggested reproduction, and missing test.
5. Suspected issues needing reproduction or product decision.
6. Rejected/stale historical concerns with current evidence.
7. Uncovered modules and next coverage-closure suggestions.
8. Explicit statement that no product files, runtime, or release state were changed.

