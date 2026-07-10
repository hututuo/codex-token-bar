# Tauri/Rust/TypeScript auxiliary tool scan - v0.7.2

Date: 2026-07-10 (Asia/Shanghai)  
Worktree: `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2`  
Branch at start: `audit/v0.7.2-full-project...origin/main [ahead 9]`

## Scope and evidence rule

This was a read-only auxiliary scan. No product source, test, manifest, config, or release file was edited. No auto-fix option was used. Cargo-generated ignored artifacts under `target/` were allowed. I did not read any human audit report.

Tool output below is treated as a lead, not a product conclusion. Candidate items were retained only after inspecting the cited production source. No candidate in this report should be treated as a release blocker without a focused behavioral check.

Working directories used below:

- Rust commands: `tauri-app/src-tauri`
- TypeScript commands: `tauri-app`
- Cross-language commands: worktree root

## Execution matrix

| Tool | Version / toolchain | Exit | Result |
|---|---:|---:|---|
| cargo clippy | active Rust 1.93.1 | 1 | Active stable toolchain lacks `cargo-clippy`; no compilation occurred. |
| cargo clippy fallback | Rust 1.92.0, already installed | 101 | Completed lint compilation; `-D warnings` promoted 25 Clippy diagnostics to errors. |
| cargo-machete | 0.9.2 | 0 | No unused Cargo dependencies found. |
| cargo llvm-cov | 0.8.7 | 130 | Canceled when the tool attempted a global `llvm-tools-preview` install; no trustworthy coverage report produced. |
| cargo-modules graph | 0.26.0 | 0 | Rust module dependency graph generated. |
| cargo-modules acyclic | 0.26.0 | 1 | Stopped on an item-level false positive involving a type and its own `default` method. |
| dependency-cruiser | 18.0.0 | 0 | 179 modules, 356 dependencies, zero unresolved imports; TypeScript support enabled via `NODE_PATH`, with no config written. |
| Knip production | 6.24.0 | 1 | `Unused files (52)`, `Unused exports (26)`, `Unused exported types (11)`; most file noise is unconfigured test entry points. |
| Biome full check | 2.5.2 | 1 | 262 errors, 15 warnings, 3 infos; dominated by formatting and import-organization baseline. |
| Biome lint-only companion | 2.5.2 | 1 | 36 errors, 15 warnings, 3 infos after disabling formatter and assist. |
| jscpd full | 5.0.11 | 1 | 109 clones; 3.54% duplicated lines across Rust/TS/TSX/MJS. |
| jscpd production-oriented companion | 5.0.11 | 1 | 58 clones; 2.28% duplicated lines after excluding test files. |
| lizard-complexity | 1.23.0 | 1 | 42 threshold warnings: 15 Rust (one in a test file) and 27 TS/TSX. |

Non-zero scanner exits indicate diagnostics or the documented environment/tool failure; they are not equivalent to product test failures.

## Exact commands and observed statuses

### 1. cargo clippy

```bash
cargo clippy --all-targets --all-features -- -D warnings
# exit 1: cargo-clippy is not installed for stable-aarch64-apple-darwin

cargo +1.92.0 clippy --all-targets --all-features -- -D warnings
# exit 101: 25 lint diagnostics promoted by -D warnings
```

The fallback used the already-installed Rust 1.92.0 toolchain because it already contained Clippy. The active Rust 1.93.1 toolchain was not modified. Diagnostics were mostly idiom/maintainability rules (`question_mark`, `while_let_loop`, `too_many_arguments`, `let_and_return`, `type_complexity`, `useless_conversion`). Examples include `src/core/live_rate/rollout.rs:360`, `src/core/quota_history/series.rs:151`, and `src/platform/surfaces.rs:293`. None is promoted here as a correctness defect from Clippy alone.

### 2. cargo-machete

```bash
cargo machete
# exit 0
```

Result: no unused Cargo dependencies were found in `tauri-app/src-tauri`.

### 3. cargo llvm-cov

```bash
env -u CARGO_LLVM_COV_SETUP cargo llvm-cov --all-features --all-targets --json --summary-only --output-path target/llvm-cov/tauri-tool-scan-summary.json
# exit 130 after cancellation
```

The command attempted to run `rustup component add llvm-tools-preview --toolchain stable-aarch64-apple-darwin`. It was interrupted to preserve the read-only/global-state boundary. The component remained uninstalled. The one 30,051,636-byte Rustup `.partial` download created by the attempt was removed, and the installed-component list and clean tracked worktree were rechecked. Xcode provides LLVM 17.0.0, while the available Rust 1.92.0 compiler uses LLVM 21.1.3, so Xcode's `llvm-cov` was not substituted.

### 4. cargo-modules dependency and cycle analysis

```bash
cargo modules dependencies --all-features --lib --no-externs --no-fns --no-sysroot --no-traits --no-types --layout dot --max-depth 3
# exit 0

cargo modules dependencies --all-features --lib --no-externs --no-fns --no-sysroot --no-traits --no-types --layout dot --max-depth 3 --acyclic
# exit 1

cargo modules dependencies --all-features --lib --no-externs --no-fns --no-owns --no-sysroot --no-traits --no-types --layout dot --max-depth 3 --acyclic
# exit 1, same false positive
```

The graph exposed the expected `commands`, `core`, `models`, and `platform` areas. Both acyclic attempts stopped before useful module-cycle analysis on:

```text
FloatingContentVisibilitySnapshot -> FloatingContentVisibilitySnapshot::default -> FloatingContentVisibilitySnapshot
```

This is an item/associated-method ownership loop, not evidence of a Rust module import cycle.

### 5. dependency-cruiser

The scanner portion of the successful no-config command was:

```bash
NODE_PATH="$PWD/node_modules" depcruise --no-config --ts-config tsconfig.json --include-only '^src' --output-type json src
# JSON was piped to an in-memory Node summarizer; pipeline exit 0
```

An initial run without `NODE_PATH` also exited 0 but was invalid for TypeScript analysis: `depcruise --info` showed `.ts` and `.tsx` support disabled, and that run saw only 78 modules/41 dependencies. It was discarded. With project TypeScript exposed through `NODE_PATH`, the final run found:

- 179 modules and 356 dependencies.
- Zero unresolved imports.
- Two unique cycles, emitted as four directed cycle edges: `dashboardState.ts` with `dashboardDefaults.ts`, and `dashboardState.ts` with `dashboardMergers.ts`.
- 13 orphans: 12 standalone `.test.mjs` entry files plus `src/vite-env.d.ts`; no production orphan was inferred from this list.
- Bidirectional top-level boundary signals for `api <-> components`, `components <-> floating`, and `state <-> components`.

### 6. Knip production scan

```bash
knip --production --no-progress --reporter compact --max-show-issues 200
# exit 1

knip --no-progress --reporter compact --max-show-issues 200
# exit 1; companion run produced the same result because no test-runner entries are configured
```

Of the 52 files labeled unused, 50 are `*.test.mjs`, one is `src/test/ssrHarness.mjs`, and one is production source: `src/diagnostics/useCommandDiagnostics.ts`. Production mode also reports helpers intentionally consumed only by tests, such as `__resetCodexRadarCacheForTests`; those are test-consumer noise, not automatic deletion candidates.

### 7. Biome check, no write

```bash
biome check src --max-diagnostics=none --reporter=summary
# exit 1: 262 errors, 15 warnings, 3 infos; no fixes applied

biome check src --formatter-enabled=false --assist-enabled=false --max-diagnostics=none --reporter=summary
# exit 1: 36 errors, 15 warnings, 3 infos; no fixes applied

biome check src --formatter-enabled=false --assist-enabled=false --max-diagnostics=none --reporter=concise
# exit 1; line-level form of the same lint-only diagnostics
```

The full total includes formatting differences across the 179 scanned files and 50 import-organization diagnostics. The lint-only run is the useful signal set.

### 8. jscpd

```bash
jscpd --format rust,typescript,tsx,javascript --min-lines 8 --min-tokens 60 --mode strict --reporters console --no-colors --no-tips --exit-code 1 tauri-app/src-tauri/src tauri-app/src
# exit 1: 109 clones, 1,418 duplicated lines / 40,051 lines (3.54%)

jscpd --format rust,typescript,tsx,javascript --min-lines 8 --min-tokens 60 --mode strict --ignore '**/*.test.mjs,**/*_tests.rs,**/tests.rs' --reporters console --no-colors --no-tips --exit-code 1 tauri-app/src-tauri/src tauri-app/src
# exit 1: 58 clones, 674 duplicated lines / 29,611 lines (2.28%)
```

Production-oriented breakdown: Rust 45 clones/3.54% duplicated lines; TypeScript 10/1.33%; TSX 3/0.50%; JavaScript 0 after test exclusion.

### 9. lizard complexity

```bash
/Users/huyiyang/.local/bin/lizard-complexity -l rust -l typescript -l tsx -C 15 -L 100 -a 7 -w tauri-app/src-tauri/src tauri-app/src
# exit 1: 42 warnings
```

Thresholds were CCN >15, function length >100, or parameters >7. This is a hotspot inventory, not a defect count.

## Source-validated candidates

### C1. Generic control groups have labels that assistive technology may not expose

Confidence: medium. Category: accessibility.

Biome flagged `aria-label` on generic `div` elements. Source inspection confirms control-group labels on elements without a semantic group role:

- `tauri-app/src/components/CacheHitRanking.tsx:44` uses `<div className="ranking-controls" aria-label="...">`.
- `tauri-app/src/components/RecentUsageChart.tsx:156` and `:184` do the same for range and line-toggle groups.

The child buttons are individually named, so this is not a claim that the controls are unusable. The candidate is that the intended group labels are likely ignored. A focused accessibility pass should choose an appropriate `fieldset`/`legend`, `role="group"`, or tab semantics and verify with the target screen reader.

### C2. Codex Radar's API layer depends on a component-owned domain model

Confidence: high as an architecture signal; no runtime defect claimed.

- `tauri-app/src/api/codexRadarClient.ts:1` imports normalization, parsing, status, and types from `components/codexRadar/model`.
- `tauri-app/src/api/codexRadarDetailClient.ts:1` imports the same component-owned model.
- `tauri-app/src/components/CodexRadarStrip.tsx:2` imports both API clients.

dependency-cruiser therefore reports `api -> components` and `components -> api` top-level edges. There is no direct file cycle in this trio, but the boundary direction makes API code depend on UI ownership and increases change coupling. Moving the model/parsers to a neutral domain folder is a maintainability candidate, not an automated release finding.

### C3. Two source-confirmed dead-code candidates remain in production files

Confidence: high for unreferenced status; impact low.

- Knip reports `tauri-app/src/diagnostics/useCommandDiagnostics.ts`; repository search finds only its own declaration at line 8. `src/app/surfaceState.test.mjs:97` explicitly asserts that the dashboard data path does not include `useCommandDiagnostics`, which suggests deliberate removal from the active path but leaves the hook file behind.
- Biome reports `modelPointSummary` at `tauri-app/src/components/CodexRadarStrip.tsx:1096`; repository search finds no call site.

Neither file/function is bundled merely because it exists. Confirm whether they are intentionally retained compatibility/debug surfaces before deleting them.

### C4. Rust live-rate rollout parsing is a corroborated maintenance hotspot

Confidence: high as a maintenance hotspot; correctness risk unproven.

`tauri-app/src-tauri/src/core/live_rate/rollout.rs:165` begins `rollout_line_metrics`, which spans through line 357. Lizard measured 186 NLOC/CCN 30. jscpd independently found repeated event-handling shapes at lines 193-229 and 239-281, while Clippy flagged the 9- and 10-argument event constructors at lines 360 and 386.

The source confirms a single function dispatching multiple rollout record/payload combinations with repeated early-return construction. Existing tests cover response-item deduplication, missing response-item fallback, reasoning exclusion, tool-output exclusion, and per-session rate caps (`core/live_rate_tests.rs:503` onward), which materially lowers immediate regression concern. This is a refactoring candidate only with those behavior tests preserved and expanded; no parsing bug is asserted here.

### C5. Quota-history query branching duplicates schema-sensitive SQL

Confidence: high as drift risk; no current query mismatch found.

`tauri-app/src-tauri/src/core/quota_history/database.rs:81` defines `matching_rows`, measured by Lizard at 125 NLOC. Lines 87-203 contain four branches that repeat the selected column list and substantial predicates. jscpd found a 31-line/243-token clone between the account-name branches and additional smaller clones in the same function.

Manual comparison did not reveal a current column-order mismatch. The candidate is future drift: adding a selected field or changing account matching requires synchronized edits across four SQL blocks. Coverage could not be measured in this lane, so branch-level execution evidence is unavailable.

## Likely false positives and baseline noise

- The dependency-cruiser `dashboardState` cycles are type-only on the reverse edges: `dashboardDefaults.ts:12` and `dashboardMergers.ts:11` use `import type { DashboardAppState }`. They do not form a JavaScript runtime cycle after TypeScript erasure. They may still matter to a strict source-graph policy.
- cargo-modules' `FloatingContentVisibilitySnapshot <-> default` report is an associated-item ownership artifact, not a module cycle.
- Knip's 51 test entry/harness files are configuration noise caused by the absence of test-runner entry patterns. Production-mode unused exports also include test-only helpers.
- Biome's `floatingContent.ts:107` callback warning is neutralized by the closed five-member `FloatingContentGroup` union (`types/settings.ts:17`) and an exhaustive switch.
- Biome's `codexRadar/model.ts:890` prototype warning is already using the safe `Object.prototype.hasOwnProperty.call(...)` form.
- Biome's `CodexRadarStrip.tsx:1017` SVG is inside an `aria-hidden="true"` wrapper, so the missing SVG title is not exposed to accessibility APIs.
- The hook dependency warnings at `useDashboardData.ts:331` and `useCompactPanelQuota.ts:65` are intentionally narrowed to the two reset timestamps; `nextQuotaResetRefreshDelayMs` reads only those fields (`utils/quotaRefresh.ts:10-17`).
- The three `updateFloatingVisible` dependency warnings in `useFloatingWindowSurface.ts` point to a render-local helper that only updates a ref and React state. Source inspection did not identify stale captured business data.
- Lizard reports `codexRadarSurfaceStatus` at CCN 36/82 NLOC, but the function actually occupies `components/codexRadar/model.ts:372-387` and contains four short status branches. This is a TypeScript parser/span artifact. Rust's `diagnostic_category` CCN 36 is real branching, but it is a lexical error-category classifier rather than an automatically unsafe control flow.
- jscpd's full result includes 51 clones removed by the production-oriented companion, mostly repeated test fixtures and assertions. Repetition percentages are not defect rates.

## Coverage gaps

No fresh production-file coverage percentage or per-file summary exists from this run. Consequently, this report does **not** name any Rust module as demonstrably uncovered.

The coverage evidence gap is itself conspicuous: `llvm-tools-preview` is absent from both installed Rust toolchains, and the read-only lane could not authorize its global installation. A trustworthy rerun requires a pre-provisioned compiler-matched LLVM tools component. Until then, any claim that a specific Rust module is covered or uncovered would be speculative.

Static source review did confirm tests around the live-rate rollup hotspot, but that is not a substitute for line/region coverage and is not reported as a percentage.

## Unfinished checks and limitations

1. `cargo llvm-cov` remains unfinished. Required follow-up: provision `llvm-tools-preview` for the selected Rust toolchain outside this read-only lane, then rerun the exact coverage command.
2. Clippy results came from already-installed Rust 1.92.0 because active stable 1.93.1 lacks Clippy. The diagnostics are useful, but this is not a same-toolchain Clippy proof for the active compiler.
3. cargo-modules could generate the graph but its built-in acyclic gate could not get past the associated-item false positive. No Rust module-cycle absence claim is made.
4. dependency-cruiser was globally installed and warned about transpiler locality. `NODE_PATH="$PWD/node_modules"` enabled the project's TypeScript 6.0.3 without installing or writing config; the successful 179-module run supersedes the incomplete first run.
5. No tests, builds, fixes, staging, commits, or human-report comparisons were performed; they were outside this auxiliary tool lane.

## Final git status

Command (run from the worktree root after writing this report):

```bash
git status --short
```

Verified output (exit 0):

```text
?? audits/v0.7.2/reports/tauri-tool-scan.md
```
