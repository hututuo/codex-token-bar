# Swift automated auxiliary scan: Codex Token Bar v0.7.2

Date: 2026-07-10

## Scope and interpretation boundary

- Report output tree: `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2`
- Swift command tree: `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/swift-usage-cache-and-refresh-cadence`
- Swift command tree HEAD: `8368d87` on `feature/quota-consumption-estimator`
- No product source, tests, manifests, configuration, or release material were edited.
- No auto-fix was run. No files were staged or committed.
- Existing human audit reports were not read.
- Tool output is treated as a search index. This report does not declare a production defect from scanner output alone.

Environment:

| Tool | Version |
|---|---:|
| Apple Swift | 6.2.1 (`swiftlang-6.2.1.4.8`) |
| Apple LLVM / llvm-cov | 17.0.0 |
| SwiftLint | 0.65.0 |
| Periphery | 3.7.4 |
| JSCpd | 5.0.11 |
| lizard-complexity | 1.23.0 |

No `.swiftlint`, `.periphery`, or `.jscpd` project configuration was present, so tool defaults apply.

## Execution summary

| Check | Exit | Result |
|---|---:|---|
| Strict-concurrency isolated scratch preflight | 1 | Dependency checkout stopped before compilation: missing TiktokenSwift Git LFS object. |
| Strict-concurrency compile and full tests using dependency-complete `.build` | 0 | Build succeeded; 322 XCTest tests passed; no strict-concurrency warning/error was emitted. |
| SwiftPM native coverage | 0 | Build succeeded; 322 XCTest tests passed; coverage JSON generated. |
| SwiftLint strict | 2 | 629 findings: 459 production, 170 tests. Most are style/size rules. |
| Periphery raw strict | 1 | 235 findings. |
| Periphery noise-filtered strict | 1 | 65 findings after retaining Codable, SwiftUI previews, and assign-only properties. |
| JSCpd over `Sources Tests` | 0 | 138 clones; 1,486 duplicated lines (3.86%). |
| JSCpd production-focused triage | 0 | 11 clones; 312 duplicated lines (1.09%) at 8-line/80-token thresholds. |
| lizard-complexity over `Sources Tests` | 1 | Six functions exceeded default warning thresholds. |
| Focused TSan core suite | 1 | Instrumented build succeeded; XCTest helper crashed with signal 11 before any test started. |
| Minimal TSan control test | 1 | Same pre-test signal 11, confirming a test-harness/environment blocker for this run. |

## Exact commands and statuses

All commands below were run from the Swift command tree unless stated otherwise.

### Strict concurrency

First attempt, using an isolated scratch path:

```sh
swift test --scratch-path .build/audit-strict-concurrency -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency
```

Exit `1`. SwiftPM stopped while checking out TiktokenSwift, before compiling product code:

```text
Error downloading object ... TiktokenFFI ...
remote missing object f458581ebf9ae3efb39c6ab7b3739f3abf6d0c4ab45324112c38994d05f06610
error: external filter 'git-lfs filter-process' failed
```

The existing default `.build/checkouts/TiktokenSwift` contained the dependency-complete macOS XCFramework, so the diagnostic was rerun serially against that cache:

```sh
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency
```

Exit `0`: build complete; 322 tests, 0 failures; no strict-concurrency diagnostics.

### SwiftPM native coverage

```sh
swift test --enable-code-coverage
swift test --show-codecov-path
```

Both exited `0`. The first command passed 322/322 tests. SwiftPM reported:

```text
.build/arm64-apple-macosx/debug/codecov/CodexTokenBar.json
```

Coverage aggregation used the LLVM JSON summaries, filtered by source path:

```sh
jq -r 'def totals($needle): [.data[0].files[] | select(.filename | contains($needle))] as $fs | {files:($fs|length), lines_count:($fs|map(.summary.lines.count)|add), lines_covered:($fs|map(.summary.lines.covered)|add), functions_count:($fs|map(.summary.functions.count)|add), functions_covered:($fs|map(.summary.functions.covered)|add), regions_count:($fs|map(.summary.regions.count)|add), regions_covered:($fs|map(.summary.regions.covered)|add)}; {production:totals("/Sources/CodexTokenBar/"), tests:totals("/Tests/CodexTokenBarTests/")}' .build/arm64-apple-macosx/debug/codecov/CodexTokenBar.json
```

Exit `0`.

### SwiftLint

```sh
swiftlint lint --strict --reporter xcode Sources Tests
```

Exit `2`. A second read-only JSON-reporter pass was summarized with `jq`; it also exited `2` because strict findings remained.

### Periphery

Raw scan:

```sh
periphery scan --format xcode --relative-results --disable-update-check --strict
```

Exit `1`, 235 issues.

Noise-classification scan, reusing the completed index:

```sh
periphery scan --skip-build --format xcode --relative-results --disable-update-check --strict --retain-codable-properties --retain-swift-ui-previews --retain-assign-only-properties
```

Exit `1`, 65 issues. The 170 findings removed by this pass are high-probability Codable/presentation/assigned-only noise, not established dead code.

### JSCpd

Full requested pass:

```sh
jscpd --reporters console --min-lines 5 --min-tokens 50 Sources Tests
```

Exit `0`: 144 files, 38,529 lines, 138 clones, 1,486 duplicated lines (3.86%).

Production-focused triage:

```sh
jscpd --reporters console --min-lines 8 --min-tokens 80 Sources
```

Exit `0`: 108 files, 28,624 lines, 11 clones, 312 duplicated lines (1.09%).

### lizard-complexity

```sh
/Users/huyiyang/.local/bin/lizard-complexity -l swift -w Sources Tests
```

Exit `1`, with six warnings listed below.

### ThreadSanitizer

Focused stores/live-rate/provider pass:

```sh
swift test --sanitize thread --filter '(AccountQuotaStoreTests|CodexRadarStoreTests|CodexUsageStoreTests|QuotaHistoryStoreTests|LiveRateMonitorTests|ProviderSyncEngineTests|ProviderSyncStoreTests)'
```

Exit `1`. The TSan-instrumented package built successfully, then `swiftpm-xctest-helper` exited with signal 11 before a suite or test began.

Minimal control:

```sh
TSAN_OPTIONS='verbosity=1' swift test --sanitize thread --filter 'RateAccumulatorTests/testDeltaAccumulatorCountsOnlyNewTokens'
```

Exit `1` with the same pre-test failure and empty helper output:

```text
error: signalled(11): .../swiftpm-xctest-helper .../CodexTokenBarPackageTests.xctest ... output:

```

This run provides no dynamic race result. The reproducible blocker is the Apple SwiftPM/XCTest helper startup crash in the current Swift 6.2.1 environment, not a test-observed product race.

## Coverage summary

| Scope | Files | Lines | Functions | Regions |
|---|---:|---:|---:|---:|
| Production `Sources/CodexTokenBar` | 110 | 10,573 / 36,145 (29.25%) | 1,424 / 3,924 (36.29%) | 3,315 / 8,796 (37.69%) |
| `Tests/CodexTokenBarTests` | 34 | 11,345 / 11,441 (99.16%) | 2,853 / 2,905 (98.21%) | 3,525 / 3,599 (97.94%) |
| All instrumented files, including generated/dependencies | - | 21,932 / 48,521 (45.20%) | 4,279 / 6,964 (61.44%) | 6,848 / 12,727 (53.81%) |

LLVM reported zero branch counters for this Swift build, so branch coverage is unavailable.

Selected core production files:

| File | Line coverage |
|---|---:|
| `AccountQuotaStore.swift` | 300 / 340 (88%) |
| `CodexRadarStore.swift` | 455 / 584 (77%) |
| `CodexUsageStore.swift` | 268 / 613 (43%) |
| `QuotaHistoryStore.swift` | 705 / 841 (83%) |
| `LiveRateMonitor.swift` | 485 / 825 (58%) |
| `ProviderSyncEngine.swift` | 220 / 298 (73%) |
| `ProviderSyncStore.swift` | 167 / 284 (58%) |
| `AccountQuotaReader.swift` | 0 / 582 (0%) |

Conspicuous zero-line production files, sorted by instrumented line count:

| File | Uncovered lines | Classification |
|---|---:|---|
| `DashboardView.swift` | 1,489 | SwiftUI presentation; unit suite does not instantiate it. |
| `AccountQuotaViews.swift` | 1,098 | SwiftUI presentation. |
| `LiveRateView.swift` | 1,022 | SwiftUI presentation. |
| `FloatingPanelAppearanceSettingsView.swift` | 772 | SwiftUI presentation. |
| `SetupGuideView.swift` | 743 | SwiftUI presentation. |
| `ProviderSyncViewComponents.swift` | 740 | SwiftUI presentation. |
| `TokenHeatmap.swift` | 725 | Drawing/presentation. |
| `TokenDisplaySurfaceComponents.swift` | 672 | SwiftUI presentation. |
| `ProviderSyncView.swift` | 614 | SwiftUI presentation. |
| `AccountQuotaReader.swift` | 582 | Non-presentation subprocess/JSON-RPC path; high-signal coverage gap. |

Other large presentation gaps include `FloatingTokenPanel.swift` (488 lines), `FloatingTokenPanel+WindowTargeting.swift` (445), `FloatingUnreadRippleEffect.swift` (417), and `FloatingUnreadShimmerEffect.swift` (374). These gaps warrant UI/integration coverage but do not imply that the UI is broken.

## High-signal reproducible candidates

These are audit candidates for human review or follow-up tests. None is promoted to a production defect by this report.

### 1. Quota app-server transport is entirely outside native test coverage

- Evidence: `AccountQuotaReader.swift` is 0/582 covered lines.
- `AccountQuotaReader.swift:79` starts the core `readOnce` path.
- `AccountQuotaReader.swift:85-110` launches `codex app-server`, wires three pipes, and owns process cleanup.
- `AccountQuotaReader.swift:112-175` performs the JSON-RPC initialize/read handshake and response dispatch.
- `AccountQuotaReader.swift:178-190` handles timeout termination and stderr classification.
- SwiftLint also marks `readOnce` at line 79 with cyclomatic complexity 11.
- The existing reader tests found by symbol search cover binary location and diagnostic classification, not a fake app-server transport or the handshake state machine.

Assessment: high-confidence release test gap around a critical external-process boundary. No failing behavior was observed.

### 2. Refresh and parser orchestration have concentrated branch/state risk

`CodexUsageStore.refresh(includePreciseScan:)`:

- `CodexUsageStore.swift:56`
- lizard: 143 NLOC, CCN 30, length 147.
- SwiftLint: cyclomatic complexity 18 and function body length 141.
- File line coverage: 43%.
- Manual read confirms that lines 64-88 handle in-flight cancellation/no-source state, lines 90-109 set loading/cache state, and lines 110-200 combine fast snapshot, precise snapshot, stale-generation guards, error preservation, and final state cleanup.
- Existing tests exercise stale refresh/source replacement, and strict-concurrency tests passed; the candidate is regression concentration, not a demonstrated race.

`TaskCompletionScanner.parseNewLines`:

- `TaskCompletionScanner.swift:136`
- lizard: 82 NLOC, CCN 20, six parameters, length 91.
- File line coverage: 80%.
- The current test file has three behavioral tests focused on malformed/missing timestamps, numeric completion time, and a valid ISO completion event. The branch-rich `task_started`, `user_message`, truncation/offset, and recursive subagent paths are not all represented by those test names.

`ProviderSyncEngine.repairSQLiteThreadTimestamps`:

- `ProviderSyncEngine+SQLiteRepair.swift:105`
- lizard: 64 NLOC, CCN 17, length 69.
- File line coverage: 80%.
- Lines 125-170 combine collision grouping, ordering, transactional updates, rollback, WAL checkpointing, and file mtime repair.

Assessment: three concentrated change-risk locations. The coverage and passing tests reduce, but do not remove, regression risk.

### 3. JSONL/file parsing utilities are duplicated across independent readers

JSCpd production matches and source readback show:

- `CodexUnreadThreadReader.swift:273-290` and `CodexUsageAnalyzer+SessionParsing.swift:448-465` independently implement the same bounded first-line reader.
- `CodexUnreadThreadReader.swift:292-305` and `TaskCompletionScanner.swift:256-269` independently implement recursive subagent detection.
- SwiftLint's `optional_data_string_conversion` also identifies lossy UTF-8 decoding at `CodexUnreadThreadReader.swift:289`, `CodexUsageAnalyzer+SessionParsing.swift:464,500,517`, and `TaskCompletionScanner.swift:160`.

Manual classification:

- Loss-tolerant `String(decoding:as:)` is plausible for append-only logs and may be intentional; it is not a defect by itself.
- The duplicated readers operate on related Codex JSONL data but can evolve independently. The high-signal risk is semantic drift in limits, malformed-data policy, and subagent detection.

### 4. An old v5 cache loader appears disconnected from the current load path

Periphery residual findings plus reference search identify:

- `CodexUsageAnalyzerModels.swift:23` `LegacyPersistentEntry`
- `CodexUsageAnalyzerModels.swift:121` `CachedSession.legacy(...)`
- `CodexUsageAnalyzerModels.swift:442` `loadLegacyV5SessionCache()`
- `CodexUsageAnalyzerModels.swift:469,483,581,589,598` conversion helpers used only by that loader chain

No call site for `loadLegacyV5SessionCache()` or `CachedSession.legacy(...)` was found. `legacyV5CacheURL` is still referenced at lines 350-351 to delete the old cache after dirty sessions, so removal policy remains live while the loader itself appears unreachable.

Assessment: high-confidence dead migration residue/maintenance debt, not a current product failure. Any deletion should first confirm the intended v5 upgrade-support window.

### 5. Two unread animation implementations duplicate substantial lifecycle/cache plumbing

- JSCpd's largest production match is `FloatingUnreadRippleEffect.swift:56-165` versus `FloatingUnreadShimmerEffect.swift:48-158`: 110 lines / 549 tokens.
- Additional matches cover render scheduling, animation control, and helper logic.
- Both files have 0% native line coverage.
- Manual read confirms that effect-specific rendering differs, while root-layer setup, layout guards, frame-budget calculation, cache invalidation, render generation, and resize debounce are largely parallel.

Assessment: presentation-maintenance drift candidate. The duplication may be an intentional way to isolate two AppKit effects; no visual or runtime defect was established.

## Tool-specific detail and likely noise

### SwiftLint

629 strict findings break down as follows:

| Rule | Count |
|---|---:|
| `line_length` | 392 |
| `identifier_name` | 50 |
| `function_body_length` | 33 |
| `file_length` | 32 |
| `type_body_length` | 27 |
| `function_parameter_count` | 17 |
| `nesting` | 13 |
| `cyclomatic_complexity` | 11 |
| `implicit_optional_initialization` | 9 |
| `vertical_whitespace` | 8 |
| `large_tuple` | 7 |
| `trailing_comma` | 7 |
| `type_name` | 7 |
| `optional_data_string_conversion` | 6 |
| `force_try` | 4 |

Noise classification:

- 392 line-length findings dominate the result and are not behavioral evidence.
- Short geometry variables such as `x`, `y`, `dx`, and `dy` account for part of `identifier_name` noise.
- `file_length`/`type_body_length` are useful maintenance signals but do not prove incorrect behavior.
- The four `force_try` findings were not in production files in the production-only filtered readback.
- `RecentUsageChart.swift:474` is both long and complex, but it is SwiftUI/Canvas construction with only 4% file coverage; it needs visual/component testing more than a scanner-only defect label.

### Periphery

- Raw: 235 issues.
- After retaining Codable properties, SwiftUI previews, and assign-only properties: 65 issues (64 production, one test).
- The 170-item reduction is the clearest signal that the raw list is dominated by decoded payload fields and presentation snapshots.

Examples of likely noise:

- Numerous `CodexRadarModels.swift` fields are assigned by decoding but not read by the current presentation.
- `FloatingPanelAppearance.swift:962-976` is a persisted presentation snapshot whose fields are assigned during decode/restore.
- `FloatingUnreadFrameCache.swift:46-57` is an encoded/cache key shape.
- `AccountQuotaStore.stop()` is unused in production, but the store timer is app-lifetime state; absence of a call is not proof of a leak.
- Periphery marks the `rollbackLatest` convenience chain unused, while selected-backup rollback is visibly wired at `ProviderSyncView.swift:153-154` and covered by `ProviderSyncEngineTests`. The rollback feature itself is not dead.
- `InitialLoadingOverlay` at `DashboardHeaderView.swift:3` has no production call, and `CodexUsageStoreTests.swift:141` explicitly asserts that the old DashboardView overlay invocation is absent. This is high-confidence stale presentation code, but not a user-facing failure.

Residual candidates worth a deliberate cleanup review include unused one-line convenience overloads, the disconnected v5 migration loader, `LiveRateMonitor.selectThread(_:)`, and obsolete presentation helpers. They should be reviewed against intended compatibility/API surface before removal.

### JSCpd

- Full `Sources Tests` pass: 138 clones / 3.86% duplicated lines.
- Production-only stricter triage: 11 clones / 1.09% duplicated lines.
- Therefore most full-pass clone volume is test fixture/setup duplication.
- Repeated temporary-directory setup, JSONL fixtures, delayed async loaders, and store mocks in tests are often intentional for test isolation.
- The production parser and animation matches described above are the highest-signal drift candidates.

### lizard-complexity

Exact warning list:

| File:line | Function | NLOC | CCN |
|---|---|---:|---:|
| `CodexUsageStore.swift:56` | `refresh` | 143 | 30 |
| `CodexRadarStore.swift:278` | `refresh` | 86 | 16 |
| `ProviderSyncEngine+SQLiteRepair.swift:105` | `repairSQLiteThreadTimestamps` | 64 | 17 |
| `AccountQuotaDiagnostics.swift:176` | `message` | 32 | 17 |
| `TaskCompletionScanner.swift:136` | `parseNewLines` | 82 | 20 |
| `RecentUsageChart.swift:474` | `chartPlotCanvas` | 165 | 20 |

These are review priorities, not failure assertions. `AccountQuotaDiagnostics.message` is largely a formatting switch, and `chartPlotCanvas` is declarative presentation code, so their CCN is less directly predictive of a product bug.

## Unfinished checks and limitations

- TSan dynamic execution is unfinished because the instrumented XCTest bundle cannot start under the current helper; no race pass/fail result exists.
- Native coverage does not exercise most SwiftUI/AppKit view/window paths.
- The quota app-server handshake lacks a hermetic fake-process integration test in the observed suite.
- LLVM branch coverage is unavailable for this build (`branches.count == 0`).
- No runtime UI smoke, signing, packaging, updater, or release check was performed; those are outside this auxiliary scan.
- No scanner finding was converted into a production defect without behavioral reproduction.

## Final git status

Swift command tree:

```text
$ git status --short --branch
## feature/quota-consumption-estimator
```

Only ignored build/coverage artifacts were generated in that tree. Existing ignored `.codegraph`, `backups`, and `dist` paths were not edited intentionally or staged.

Audit report tree:

```text
$ git status --short --branch
## audit/v0.7.2-full-project...origin/main [ahead 11]
?? audits/v0.7.2/reports/swift-tool-scan.md
```
