# Swift / Tauri Target-State Parity Review

## Status

- Baseline: released `v0.7.2` source at `e48930a626679230d5d52267c830812f254fdd26`.
- Method: Commander cross-compare of independent blind reviews, context-aware reviews, source traces, current macOS screenshots, and accepted product decisions.
- Automatic scanner reports are auxiliary and still pending. They cannot independently change any row to “confirmed”.
- This is a target-state matrix, not a mechanical “copy Swift to Tauri” list.

## Decision Labels

- **Catch up:** one lane already has the accepted healthy behavior.
- **Common fix:** both lanes share the same defect or missing invariant.
- **Redesign:** neither lane is a safe template; define one shared contract first.
- **Runtime gate:** source evidence is insufficient without native/UI/lifecycle proof.
- **Policy decision:** product semantics must be chosen before code changes.

## Core Data And Lifecycle

| Topic | Swift v0.7.2 | Tauri v0.7.2 | Target state | Decision |
|---|---|---|---|---|
| Codex Home transition | Usage/quota have generation guards, but Dashboard does not reset live monitor; failed new-source loads can retain old snapshots under a new label | Main source action does not notify compact surfaces or advance all load generations; compact quota is source-blind | One source-transition coordinator; cancel/reset every source-owned reader; old data may remain only with explicit old-source provenance | Common fix |
| Trusted `总/今/次` | Precise JSONL aggregate is the source of truth; metadata fallback does not invent totals | Same intended source, but date/offset change can drop trusted summary to pending and compact lifecycle can clear it | Preserve only semantically safe fields during same-source rebuild; never use live-rate or SQLite totals; cold-start pending only | Redesign |
| Local-day/UTC projection | Signature includes local day/offset and rebuilds | Trusted compact scope includes date/offset and rejects immediately | Separate source identity from calendar projection; total survives, today/request are recomputed or conservatively reset while one rebuild runs | Redesign |
| Archived sessions in historical usage | Current scope needs explicit confirmation | Active sessions and active rollout paths only | Decide whether “consumed historically” or “currently visible sessions” is the product scope; then implement both lanes with migration/dedupe tests | Policy decision |
| Fork replay | 2-second grace now matches the dense replay regression target | 2-second grace with focused fixtures | Keep current policy until a stronger real event boundary is proven; characterize exact threshold only | Aligned/accepted |
| Cache persistence | Swift append/cache policy is stronger but complex | Tauri has Windows replace failures in aggregate/cache state | Shared cache invariants; platform-correct atomic replace; cache errors observable but rebuildable | Common fix |

## Quota And History

| Topic | Swift v0.7.2 | Tauri v0.7.2 | Target state | Decision |
|---|---|---|---|---|
| CLI discovery | Bundle ID + bounded app scan + PATH/override | Bundle ID + LaunchServices + bounded app scan + PATH/override | Preserve both platform-appropriate implementations and executable/identity validation | Aligned |
| App-server stderr | Pipe is drained only after timeout/termination | Pipe is drained only after deadline/cleanup | Continuously drain a bounded stderr tail while stdout JSON-RPC proceeds; timeout remains the primary category | Common fix |
| Cancellation | Cancelled store task does not stop synchronous child read/retry | Backend source-keyed gate serializes reads, but caller cancellation is limited | Child lifecycle owned by a cancellable request; source switch terminates obsolete work; no retry after cancellation | Common contract |
| User cadence | Timer/cooldown now derive from selected cadence | Frontend cadence is masked by a fixed backend five-minute success cache | One freshness policy derived from requested cadence; in-flight dedupe remains | Tauri catch up |
| Unavailable quota | Optional window model can express unavailable | Placeholder encodes unavailable as real 0% | Explicit availability/provenance; unknown never renders as exhausted | Tauri catch up |
| History identity | Shared DB but canonicalizes readable plans to fake `Pro` | Uses actual plan but display-name identity can collide and failure can load global latest history | Versioned key: stable account subject + canonical source + actual plan; bounded legacy migration bridge | Redesign |
| History overlay horizon | Long chart/history behavior is closer to intended shared timeline | 30-day 5-minute usage canvas receives only 24h quota overlay | One explicit horizon/bucket/carry contract for usage and quota in both lanes | Tauri catch up after contract |
| Post-reset carry | Existing behavior may synthesize 100% beyond the last sample | Same class of policy ambiguity | Decide carry duration and reset-boundary interpolation before editing either lane | Policy decision |

## Live Rate And Unread

| Topic | Swift v0.7.2 | Tauri v0.7.2 | Target state | Decision |
|---|---|---|---|---|
| Source switch | Monitor reset implementation exists but Dashboard wiring omits it | Registry/service resolves global source; surface transition wiring is incomplete | Source-local thread/log/rollout/fingerprint/rate state resets exactly once on source identity change | Common fix |
| SQLite replacement/WAL | Same-path logs DB replacement is not acted on | Rollout thread cache ignores `state_5.sqlite-wal` | File identity includes replacement/WAL reality plus bounded TTL; no stale IDs across rotations | Common fix |
| Stream/rollout dedupe | Fingerprints differ for streamed delta vs rollout `agent_message` | Has its own dual-source dedupe but task/refcount lifecycle is fragile | Shared per-lane normalized visible-event identity; repeated genuine text remains distinct | Common fix |
| Stream ownership | One monitor object per Swift surface composition; multi-window duplication remains open | Global refcount/running flag can duplicate loops or let one cleanup cancel another | Explicit per-subscriber lease + one generation-owned loop; Windows/macOS native tests | Tauri redesign, Swift runtime gate |
| Selected/all-session cap | Per-selected cap and all-session sum are intentional | Same intended semantics | Keep; do not introduce a global 80 tok/s cap | Aligned/accepted |
| Native unread baseline | Baseline prunes IDs that leave native set, but native authority can remain sticky after source becomes unavailable | Persisted IDs never prune after leaving native set | Baseline lifecycle prunes departed IDs and can recover from native-state loss | Common fix |
| New completion in continuously unread thread | Completion scan is bypassed while native unread state is available | Completion markers are fallback-only | Merge post-baseline completion markers with native identity without double-counting/subagent alerts | Common redesign |
| Partial JSONL tail | Task scanner consumes incomplete tail offset | Recent completion scanners need equivalent audit/fixture | All append scanners retain incomplete final record until newline/valid boundary | Swift confirmed; cross-lane guard |
| Always-visible mark-all-read | Dashboard button is conditional | Dashboard button is always present with active/idle tone | Primary dashboard button always visible, blue when unread and gray when idle; compact policy separately space-tested | Swift catch up |

## Provider Repair And Data Safety

| Topic | Swift v0.7.2 | Tauri v0.7.2 | Target state | Decision |
|---|---|---|---|---|
| Running Codex guard | Advisory only; engine still mutates | Advisory only; writes can race Codex/WAL | Engine-level final guard immediately before mutation; optional expert override only if explicitly designed | Common fix |
| Operation serialization | Store serializes one UI instance, engine has no global guard | Frontend busy/timeout only; Rust can overlap operations | Backend single-flight per canonical Codex Home, with operation ID and uncertain timeout state | Common fix |
| Backup freshness | Creates a fresh backup inside sync | UI promises fresh backup but Tauri reuses an arbitrary older backup | Every mutation creates and returns a fresh consistent recovery point | Tauri catch up |
| SQLite consistency | Uses SQLite backup/VACUUM-style path, but active-writer guard is absent | Copies main/WAL/SHM independently, ignores sidecar errors, restores main only | SQLite online backup or stopped-writer snapshot; restore exactly what was validated | Tauri redesign, Swift harden |
| Target provider | Structured Swift config path is safer | `(missing)` sentinel and ad-hoc TOML parsing can select invalid target | Structured config parse; absence remains `nil`; provider value validated before all writes | Tauri catch up |
| Post-write verification | Verification can throw outside rollback and ignores invalid files | Verification/rollback transaction boundaries also need strengthening | Mutation + verification is one recoverable transaction; invalid input cannot vacuously pass | Common fix |
| Session file replacement | macOS-specific Swift path works but needs concurrent append re-stat | Windows rename-over-existing fails | Cross-platform atomic replace with pre-write signature check and temp cleanup | Common contract |
| Rollback archive scope | Tar members extract from filesystem root without member validation | Full-file rollback can overwrite newer data and has WAL inconsistency | Stage, validate canonical members, confirm backup/source identity and freshness, then atomically restore | Common redesign |
| Backup identity | UUID suffix avoids same-second collision | Second-only ID can collide | Collision-resistant create-new IDs in both lanes | Tauri catch up |

## UI, Surfaces, And Accessibility

| Topic | Swift v0.7.2 | Tauri v0.7.2 | Target state | Decision |
|---|---|---|---|---|
| Preparation layout | Stable stat-strip slot after recent fix | Stable header slot after recent fix | No dynamic rows that shift the dashboard; true failures remain separately actionable | Aligned, runtime regression check |
| Floating hidden lifecycle | Controller/monitor ownership still needs closed-window profiling | Hidden webview keeps quota/live/unread/Radar work active | Hidden/disabled surfaces quiesce work but keep last trusted presentation for reopen | Common runtime fix |
| Floating scale | Window controller receives interface scale, root view recomputes from plain stored scale | CSS/native scaling needs narrow and DPI review | One size model per lane; no disagreement between native host and content | Swift confirmed, Tauri runtime gate |
| Heatmap accessibility | One grouped accessibility element | Every day is a button/tab stop | Grouped chart or roving one-tab-stop selection; pointer range behavior preserved | Tauri catch up |
| Status surface | Native status popover exists and owns long-lived Swift stores | Status panel is unreachable from tray; tray live text is dashboard-owned | Tray/status lifecycle owned outside dashboard webview; close/reopen preserves trusted metrics | Tauri redesign |
| Updater error UI | Sparkle path native to macOS | macOS debug shows raw Windows updater platform error in dense header | Unsupported platform hides background check; supported failures use bounded copy plus diagnostics | Tauri fix |
| 24h chart browse/tooltip | Scroll model is accepted reference, trackpad state still needs runtime proof | Long canvas/date range implemented; hover/drag/narrow acceptance incomplete | Fixed panel size, real long history, visible dates, non-clipped tooltip, keyboard/trackpad support | Runtime gate |
| Responsive density | Current Swift capture usable; compact control pressure remains to test | Quota cadence/header are improved but narrow dashboard remains unverified | Screenshot matrix across minimum/common/large sizes, light/dark, localization, error states | Common UI gate |

## Updater And Release

| Topic | Swift v0.7.2 | Tauri v0.7.2 | Target state | Decision |
|---|---|---|---|---|
| Automatic reminder | Sparkle automatic-check preference exists | One silent check 5s after Dashboard mount, then no focus/wake/periodic check | Startup + wake/focus + several-hour persisted minimum interval; background check never auto-installs | Tauri catch up |
| Private-key custody | Sparkle key remains Mac-local | Repository Windows script requires updater private key on Windows, contradicting actual v0.7.2 process | Windows builds unsigned installers + manifest; Mac signs updater artifacts and metadata | Tauri fix |
| Version consistency | Release script verifies app/feed candidate | PowerShell parameter can differ from package/Cargo/Tauri versions | Hard preflight across tag, parameter, manifests, binary version, architecture, hashes | Tauri catch up |
| Release tests | Swift candidate suite was run outside packaging script | Windows release script does not run Rust/Node suites | One release gate invokes lane suites or verifies a signed CI attestation before packaging | Common process fix |

## Runtime Confirmation Queue

1. Windows x64 and ARM64: autostart, tray, close/reopen, second-instance activation, floating/status windows, updater install/relaunch, file replacement.
2. macOS Swift/Tauri: source switch with two real fixture Homes; sleep/wake; date/UTC-offset transition; long-running live-rate DB/WAL rotation.
3. Provider disposable fixtures: active WAL, concurrent append, timeout/retry, rollback member validation, corrupt backup, Codex-running guard.
4. UI: minimum/common/large window sizes, light/dark, keyboard traversal, VoiceOver/AX tree, heatmap, long-chart trackpad/hover, floating/status reopen.
5. Performance: hidden surfaces, large history CPU/RSS/IO, multi-window Swift ownership, event animation main-thread cost.

## Repair Order

1. Provider data-safety and backend serialization.
2. Cross-source provenance and settings atomicity.
3. Quota freshness/history identity/unavailable state.
4. Unread baseline and partial-tail correctness.
5. Live-rate ownership, WAL/replacement, and dedupe.
6. Windows filesystem/release pipeline correctness.
7. UI/accessibility/lifecycle parity and native runtime closure.
