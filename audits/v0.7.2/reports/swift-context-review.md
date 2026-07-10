# Swift/macOS v0.7.2 Context-Rich Manual Review

## 1. Review Identity

- Review lane: Swift context-rich manual review
- Audit worktree: `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2`
- Audit branch: `audit/v0.7.2-full-project`
- Released product tag/commit reviewed: `v0.7.2` / `e48930a626679230d5d52267c830812f254fdd26`
- Audit HEAD at report-writing start: `e4d42d2d7e99f20b16d34551895262e8eaf705f7`
- Audit HEAD at final verification: `97de69c1519c1b68d89c90bb9f1e2098067f9d55`
- Source identity check: `git diff --quiet e48930a -- Sources Tests Package.swift Package.resolved` returned success. The reviewed Swift source and tests are byte-identical to the released product.
- Method: manual source reads, call tracing, focused search, existing-test inspection, and Git history/blame. No SwiftLint, Periphery, duplication scanner, mutation tool, build, test run, app launch, network request, or real Provider operation was used in this lane.

The audit branch changed concurrently while this review was in progress: another lane added commit `e4d42d2` and untracked UI evidence. I did not read, modify, stage, or incorporate those reports/screenshots. This report is based only on the released source, its tests, and its Git history.

## 2. Actual Exploration Scope

The review covered all 112 Swift product files at a business-flow level and inspected all 34 XCTest files as a coverage map. Deep reads followed the paths below rather than treating files as isolated units:

- App lifecycle and orchestration: `CodexTokenBarApp`, `DashboardView`, menu-bar entry, startup behavior, refresh planning, login item, update settings.
- Data-source resolution: selected Codex Home, security-scoped bookmark, environment/default/one-level discovery, source propagation into usage, quota, unread, live rate, and ProviderSync.
- Usage totals: session discovery, active `state_5.sqlite.rollout_path`, JSONL incremental parsing, fork replay suppression, persistent per-session cache, snapshot cache, metadata-only fallback, daily/recent/hourly aggregates, compact/status provenance.
- Quota/account: CLI discovery, app-server JSON-RPC, diagnostics, stale-success preservation, reset credits, cadence, quota-history persistence, monotonic repair, chart projection.
- Live rate: SQLite global log, rollout fallback, poll plan, source attribution, cross-source dedupe, bounded token estimation, per-session cap/all-session aggregation, selected session, display surfaces.
- Radar: public summary, authenticated detail path, RSS partial failure, scheduled refresh, diagnostics/stale state, dashboard/detail/compact presentation.
- ProviderSync: scan, session/index/SQLite repair, backup, rollback, operation-generation guards, fixture tests.
- Unread/task completion: official unread-state reader, JSONL fallback scanner, read baseline, status/floating surfaces.
- Charts and secondary features: heatmap, cache-hit ranking, quota estimator, horizontal chart history, CSV/PNG exporter, status/floating window lifecycle.
- Infrastructure and release-facing boundaries: SQLite driver, package dependencies, Sparkle entry points, entitlements and packaging references. Release scripts were read only as boundaries; release validation was not rerun.

This is sufficient to identify cross-boundary correctness and lifecycle risks in the released Swift product. It is incomplete for visual fidelity, live endpoint compatibility, real AppKit accessibility behavior, real Provider write/rollback behavior, Sparkle installation, and large-data runtime performance; those require later dedicated lanes.

## 3. Flow Maps And Invariants

### 3.1 Usage / total-today-request flow

```text
CodexDataSourceResolver
  -> selected bookmark / CODEX_HOME / ~/.codex / bounded home scan
  -> CodexUsageStore (generation + source-id guarded refresh)
  -> CodexUsageAnalyzer
       -> sessions/**/*.jsonl
       -> active state_5.sqlite rollout_path values
       -> SessionEventCache v8 / namespace swift-usage-cache-2026-07-v3
       -> fork replay suppression + token_count deltas
       -> daily/recent/hourly/cache/session/turn aggregates
  -> DashboardSnapshot(precise | metadataOnly)
  -> dashboard / TokenDisplaySnapshot / floating / status bar
```

Invariants confirmed:

1. Trusted `总 / 今 / 次` comes from `CodexUsageStore.snapshot`, not from live-rate totals and not from `threads.tokens_used` metadata (`TokenDisplaySurface.swift:180-196`).
2. `state_5.sqlite` fallback deliberately reports zero token totals with `usagePrecision == .metadataOnly`; compact surfaces show `待读取` rather than invented totals (`CodexUsageAnalyzer+StateSQLite.swift:42-74`, `TokenDisplaySurface.swift:199-216`).
3. A cache offset beyond a shortened file cannot be incrementally reused: `appendableSession` requires the cached offset to fit both cached/current sizes, otherwise that file is fully reparsed (`CodexUsageAnalyzerModels.swift:164-177`).
4. Fork history is skipped until a user message is at least two seconds after the last skipped replay token, and that replay state persists in the per-session cache (`CodexUsageAnalyzer+SessionParsing.swift:247-280`, `CodexUsageAnalyzerModels.swift:39-45`).
5. The persistent cache stores prompt/response digests, not raw content (`CodexUsageAnalyzerModels.swift:48-58`). This is an intentional privacy boundary.

### 3.2 Quota / history flow

```text
CodexDataSource
  -> CodexBinaryLocator
  -> codex app-server (CODEX_HOME propagated)
  -> account/rateLimits/read + reset-credit read
  -> AccountQuotaStore (source/generation guard, stale-success diagnostics)
  -> QuotaMonotonicNormalizer
  -> QuotaHistoryStore / quota-history.sqlite
  -> dashboard strip / compact quota / chart / estimator
```

Invariants confirmed:

1. Changing or clearing the selected Codex Home invalidates an in-flight old-source quota read (`AccountQuotaStore.swift:95-107`).
2. Automatic cadence changes reschedule the timer without forcing an immediate read; in-flight same-source reads do not overlap (`AccountQuotaStore.swift:126-164`, `250-254`).
3. A failed fresh read preserves an available previous snapshot and exposes stale diagnostics (`AccountQuotaStore.swift:215-239`).
4. Quota retry is quota + quota history only; it does not trigger usage/radar/provider work (`DashboardRefreshPlan.swift:89-105`).
5. Reset-credit count and future expiry are separated: unknown/past expiry may count as available but cannot manufacture a nearest-expiry summary.

### 3.3 Live-rate flow

```text
logs_2.sqlite stream rows -----------+
                                      +-> attribution + cross-source/item dedupe
active rollout JSONL fallback -------+-> RateAccumulator
                                          -> selected session raw rate (display capped at 80)
                                          -> per-session rates summed for all-session display
                                          -> EMA display smoothing
                                          -> dashboard / floating / status surfaces
```

Invariants confirmed:

1. A poll may read both stream and rollout; one source does not suppress distinct output from the other (`LiveRateMonitor.swift:364-384`).
2. Bottom-level accumulation is not globally capped. Selected-session display is capped; all-session display sums per-session capped values (`LiveRateMonitor.swift:720-735`).
3. Missing attribution maps to one stable unattributed display bucket (`LiveRateMonitor.swift:737-740`).
4. Tool output, patch result, and hidden reasoning do not drive visible speed; visible output/tool arguments/patch input follow explicit category policy (`RateAccumulator.swift:350-366`).
5. Stream deltas and a later full rollout completion sharing the same item key use cumulative `itemTokens`, so a normal full completion adds only an unobserved remainder rather than blindly recounting the full text (`RateAccumulator.swift:220-235`).
6. Source changes clear thread/log/rollout/fingerprint/accumulator state; unchanged sources do not reset unnecessarily (`LiveRateMonitor.swift:180-229`).

### 3.4 Radar / Provider / unread flow

- Radar public summary is unauthenticated; full detail is a separate scheduled/manual path. Root and RSS failures preserve last-good data and expose distinct stale states.
- ProviderSync store serializes destructive operations and uses an operation generation guard. Engine backup precedes mutation in the normal sync path.
- Unread prefers official `.codex-global-state.json`; if unavailable, it scans appended `task_complete` JSONL events and applies a persisted read baseline.

## 4. Confirmed Findings

### High 1: A distributable app contains a recoverable shared Radar bearer credential

- Evidence: `Sources/CodexTokenBar/CodexRadarStore.swift:73-81` attaches an Authorization header for the full-detail endpoint; `:94-114` reconstructs the bearer value entirely from constants shipped in the binary.
- Impact: anyone who obtains the open-source code or app can reconstruct and reuse the credential outside the app. Obfuscation changes discoverability, not secrecy. Abuse, revocation, or a server-side scope change can break every installed client at once.
- Trigger: inspect the binary/source and execute the deterministic reconstruction.
- Confidence: high. The report intentionally does not reproduce the credential or obfuscation material.
- Suggested reproduction: in an isolated security review, assert that the authorization value can be reconstructed from public client code without reading user secrets; do not call the live endpoint.
- Missing test/gate: release-time policy rejecting embedded long-lived bearer material; architecture test for a server-mediated or user-Keychain credential path.
- Suggested direction: keep public summary unauthenticated; move privileged detail access behind a server-controlled proxy/ephemeral token, or require a user-provided Keychain credential. Rotate the distributed credential after migration.

### Medium 1: Task-completion scanning permanently skips a record read while its JSONL line is only partially written

- Evidence: `TaskCompletionScanner.parseNewLines` decodes the entire appended tail and attempts to parse every split segment, including a non-newline-terminated final segment (`TaskCompletionScanner.swift:160-173`). Regardless of parse success, it advances `state.offset` to the file size captured before the read (`:224`).
- Impact: a `task_complete` record caught mid-write is never reconstructed on the next poll, so fallback unread/task-completion notification can be missed permanently.
- Trigger: the two-second monitor poll reads after the first bytes of a JSON object are appended but before its newline/rest is flushed.
- Confidence: high; this is a normal append race, not a malformed-input-only case.
- Suggested reproduction: write half of a valid `task_complete` line, scan, append the remainder plus newline, scan with returned state; expect exactly one event. Current code yields zero.
- Missing test: partial trailing line retention/replay in `TaskCompletionScannerTests`.
- Suggested direction: advance only through the last complete newline and retain the incomplete byte offset, matching the safe offset behavior already used by usage and rollout parsers.

### Medium 2: Live-rate thread discovery is startup/manual-reset-only, so a newly created Codex session stays absent

- Evidence: `threadOptions` is populated only by `resetToLatestThread()` (`LiveRateMonitor.swift:231-269`). Normal `poll()` refreshes logs and iterates the existing options, but only calls reset when `threadID` is empty (`:321-338`, `:390-400`). Search found no periodic state-DB revision check or option refresh.
- Impact: after the app starts, a newly opened Codex session may not appear in the session selector, the selected-session display can remain attached to an old session, and rollout-only fallback output from the new session is omitted from all-session rate when no usable SQLite stream row exists.
- Trigger: leave Token Bar running, start a new Codex session, then produce output that is present only in the new rollout JSONL.
- Confidence: high.
- Suggested reproduction: start with state DB thread A; after monitor preparation add newer thread B + rollout data; poll without manual reset. B remains absent.
- Missing test: state DB gains a newer thread during monitoring and options/rollout readers refresh without resetting the entire source.
- Suggested direction: add a low-frequency state-DB signature/mtime-based thread refresh that merges new options and offsets without discarding active rates.

### Medium 3: Quota history rewrites every Codex-plan identity to `Pro|codex`

- Evidence: `canonicalCodexIdentity` accepts any nonempty `planType` when `limitName` is empty/codex, then returns `("Pro", "codex")` unconditionally (`QuotaHistoryStore.swift:758-763`). `row` and `accountKey` persist that canonical value (`:418-425`, `:749-755`). Tests cover only `Pro`/`pro` legacy-key consolidation.
- Impact: Plus, Team, Business, or future plan types are mislabeled as Pro and can be merged into the same account-history identity. Curves and monotonic normalization may join samples that should remain separate across tiers.
- Trigger: a successful quota snapshot with account name X, `planType != Pro`, and empty/codex limit name.
- Confidence: high at the model level; whether current production accounts emit those plan strings requires live fixture confirmation.
- Suggested reproduction: record two snapshots for the same account, one Plus and one Pro; inspect persisted keys and loaded history.
- Missing test: preserve non-Pro plan identity while still normalizing case and old Pro keys.
- Suggested direction: canonicalize casing/limit aliases without changing the semantic plan tier; migrate only explicitly recognized legacy Pro keys.

### Medium 4: Official unread-state loss leaves the monitor stuck on stale official data and ignores its own fallback scan

- Evidence: once `hasCodexUnreadState` becomes true, `.unavailable` does not clear or age that authority (`TaskCompletionMonitor.swift:197-201`). A fallback scan still runs on unavailable reads (`:120-135`), but recomputation always prefers the old official set (`:189-194`), so newly scanned completions cannot affect the count.
- Impact: if `.codex-global-state.json` is temporarily unreadable or partially rewritten, unread count can freeze and new task completions remain invisible until official state returns.
- Trigger: one successful official unread read followed by an unavailable read plus a valid fallback completion event.
- Confidence: high.
- Suggested reproduction: apply `.available([])`, then apply `.unavailable` with one fallback event; expected count is one in degraded mode, current count remains zero.
- Missing test: official-success -> unavailable -> fallback event transition in `TaskCompletionMonitorTests`.
- Suggested direction: model official state as available/stale/unavailable with a bounded grace; after loss, either merge fallback events or explicitly degrade to fallback authority.

### Medium 5: Touch/trackpad chart scrolling does not update button and edge-fade state

- Evidence: arrow enablement and fades derive from `scrollWindowIndex` (`RecentUsageChart.swift:342-418`). That state changes only in `scrollChart(by:)` and `scrollChartToLatestIfNeeded` (`:661-689`). The native horizontal `ScrollView` has no offset/position binding or geometry callback.
- Impact: after manually scrolling to older data, the right arrow may remain disabled and the right “newer data exists” fade may stay hidden; controls and visual affordances describe the old programmatic position rather than the actual viewport.
- Trigger: use a trackpad/mouse horizontal scroll instead of the arrow buttons.
- Confidence: high from state ownership.
- Suggested reproduction: open a multi-window history range at latest, manually scroll left, then inspect right arrow/fade.
- Missing test/seam: scroll-offset-to-window-index model and behavior test. Current tests exercise only pure button index shifting and static fade states.
- Suggested direction: bind scroll position on supported macOS SwiftUI APIs or measure content offset and derive the current window index from it.

### Medium 6: Provider rollback trusts archive membership and extracts at filesystem root

- Evidence: session backup stores paths relative to `/` (`ProviderSyncEngine+Backups.swift:58-62`). Rollback validates only mutable `manifest.json` Codex Home text (`:129-142`) and extracts the archive with `tar -C / -xf` without inspecting members (`:153-165`). The public engine rollback also accepts an arbitrary backup path.
- Impact: a modified/crafted backup can overwrite user-writable paths outside the selected Codex Home. Even without privilege escalation, this violates the feature's stated data-safety boundary.
- Trigger: tamper with a backup archive/manifest or pass a matching external backup directory before rollback.
- Confidence: high for the validation gap; exploitation requires local backup tampering or an untrusted backup source.
- Suggested reproduction: disposable home only. Create an archive containing a path outside the fixture Codex Home and a matching manifest; verify rollback currently extracts it.
- Missing tests: reject backup outside the managed backup root; reject `..`, absolute, symlink, or non-Codex-Home archive members.
- Suggested direction: require canonical backup-root containment, list/validate every archive member, extract to a staging directory, then copy only allowlisted Codex Home paths.

### Medium 7: `WindowGroup` allows independent dashboard stores/monitors to coexist and compete for shared compact controllers

- Evidence: each `DashboardView` owns fresh usage/quota/history/radar/provider/unread/live objects (`DashboardView.swift:9-15`), while the app-level floating/status controllers are shared (`CodexTokenBarApp.swift:6-10`). The scene is a multi-instance `WindowGroup` and does not replace the New Window command (`CodexTokenBarApp.swift:23-45`).
- Impact: opening another dashboard can duplicate timers, JSONL scans, quota app-server processes, Radar requests, and unread polling. Shared floating/status controllers can be rebound by whichever window updates last, creating inconsistent source/state presentation.
- Trigger: create a second dashboard window via standard macOS window commands or repeated scene opening.
- Confidence: medium-high; manual AppKit confirmation of the exact menu path is still needed.
- Suggested reproduction: open two dashboards and instrument store initializers/read counts; confirm independent refresh loops and compact controller rebinding.
- Missing test: singleton/coordinator ownership or a single-window scene contract.
- Suggested direction: use a single shared app model for data stores, or switch the dashboard to a single-instance `Window`/disable New Window if multiple dashboards are not a product requirement.

### Low 1: Status-bar title still drops the required decimal at 10 tok/s and above

- Evidence: `TokenDisplaySnapshot.statusBarTitle` rounds values >=10 to `Int` (`TokenDisplaySurface.swift:219-227`), while main/floating formatting and `LiveRateSnapshot.rateDisplayText` preserve one decimal. The status-bar accessibility text also preserves one decimal (`StatusBarTokenPanel.swift:132-146`).
- Impact: the visible menu-bar number disagrees with other surfaces and hides small changes, undermining parity/debugging.
- Trigger: any rate >=10, e.g. 40.4 displays as `40/s` in the title but 40.4 elsewhere.
- Confidence: high.
- Missing test: `statusBarTitle` examples for 10.1, 42.4, and 80.0.

### Low 2: Status-bar controller rebuilds the popover root view every 0.5 seconds even when nothing changed

- Evidence: the repeating timer fires at 0.5 seconds (`StatusBarTokenPanel.swift:64-70`), and `updateStatusItem()` reassigns `hostingController.rootView` before the presentation equality guard (`:100-123`).
- Impact: unnecessary main-thread SwiftUI tree replacement continues while the status surface is enabled, including when the popover is closed. This is avoidable background work and can complicate state continuity.
- Trigger: enable status-bar mode and leave the app idle.
- Confidence: high for repeated reconstruction; actual CPU cost requires profiling.
- Missing test/seam: snapshot/presentation-change gating before root-view replacement.

### Low 3: Export failures are silently discarded

- Evidence: CSV and PNG writes use `try?` and return no user-visible result (`Exporter.swift:7-20`, `:23-44`). Rendering failure also returns silently.
- Impact: users may believe an export succeeded when permission, disk, or encoding failure prevented it.
- Trigger: select a read-only destination, fill the disk, or force PNG conversion failure.
- Confidence: high.
- Missing test: injected writer failure and surfaced error presentation.

## 5. Suspected Issues / Product Decisions

### S1. Plain non-JSON app-server stdout can abort quota reading

`JSONLineReader.next` performs a throwing `JSONSerialization` call on the next line (`AccountQuotaReader.swift:533-547`). Structured JSON log lines are safely ignored by ID logic, but a plain-text stdout warning would throw out of `readOnce` and likely classify as unknown. This needs a process/pipe seam test with mixed plain noise + valid JSON-RPC before changing behavior; current known Codex warnings are often JSON or stderr.

### S2. Quota timeout termination can wait forever on an uncooperative child

After deadline, the reader calls `terminate()` then unconditionally `waitUntilExit()` (`AccountQuotaReader.swift:178-182`). A child that ignores SIGTERM can keep a detached quota task and in-flight state alive indefinitely. Add a process abstraction and bounded terminate/kill escalation test before modifying this sensitive path.

### S3. Recent quota bins mix calendar-day subtraction with a fixed 720-hour count

`QuotaHistoryStore.makeSnapshot` computes start as 30 calendar days before now, then emits exactly `30 * 24 * 12` fixed five-minute bins (`QuotaHistoryStore.swift:290-305`). In a DST timezone the start-to-now duration can be 719 or 721 hours, producing a one-hour shortfall/overhang and misalignment with usage bins. This is irrelevant in non-DST zones but should be covered with `America/Los_Angeles` fixtures before changing historical semantics.

### S4. Post-reset quota projection is a product assumption, not observed data

For any sample whose reset date has passed, history returns 100% even without a post-reset observation (`QuotaHistoryStore.swift:493-507`). That gives a useful continuous line, but it can temporarily invent a reset that the account server did not confirm. Decide whether the chart is an observed series or an observed-plus-projected series; if projection remains, mark it visually/semantically.

### S5. Precise usage failure and normal metadata-only preparation are not distinguishable

`CodexUsageAnalyzer.load()` uses `try?` for precise JSONL and silently falls back to state SQLite (`CodexUsageAnalyzer.swift:22-39`). The UI correctly avoids fake totals, but a persistent permission/schema/parser failure can look like ordinary “still reading” forever. A structured precise-failure reason would improve diagnosis without changing totals.

### S6. Hard-coded estimator prices need a freshness policy

`QuotaConsumptionEstimator.swift:9-46` embeds model prices without an effective date or remote/versioned source. This is not a correctness finding without checking current official prices, which this offline source audit intentionally did not do. Add a displayed price date and a release checklist/table test if the feature is retained.

### S7. Provider tar creation can exceed argument-size limits on very large histories

`createSessionTar` passes every session path as a single `Process.arguments` array (`ProviderSyncEngine+Backups.swift:58-62`). A Codex Home with enough session files can exceed `ARG_MAX`, causing backup/sync to fail safely before mutation. Prefer a file list/stdin or an archive API; add a many-file fixture.

## 6. Testability And Coverage Risks

- Seven test files still read production source text and assert string fragments: `CodexRadarViewPlacementTests`, `CodexUsageStoreTests`, `DashboardRefreshPlanTests`, `FloatingUnreadEffectsTests`, `LiveRateMonitorTests`, `QuotaConsumptionEstimatorTests`, and `StartupPresentationTests`.
- The largest brittle clusters are Radar layout placement and floating/live-rate visual wiring. These can detect deleted text but cannot prove runtime state transitions, scroll position, window multiplicity, or accessibility behavior.
- Existing test strength is high in usage fork/cache logic, quota store source guards, Radar stale state, Provider store generations, RateAccumulator math, and refresh planning.
- The most valuable missing behavior fixtures correspond directly to confirmed findings: partial JSONL tail, dynamic live thread discovery, non-Pro quota identity, official-unread loss, native chart scroll position, archive-member containment, and multi-window ownership.

## 7. Rejected Or Stale Concerns

1. **Fork sessions still count copied history:** rejected for current source. Two-second replay-exit grace, cached replay state, dense replay fixtures, and active state rollout inclusion are present (`CodexUsageAnalyzer+SessionParsing.swift:247-320`; analyzer tests around dense/append replay cases).
2. **Metadata-only SQLite totals are presented as precise:** rejected. SQLite fallback totals are zero and precision is explicit; compact metrics render `待读取`.
3. **Live rate has a global 80 tok/s cap:** rejected. Only per-session selected display is capped; all-session sums session display rates.
4. **One live source suppresses the other:** rejected. Poll plan can read SQLite and rollout in the same cycle, and item-token cumulative state prevents a later full completion from blindly recounting observed stream deltas.
5. **RateAccumulator re-tokenizes unbounded full output:** rejected. It uses a 96-character overlap and fractional carry (`RateAccumulator.swift:150-181`).
6. **Malformed rollout/task timestamps synthesize current-time spikes:** rejected for current source. Both paths require valid timestamps; targeted tests exist.
7. **Source switching leaks old live/quota/usage state:** rejected for the reviewed guards. Each core store has generation/source identity protection; live rate explicitly clears source-local offsets/fingerprints/accumulators.
8. **Persistent usage cache stores raw prompts/responses:** rejected. Persistence stores digests; restoring raw content would violate the current privacy decision.
9. **Session cache loads while holding its lock through disk I/O:** rejected. Current implementation does disk loading outside the lock, then double-checks/merges under lock (`CodexUsageAnalyzerModels.swift:364-399`).
10. **Radar date labels are hard-coded to 2026:** rejected. Current parser validates arbitrary four-digit years and tests 2027/2031.
11. **Codex CLI/App discovery depends only on fixed Codex.app path/name:** rejected. Current locator supports explicit override, bundle identity, bounded Applications scans, known names, Homebrew/PATH, executable/symlink validation; Provider running-app matching prefers bundle identity.
12. **Radar root/RSS failures erase useful prior data:** rejected. Root and feed stale states preserve last-good snapshot/feed and expose diagnostics.

## 8. Recommended Repair Order

1. **Unread correctness batch:** retain incomplete TaskCompletionScanner lines; model official unread loss and fallback authority. Run `TaskCompletionScannerTests` + `TaskCompletionMonitorTests`.
2. **Live-rate dynamic session batch:** add state-DB signature-driven thread-option refresh without resetting rates. Run `LiveRateMonitorTests` + `RateAccumulatorTests`.
3. **Quota identity/history batch:** preserve non-Pro tiers; add migration-safe identity tests and DST/projection decision tests. Run `QuotaHistoryStoreTests` + `QuotaMonotonicNormalizerTests`.
4. **Chart interaction batch:** make viewport position observable and drive arrows/fades from actual offset. Run `QuotaConsumptionEstimatorTests`, then manual trackpad/mouse acceptance.
5. **Provider data-safety batch:** stage and validate archive members/root containment; replace argv-sized tar input. Run only disposable `ProviderSyncEngineTests` fixtures.
6. **App ownership/performance batch:** single dashboard store ownership, status popover update gating, one-decimal title. Run targeted lifecycle/presentation tests, then profile one dashboard and two-window attempts.
7. **Credential architecture gate:** decide server proxy/user credential and rotate the distributed Radar detail key. This is not an ordinary client-only refactor.

## 9. Uncovered Areas And Closure Plan

Not covered by this lane:

- Pixel-level dashboard/floating/status/Radar/chart visual acceptance and real accessibility navigation.
- Live Codex app-server, CodexRadar endpoints/RSS, Sparkle feed/install, login-item approval, or network-failure behavior.
- Real user Codex Home contents, real Provider writes/rollback, or private runtime databases.
- Runtime CPU/RSS/file-I/O profiling with large histories and multiple dashboard windows.
- Signing, notarization, Gatekeeper, updater asset integrity, and cross-platform/Tauri parity.

Closure should use separate disposable/runtime lanes: targeted XCTest fixes first, temporary Codex Home integration fixtures second, manual UI/accessibility and performance acceptance third, and release/security checks last.

## 10. Final Change Statement

This review made no changes to product source, tests, runtime processes, app bundles, user Codex data, release metadata, tags, remotes, updater state, or Tauri. The only file created by this lane is this report. At final verification, `git status --short --branch` showed `audit/v0.7.2-full-project` ahead of `origin/main` by 6 and three untracked reports: this report plus `swift-blind-review.md` and `tauri-blind-review.md`; the latter two belong to concurrent lanes and were not modified or consumed here.
