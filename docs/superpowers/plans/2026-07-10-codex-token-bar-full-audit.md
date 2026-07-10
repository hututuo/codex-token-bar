# Codex Token Bar v0.7.2 Full Audit Execution Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete a human-led full-project audit of Swift and Tauri, close coverage gaps, validate cross-platform target behavior and UI, then generate and execute evidence-backed repair batches for confirmed legacy defects.

**Architecture:** The audit has independent blind human-review lanes, a separate auxiliary-tool lane, a coverage-closure lane, and Commander adjudication. Discovery remains read-only. Confirmed findings are converted into separate TDD repair plans and implemented on bounded branches with task review and final whole-branch review.

**Tech Stack:** Swift/SwiftUI/SwiftPM, React/TypeScript/Node, Rust/Tauri/Cargo, macOS AppKit, Windows Tauri runtime, Git worktrees.

## Global Constraints

- Product audit baseline is `v0.7.2` at `e48930a626679230d5d52267c830812f254fdd26`; audit integration starts from post-release `origin/main` at `04124ea5f7d731024496b7b8441d7fec96cc0540`.
- Human review is the coverage authority; automatic tools are auxiliary signals only.
- Blind human reviewers do not receive previous findings or tool output before their first report is sealed.
- Discovery tasks are read-only: no production edits, commits, builds that open Apps, process kills, pushes, tags, releases, or updater publication.
- Swift and Tauri workers never manage the other lane's runtime or worktree.
- No reset-card consumption request may be made. Provider write operations use disposable copied fixtures only.
- Core flows require two independent reviewers and deterministic reproduction before production fixes.
- Build-writing commands in one worktree run serially; independent read-only searches may run concurrently.
- Every confirmed fix uses TDD, a focused commit, task-level review, and final whole-branch review.
- Tool-only output, formatting noise, and missing optional tool configuration are not product findings without human evidence.

---

### Task 1: Freeze Baseline And Create Audit Ledger

**Files:**
- Create: `audits/v0.7.2/README.md`
- Create: `audits/v0.7.2/coverage-ledger.md`
- Create: `audits/v0.7.2/progress.md`
- Modify: local project `PROJECT_INDEX.md`

**Interfaces:**
- Consumes: released source and post-release ledger at the commits named in Global Constraints.
- Produces: canonical audit scope, domain coverage states, task status, and report locations used by every later task.

- [ ] **Step 1: Record repository and worktree baseline**

```bash
git status --short --branch
git log -5 --oneline --decorate
git diff --check
```

Expected: branch `audit/v0.7.2-full-project`, clean worktree before audit-document changes, starting HEAD `04124ea`.

- [ ] **Step 2: Generate production and test inventory counts**

```bash
rg --files Sources Tests tauri-app/src tauri-app/src-tauri/src scripts | wc -l
rg --files Tests tauri-app/src tauri-app/src-tauri/src | rg '(Tests?\.swift$|\.test\.mjs$|tests?\.rs$)' | wc -l
```

Expected: non-zero counts recorded in `audits/v0.7.2/README.md`.

- [ ] **Step 3: Populate coverage domains**

Add rows for source discovery, usage totals/cache, quota/reset credits/history, live rate, unread/task completion, Radar, Provider repair, settings/surfaces, update/release, UI/accessibility, tests/architecture, and history archaeology. Initial state is `pending`; no domain may be marked reviewed from prior reports alone.

- [ ] **Step 4: Commit audit scaffold**

```bash
git add docs/superpowers audits/v0.7.2
git commit -m "建立 v0.7.2 全项目审查基线"
```

### Task 2: Run Clean Baseline Verification

**Files:**
- Modify: `audits/v0.7.2/progress.md`
- Modify: `audits/v0.7.2/README.md`

**Interfaces:**
- Consumes: clean audit worktree from Task 1.
- Produces: exact baseline test counts and known pre-audit failures.

- [ ] **Step 1: Run all frontend and script tests**

```bash
cd tauri-app
node --test $(find src -name '*.test.mjs' -print | sort)
cd ..
node --test scripts/*.test.mjs
```

Expected: all tests pass; intentional diagnostic test logging is not a failure.

- [ ] **Step 2: Run full Rust tests serially**

```bash
cargo test --manifest-path tauri-app/src-tauri/Cargo.toml -- --test-threads=1
```

Expected: all Rust and doc tests pass.

- [ ] **Step 3: Run full Swift tests serially**

```bash
swift test --disable-sandbox
```

Expected: all Swift tests pass.

- [ ] **Step 4: Run frontend production build**

```bash
cd tauri-app
npm run build
```

Expected: TypeScript and Vite build pass.

- [ ] **Step 5: Record results without hiding baseline failures**

If any command fails, record the exact failing test and classify it as a baseline finding before continuing. Do not change tests or production code in this task.

### Task 3: Blind Swift Human Review

**Files:**
- Create: `audits/v0.7.2/reports/swift-manual-review.md`
- Modify: `audits/v0.7.2/coverage-ledger.md`

**Interfaces:**
- Consumes: Swift production source/tests and the design document; does not consume previous findings or tool reports.
- Produces: independent findings, actual explored scope, flow maps, invariants, uncovered areas, and suggested reproductions.

- [ ] **Step 1: Dispatch the existing Swift executor with a blind read-only brief**

The brief states the repository/worktree boundary, baseline commit, human-first requirement, evidence schema, and forbidden actions. It must not list suspected files or previous bugs.

- [ ] **Step 2: Dispatch an independent Swift code-review agent**

The second reviewer uses the Swift code-review guide but remains blind to the first report and tool output.

- [ ] **Step 3: Seal both reports before comparison**

Each report records actual directories and flows explored, negative evidence, uncovered areas, confirmed/suspected findings, and historical patterns discovered from Git.

- [ ] **Step 4: Merge scope into the coverage ledger**

Do not merge conclusions yet. Mark only modules actually read or traced by the reviewers.

### Task 4: Blind Tauri Human Review

**Files:**
- Create: `audits/v0.7.2/reports/tauri-manual-review.md`
- Modify: `audits/v0.7.2/coverage-ledger.md`

**Interfaces:**
- Consumes: React/TypeScript/Rust/Tauri source/tests and the design document; does not consume previous findings or tool reports.
- Produces: independent Tauri findings, flow maps, platform-specific risks, uncovered areas, and suggested reproductions.

- [ ] **Step 1: Dispatch the existing Tauri executor with a blind read-only brief**

- [ ] **Step 2: Dispatch an independent Tauri code-review agent**

- [ ] **Step 3: Seal both reports before comparison**

- [ ] **Step 4: Merge actual scope into the coverage ledger**

### Task 5: Historical Debt Archaeology

**Files:**
- Create: `audits/v0.7.2/reports/history-debt-review.md`
- Modify: `audits/v0.7.2/coverage-ledger.md`

**Interfaces:**
- Consumes: Git history, local `CONTEXT.md`, `PROJECT_INDEX.md`, `decisions.md`, release notes, and current source.
- Produces: recurring defect clusters, patch stacks, stale compatibility bridges, cache-version history, and root-cause hypotheses.

- [ ] **Step 1: Map recurring repair themes**

Use `git log --all --oneline`, `git log -S`, `git log -G`, and blame around behavior boundaries. Cover at least usage totals, fork replay, quota reads, live rate, pending states, Radar, unread, CLI discovery, Provider operations, UI layout, and updates.

- [ ] **Step 2: Trace each recurring cluster to current code**

For each cluster, state whether the root cause is removed, guarded only by tests, hidden behind compatibility code, or still structurally present.

- [ ] **Step 3: Identify stale or contradictory decisions**

Compare current code against `decisions.md` and current release behavior. Record contradictions as findings, not silent documentation edits.

### Task 6: Auxiliary Automated Tool Pass

**Files:**
- Create: `audits/v0.7.2/reports/tool-assisted-review.md`
- Create: `audits/v0.7.2/reports/tool-noise.md`

**Interfaces:**
- Consumes: sealed manual reports only after tool runs complete; tools do not influence blind review.
- Produces: manually investigated supplemental findings and a separate noise/configuration record.

- [ ] **Step 1: Verify tool identities and versions**

Record SwiftLint, Periphery, JSCpd, Knip, Biome, Cargo Machete, Cargo Mutants, and Clippy versions. Reject `/opt/homebrew/bin/lizard` if it identifies as the compression CLI.

- [ ] **Step 2: Run Swift auxiliary scans**

Run SwiftLint read-only, Periphery read-only, JSCpd, and Swift coverage. Do not autofix or write project configuration in this task.

- [ ] **Step 3: Run Tauri auxiliary scans**

Run Clippy, Cargo Machete, Knip with an audit-only entry configuration, Biome read-only, JSCpd, and test coverage. Do not treat missing project-owned lint configuration as a product bug.

- [ ] **Step 4: List mutation candidates without full-project mutation**

Use `cargo mutants --list` and manual Swift mutation candidates. Select only small pure modules in usage parsing/cache policy, quota parsing/refresh, live-rate accumulation, unread baseline, and Radar scheduling.

- [ ] **Step 5: Manually trace every high-signal tool result**

Promote a result only after reading callers, state flow, tests, and user impact. Put formatter/import noise and false positives in `tool-noise.md`.

### Task 7: Coverage Closure

**Files:**
- Create: `audits/v0.7.2/reports/coverage-closure.md`
- Modify: `audits/v0.7.2/coverage-ledger.md`

**Interfaces:**
- Consumes: manual review scopes, tool supplemental report, and production file inventory.
- Produces: proof that every production module was reviewed or an explicit bounded exception.

- [ ] **Step 1: Compare actual review scopes with the complete source inventory**

- [ ] **Step 2: Dispatch focused read-only closure reviews for uncovered modules**

Closure prompts may list uncovered paths because open exploration is complete. They must still trace behavior and callers rather than perform a filename-only skim.

- [ ] **Step 3: Require two independent reviews for core flow modules**

- [ ] **Step 4: Mark the ledger complete only with report references**

### Task 8: Functional Parity And Target-State Review

**Files:**
- Create: `audits/v0.7.2/reports/functional-parity-matrix.md`
- Create: `audits/v0.7.2/fixtures/README.md`

**Interfaces:**
- Consumes: sealed Swift/Tauri reports, shared fixture definitions, and current tests.
- Produces: target-state decisions for every user-visible feature and data semantic.

- [ ] **Step 1: Define shared read-only fixtures**

Cover two Codex Homes, fork/subagent/active-rollout sessions, append/truncate, quota seconds/milliseconds and mixed percent scales, noisy timeout, reset-card states, Radar public/full payloads, and unread baseline changes.

- [ ] **Step 2: Compare normalized Swift and Tauri outputs**

Compare total/today/request, quota, pace, live rate, unread, Radar, Provider scan summaries, settings, startup/wake behavior, and update checks.

- [ ] **Step 3: Classify every difference**

Allowed values are `swift-target`, `tauri-target`, `common-redesign`, or `intentional-platform-difference`. Every intentional difference requires a platform capability reason.

### Task 9: Real UI And Runtime Review

**Files:**
- Create: `audits/v0.7.2/reports/ui-parity-review.md`
- Create: `audits/v0.7.2/reports/runtime-scenarios.md`
- Create: `audits/v0.7.2/screenshots/README.md`

**Interfaces:**
- Consumes: clean debug builds, functional parity matrix, and state scenarios.
- Produces: screenshot/runtime evidence for Swift macOS, Tauri macOS, and Tauri Windows.

- [ ] **Step 1: Build and open each lane serially**

Swift worker closes/opens only Swift. Tauri worker closes/opens only Tauri. Windows smoke runs silently on the local Windows environment.

- [ ] **Step 2: Capture the UI state matrix**

Capture main/floating/status/tray across cold start, loading, success, stale, failure, offline, disabled, unread, update-available, narrow/wide, light/dark, and Windows DPI states available without production writes.

- [ ] **Step 3: Inspect interaction stability**

Check layout movement, clipping, text fit, tooltip/popover overflow, chart scroll/date context, hit targets, keyboard/accessibility labels, animation smoothness, idle CPU, and cross-surface setting synchronization.

- [ ] **Step 4: Record untestable states as testability debt**

Do not invent successful coverage when a deterministic state injection seam is absent.

### Task 10: Commander Triage And Reproduction

**Files:**
- Create: `audits/v0.7.2/master-report.md`
- Create: `audits/v0.7.2/findings-register.md`
- Create: `audits/v0.7.2/rejected-findings.md`
- Modify: `audits/v0.7.2/progress.md`

**Interfaces:**
- Consumes: every manual, auxiliary, parity, UI, runtime, and history report.
- Produces: deduplicated confirmed findings and explicit rejected/suspected items.

- [ ] **Step 1: Deduplicate by root cause rather than symptom**

- [ ] **Step 2: Independently reproduce every P0/P1**

- [ ] **Step 3: Sample P2 and rejected/tool-noise decisions**

- [ ] **Step 4: Assign severity, confidence, owner, target state, tests, and blast radius**

- [ ] **Step 5: Commit the complete read-only audit packet**

```bash
git add audits/v0.7.2
git commit -m "完成 v0.7.2 全项目人工审查"
```

### Task 11: Generate Evidence-Based Repair Plans

**Files:**
- Create: `docs/superpowers/plans/2026-07-10-codex-token-bar-core-repairs.md`
- Create: `docs/superpowers/plans/2026-07-10-codex-token-bar-parity-ui-repairs.md`
- Create: `docs/superpowers/plans/2026-07-10-codex-token-bar-tech-debt-repairs.md`
- Modify: `audits/v0.7.2/progress.md`

**Interfaces:**
- Consumes: confirmed findings register with reproduction evidence.
- Produces: exact TDD tasks, file ownership, test commands, commit boundaries, and review gates. No repair task may be generated from suspected or tool-only findings.

- [ ] **Step 1: Put P0/P1 and core P2 into the core repair plan**

- [ ] **Step 2: Put target-state parity and UI defects into the parity/UI plan**

- [ ] **Step 3: Put architectural and testability debt into the technical-debt plan**

- [ ] **Step 4: Self-review each plan for conflicting ownership and missing reproductions**

- [ ] **Step 5: Execute plans with subagent-driven development**

Each implementation task receives a fresh bounded worker, a task reviewer, and a focused fix loop. Shared core modules are repaired sequentially. Independent Swift/Tauri/UI tasks may run in isolated worktrees.

### Task 12: Final Re-Audit And Release Decision

**Files:**
- Create: `audits/v0.7.2/final-verification.md`
- Create: `audits/v0.7.2/remaining-risk.md`
- Modify: `audits/v0.7.2/findings-register.md`
- Modify: `audits/v0.7.2/progress.md`

**Interfaces:**
- Consumes: reviewed repair branches and original reproduction cases.
- Produces: closed findings, remaining decisions, full-suite evidence, runtime evidence, and merge/release recommendation.

- [ ] **Step 1: Re-run every original reproduction against repaired code**

- [ ] **Step 2: Re-run relevant mutation and auxiliary scans to catch regressions**

- [ ] **Step 3: Run full Swift, Node, Rust, macOS, and Windows verification**

- [ ] **Step 4: Repeat functional and UI parity spot checks**

- [ ] **Step 5: Dispatch a final whole-branch code review**

- [ ] **Step 6: Mark findings closed only with evidence links**

- [ ] **Step 7: Use superpowers:finishing-a-development-branch for integration choices**

