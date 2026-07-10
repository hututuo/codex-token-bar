# Automated Tool Findings - Commander Triage

## Boundary

The Swift and Tauri scanner reports are auxiliary search indexes. Every item below was reclassified after manual source review; scanner counts are not defect counts and do not change human coverage status.

## Accepted Follow-Ups

| Lane | Tool signal | Manual conclusion | Action |
|---|---|---|---|
| Swift | `AccountQuotaReader.swift` 0/582 covered lines | Critical subprocess/JSON-RPC path has no hermetic transport test. Existing tests cover binary discovery and diagnostic models, not the process handshake or noisy stderr. This corroborates the already confirmed stderr/cancellation risks. | Extract a fake process/line transport seam in the quota batch; test initialize/read/error/timeout/cancellation/noisy stderr. |
| Swift | `CodexUsageStore.refresh` CCN/length hotspot | Real change-risk concentration, but existing stale-generation/source tests prevent calling it a current defect. | Extract pure publication/recovery decision model only while repairing source provenance; no broad rewrite. |
| Swift | `TaskCompletionScanner.parseNewLines` hotspot | The scanner led to a manually confirmed partial-tail bug: incomplete final records are consumed by advancing offset to EOF. | Fix with a red two-phase append fixture in the unread/task batch. |
| Swift | repeated first-line/subagent JSONL helpers | Real semantic-drift debt across usage, unread, and task readers. | After correctness fixes, introduce a small shared bounded JSONL helper only where malformed/tail policy is identical. |
| Swift | disconnected v5 cache loader chain | High-confidence stale migration residue; current code still deletes old v5 cache but no longer calls its loader/converters. | Confirm the supported upgrade window in release history, then remove the unreachable loader/types as a behavior-neutral cleanup commit. |
| Swift | unread ripple/shimmer duplicated lifecycle/cache plumbing | Real duplication, but effect-specific rendering and zero UI coverage make a merge risky. | Defer until runtime profiling/visual fixtures exist; do not refactor during correctness batches. |
| Tauri | generic `div[aria-label]` control groups | Intended group labels on cache-ranking and recent-chart controls may not reach accessibility APIs because no group role/fieldset semantics exist. Child controls remain individually named. | Verify in the UI/AX pass, then use `fieldset/legend`, `role=group`, or tab semantics with one focused accessibility test. |
| Tauri | API imports `components/codexRadar/model` while component imports API | Confirmed architectural inversion and change coupling, not a runtime bug. | Move Radar parsing/types/status model to a neutral domain module when Radar is next modified; preserve public/full endpoint separation tests. |
| Tauri | `useCommandDiagnostics.ts` and `modelPointSummary` unreferenced | High-confidence dead production source; one source test explicitly asserts the hook is not wired. | Remove in a low-risk cleanup batch with build and focused source/SSR tests. |
| Tauri | `rollout_line_metrics` complexity/duplication | Confirmed maintenance hotspot with meaningful existing behavior tests; no new parser defect established by tools. | Refactor only after live-rate WAL/refcount/dedupe fixes add missing edge fixtures. |
| Tauri | quota-history SQL branch duplication | Four schema-sensitive query branches repeat column lists/predicates; no current mismatch found. | Extract a tested shared query builder after identity migration is designed, not before. |

## Rejected Or Non-Actionable Noise

- SwiftLint's dominant line-length and short geometry-name findings are style baseline, not correctness evidence.
- Periphery's decoded/assigned-only Radar and presentation fields are mostly schema-tolerance state; they are not blanket deletion candidates.
- Knip's 50 test files and SSR harness are unconfigured-entry noise.
- Biome's formatter/import findings are not a release defect and should not trigger a repository-wide formatting churn.
- dependency-cruiser `dashboardState` cycles are type-only reverse edges erased by TypeScript; no runtime cycle was established.
- cargo-modules stopped on a type/associated-`default` ownership loop, not a Rust module cycle.
- Lizard's SwiftUI/Canvas complexity values are prioritization hints, not proof of UI failure.
- TSan produced no product race evidence: the instrumented XCTest helper crashed before the first test, including a minimal control test.
- Rust coverage is unknown in this run because the matching `llvm-tools-preview` component was intentionally not installed by a read-only worker.

## Tooling Debt Decision

- Do not adopt raw SwiftLint/Biome/Knip output as a CI gate until project-owned configurations define entries, generated/Codable surfaces, and accepted formatting.
- Keep Clippy and dependency tools as advisory until the active Rust toolchain includes matching components and warnings are triaged into a stable baseline.
- Coverage targets must be module/risk based. A global percentage would reward presentation-line execution while leaving subprocess, lifecycle, and native-window boundaries untested.
