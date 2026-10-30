# Homepage scroll performance audit — GPT-6.1 Sol / max

## Scope and evidence boundary

Starting source: `codex/dashboard-header-client-identity`, `dea70b3a7208fb95f68a301b46c400cd2fc79eeb`.
The installed process profiled by the root agent was `/Applications/Codex Token Bar.app/Contents/MacOS/CodexTokenBar`, PID 92225, 0.9.7 build 979, on macOS 27.0.1. Installed code and the working source are separate gates.

This worker inspected Swift and React sources, analysed the root agent's read-only process sample, added focused React regressions and a synthetic numeric projection benchmark, and proposed production changes for the root agent to integrate. No application installation/restart, native GUI automation, database migration/write change, reporter change, new dependency or external API request was performed by this worker.

## Native findings

Evidence: `scratch/20261030-homepage-scroll/scroll.sample.txt`. Root captured a nominal 10-second sample at 5 ms while performing an ordinary upward scroll. The main-thread call graph contains 1,200 sampled observations. These are statistical inclusive stack counts, not presented FPS or a CPU benchmark; overlapping parent/child counts must not be summed.

| Main-thread path | Observations | Interpretation |
| --- | ---: | --- |
| `CodexUsageStore.configureSessionMutationMonitor` callback → `loadContinuityLoss` | 175 / 1,200 | Synchronous safety-store work ran on the main actor during this scroll window. |
| The same path → `migrateLegacyContinuityLossesIfNeeded` → safety database `load` | 77 | Even an already migrated record opens a connection to check for authoritative data. |
| The same path → `continuityLosses` → safety database `load` | 98 | The same callback then opens another connection to retrieve the record again. |
| Largest `UpdateCycle.continueProcessing` branch | 317 | Framework layout/render work is present. This stack alone does not identify which visual element is responsible. |
| `DashboardView.dashboardContent` at its cost-cache branch | 16 | Historical model-cost preparation is visible but much smaller in this sample than the safety read path. |

`SQLiteDatabaseDriver.withUncoordinatedConnection` opens/closes SQLite and calls `installBusinessStore` for every load. In these stacks, that setup descends into `sqlite3ReadSchema` / `sqlite3InitOne` and schema parsing. The trace does not establish a SQLite busy timeout as the cause. The process also had an exact usage scan running on a background worker; this is an active workload, not idle power evidence. Physical footprint was 1.0 GB, peak 1.6 GB; this alone does not establish a leak or memory-pressure stall.

Relevant methods:

- `CodexUsageStore.loadContinuityLoss`, `migrateLegacyContinuityLossesIfNeeded`, `continuityLosses`, and `configureSessionMutationMonitor` in `Sources/CodexTokenBar/CodexUsageStore.swift`.
- `SharedAccountUsageSafetyDatabase.load` in `Sources/CodexTokenBar/SharedAccountUsageSafetyDatabase.swift`.
- `SQLiteDatabaseDriver.withUncoordinatedConnection` in `Sources/CodexTokenBar/SQLiteDatabaseDriver.swift`; `SQLiteDatabaseConnection.installBusinessStore` in `Sources/CodexTokenBar/SQLiteStoreConnection.swift`.

Recommended first native change: return the authoritative decoded continuity dictionary from the migration/load helper and consume it directly in `loadContinuityLoss`. For an existing record, keep one current authoritative read per callback. For a missing record, retain the current validation, atomic adoption of a concurrent authoritative record, post-write read-back verification and defaults-retirement checks; return that verified payload without another load. Keep nil as failure and an empty dictionary as healthy absence. Share typed decoding with other callers and retain corruption reporting, health flags and recovery state. Do not cache a record across events or suppress cross-process gap observation.

Also equality-guard repeated assignments to the three published continuity-loss fields and their published persistence-health flag. The current callback republishes identical existing values or nil, which can invalidate the entire dashboard. Continue observing and reading safety state at the existing cadence. A broader asynchronous safety-store design would require separate source/recovery-generation and ordering work.

Existing native safety regressions cover production migration/acknowledgement, typed corruption without deletion, cross-process gap reload, storage recovery and stable legacy UUID migration in `CodexUsageStoreTests`. Compilation and these regressions after production edits belong to root integration; this audit did not run a large Swift build.

### Review of the root's native factoring

Root implemented `loadMigratedContinuityLosses`, shared typed decoding and equality-guarded publication in `CodexUsageStore`. Source review found no blocking safety regression: the existing-payload branch reads the safety database again on each callback; typed corruption still reports an unhealthy safety generation; missing-record migration still validates the defaults source, atomically adopts any concurrent authoritative record, verifies its read-back and checks defaults retirement. Nil still represents a failed read and clears the loss presentation while persistence health remains false. The defaults-only branch now also validates existing data when no source is selected, which detects corruption earlier.

New runtime regression file: `Tests/CodexTokenBarTests/ContinuityReloadPerformanceTests.swift`.

- `testUnchangedDefaultsReloadDoesNotPublishEmptyGapOrRecoveryState`: five unchanged reads each for healthy empty, ordinary gap and storage-recovery records publish no `objectWillChange` events.
- `testUnchangedDatabaseReloadDoesNotPublishEmptyGapOrRecoveryState`: the same check against a disposable durable database.
- `testFreshExternalDatabaseReplacementAndRemovalAreObservedOnEveryReload`: a separate database instance writes distinct records and removal; each fresh read updates the presentation, and the next unchanged read emits nothing.
- `testNewDefaultsCorruptionFailsClosedWithoutReplacingEvidenceOrCachingLastGood`: corruption introduced after a valid read fails closed and stays available as evidence; a later valid legacy/test value is observed.
- `testNewDatabaseTypedCorruptionFailsClosedAndKeepsDurableEvidence`: typed corruption introduced by an independent writer marks persistence unhealthy and clears stale presentation without deleting the stored payload; repeated failed reads do not republish unchanged state.

Verification here: Swift syntax parse passed; a bounded `swiftc -typecheck` passed against the existing cached Debug module and XCTest Swift overlay. That confirms the new test file's types against the cached interfaces, not execution of the changed production implementation. The five new runtime tests remain **NOT_RUN** here until a current-source test build. Suggested focused execution after that build: `swift test --skip-build --filter ContinuityReloadPerformanceTests`. No post-change native latency or FPS result is claimed.

## React findings and bounded measurements

`useClientScope` originally allocates fresh `available` and `allowed` arrays on every render. `DashboardPage` passes `allowed` to the memoized `DashboardAnalyticsSection`, so unrelated live-rate parent renders cross the historical memo boundary.

The new production-hook regression reproduced **21 historical-child renders for the initial render plus 20 unrelated live updates**. It also checks that a real source choice and a newly published enabled client still update membership. Stabilizing the scope arrays must include those real input changes in its key.

`DashboardPage` already computes `projectOriginalDashboard` in a memo. `DashboardAnalyticsSection` originally computes that projection a second time from `originalCodex` and `clients`. The regression instruments the source trend getter and confirms that the extra pass occurs even when a prepared scoped snapshot is supplied. The single projection owner should be `DashboardPage`; standalone fixtures and development previews must project explicitly before passing their snapshot. The original Codex snapshot remains a separate quota/money provenance input.

Synthetic benchmark command:

```sh
node scripts/benchmark_homepage_projection.mjs --output scratch/20261030-homepage-scroll/projection-benchmark.json
```

Node v26.4.0; four warmups and 20 timed samples per size. The benchmark calls the actual pure TypeScript projection and validates that every represented input bucket remains in the output.

| Codex bins + Claude CLI bins | Output five-minute bins | Median | p95 | Maximum |
| --- | ---: | ---: | ---: | ---: |
| 288 + 288 | 288 | 0.466 ms | 1.014 ms | 2.731 ms |
| 8,640 + 8,640 | 8,640 | 7.750 ms | 10.825 ms | 14.278 ms |

The larger fixture preserves 20,736,000 chart tokens and 17,280 chart calls, with an input-weighted 80% cache hit rate. Removing a redundant projection avoids another complete call when source data changes. These timings exclude React rendering, native SwiftUI, and screen presentation; they do not quantify the installed Mac scroll improvement or Windows FPS.

Focused regressions:

```sh
cd tauri-app
node --test src/multiClient/homepagePerformance.test.mjs
```

Before the root's production edits, all three new tests reproduced their intended performance regressions. After the root stabilized scope arrays and made the analytics component consume the prepared snapshot, all **3 tests passed**. The memoized historical child now renders once across 20 unrelated live updates; real scope/publication changes still propagate. The analytics test verifies zero source-bucket rereads, the supplied aggregate's plotted total, one analytics area and the Codex provenance note. Happy DOM verifies React work and markup, not browser layout or presented frames.

## Existing guards retained

Native `DashboardView` already uses a lazy section stack, has stopped observing every `LiveRateMonitor` publication, and caches multi-client usage/model-cost projections. `BodySpeedTrendContent` has an equatable input; `RecentChartPreparationStore` prepares chart snapshots off the UI thread. Native and React recent charts render their visible history range while retaining the represented history. The audit found no reason to reduce samples or remove product sections.

Decorative animation visibility probes use clipping/occlusion notifications and can pause during scroll. Historical collection and local-rate observations must remain independent of those decoration gates. Multi-client usage refresh is already minute-based and uses background scanning; reducing it would not address the identified callback stack.

All fixes must preserve the one aggregate analytics area, Codex + Claude totals, original Codex quota/money provenance, body TPS distributions/medians and raw three-minute activity points. No AXScrollToTop or AXScrollToBottom operation is part of this audit or its acceptance plan because of the known macOS 27 lazy-list accessibility crash.

## Integration status

- Native installed baseline sample: captured by root and analysed here.
- React regression before fixes: 3 expected failures, confirming both identity invalidation and duplicate preparation.
- Synthetic pure projection benchmark: passed all data-preservation checks.
- React source changes: integrated by root; the new focused suite passes 3 / 3, with no skips.
- Native factoring: implemented by root and reviewed here with no blocking safety finding. Five new runtime regressions added; syntax and cached-interface typechecking pass, runtime execution remains pending a current-source build.
- Installed candidate/native visual acceptance and Windows execution: not performed by this worker.
