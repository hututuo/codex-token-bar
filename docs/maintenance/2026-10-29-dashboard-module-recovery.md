# Multi-client dashboard recovery (2026-10-29)

## Fixed policy

- The global selector changes the whole page. Headline usage and model-cost summaries may add selected clients, with their client identities retained.
- Historical analytics are source-owned: aggregate view renders separate Codex / Claude CLI / Claude Desktop sections through the original heatmap and chart components. Codex always receives its original snapshot, attribution, money, quota observations, and request/whole-turn ranking. A non-Codex selection must not disable those capabilities for Codex in aggregate view.
- Claude cache ranking reuses the normalized cache-read/cache-write facts already in B. Cache hits = cache reads / total input; cache writes are not hits. Unknown fields remain unknown. Numeric requests and complete weighted sessions are available; verified whole-turn boundaries are not currently persisted, so requests must not be labeled turns.
- Activity speed: one chart per client, last 30 minutes, one minute per point. Remove the aggregate panel's 5/15/30 minute mean table. The independent Codex body-TPS surface keeps its own metric. No interpolation or invented zero buckets across missing data. Existing five-minute historical rollups remain compatible.

## Storage

Exactly two live business databases remain. A (`codex-ledger.sqlite`) owns original Codex accounting and precise index. B (`multi-client-usage.sqlite`) owns added-client usage and all source-scoped speed telemetry. This is a physical storage boundary, not a change of metric/client ownership.

Completed Codex body speed moves from its old logical A partition into source-namespaced tables in B. Preserve all raw details, dedup IDs, retained five-minute aggregates and retention metadata. Take a consistent retained backup, copy transactionally, verify counts/digest, then write a receipt. Source A is unchanged. A failure must leave the pending measurement revision retryable; no empty-success fallback and no raw-only reconstruction of retained history. Existing B usage and global user_version must remain unchanged. Namespace identity includes the legacy logical source path, preserving old Codex Home separation.

## Sidebar

Auto-collapse is eligible only when unpinned and outside the rail/detail grace union, with no rail drag or settings reorder. Native expanded sidebars periodically reconcile pointer position to recover missed exit events after resize; closed/pinned sidebars do not poll. Delayed collapse rechecks all interaction guards. Tauri's existing presence/reminder watchdogs apply the same reorder/drag guards and resume after release.

## Verification gates

Cloud: full Swift, Rust unit tests, production Rust check, frontend regressions and both installer builds. Disposable migration tests check preservation/idempotence/isolation and failure recovery. Local: actual old-data migration, sidebar hover/exit/pin/resize, visual layout and installed-source identity. Never upload local logs, databases or credentials. Cloud and installed acceptance are separate results.

Precise staged import also reuses one read connection/snapshot across manifest columns, fingerprints, events and chunks per staged source. It preserves all previous validation/admission/commit semantics while reducing repeated physical A schema initialization inside the publication transaction. This complements B isolation; it is not a claim that every historical rebuild is instantaneous.

Hosted compiler: Swift 6.2.1 / Xcode 26.1.1 crashed in IR generation of the actor-isolated `SpeedColorGrouping` binding (SmallVector overflow), while the local compiler is Swift 6.4. Swift checks and macOS packaging now use the runner image's verified stable Xcode 26.6 on macOS 26. Deployment remains macOS 14. The picker setter is an explicit closure rather than an isolated bound method. Unit tests/builds still run in cloud; real user data stays local.

Hosted test compilation additionally unwraps the nullable SQLite scalar in the test count helper and uses explicit typed loops for the performance fixture. These preserve assertions and generated samples.

Windows hosted regressions: source snapshot filenames now hash the complete store/source/version identity into one bounded filename; existing data and recorded backup paths are untouched. Windows broker positioned reads restore the native handle cursor while the broker lock serializes reads, matching Unix read_at semantics. Platform fixtures use native path components and executable suffixes rather than POSIX-only assumptions.

Hosted native UI fixtures now supply deterministic pointer positions so the new missed-exit watchdog does not depend on the runner mouse. A dedicated controller test verifies missed exits, pinning, and settings-reorder release. The morph integration fixture attaches its original SwiftUI rail to a live window and verifies the system motion policy; direct morph tests separately exercise enabled and disabled animation. ModelTrace fake transports inject their executable resolver; production discovery is unchanged. Radar source-contract checks follow the preserved Codex chart anchor after source-owned analytics extraction.

The Windows reporter offline oversized-header fixture starts the read pump before writing its 4097-byte header and bounds the write/wait. Windows anonymous-pipe buffering can otherwise block the fixture before its existing `header_too_large` assertion. Production pipe and reporter behavior are unchanged.

Scroll-pause UI regression uses an injectable monotonic event clock, avoiding wall-time sleeps being interpreted as user idle on loaded hosts; production retains systemUptime. Windows compositor example passes the established base canvas width to the current five-argument API, keeping installer all-target tests compilable.

Follow-up UI: native sidebar panels explicitly use dark Aqua so system segmented controls stay legible on the always-dark sidebar; Tauri scopes the activity-mode text color to its dark detail surface. Ring morphs now preserve an affine ellipse instead of redistributing arc vertices. WebView animates normalized dash intervals along the whole path, preserving actual quota/model fractions and reversal state. Motion uses existing compositor layers/timing and leaves no idle animation. The existing production-component preview is updated in dev-previews/sidebar-squeeze-review.html.

Candidate build971 passed cloud tests/signature verification but failed local launch in SwiftPM Bundle.module while opening the ledger schema. The resource bundle was present at Contents/Resources; generated accessor layout assumptions did not locate it. Restored only application build970, with current databases/preferences intact and the failed candidate retained. The pre-migration audit found 576 old namespaces and zero missing event keys. Actual B body-speed migration remains a local acceptance gate.

All application resource consumers now use one AppResources resolver: resolve the installed signed Resources bundle first, preserve the legacy app-root layout, and use the generated SwiftPM accessor only outside an app. Missing installed resources return an error instead of fatalError/developer-tree fallback. Packaging executes the signed binary with --verify-bundled-resources from /private/tmp; that entry exits before SwiftUI/runtime, preference writes, database migration, readers or network initialization. Resolver tests cover packaged lookup, missing bundle and CLI access. Current Agent Speed pin remains a94a67f per user decision; upstream upgrades are outside this candidate.

The follow-up hosted run passed all three resource regressions, but exposed a second scheduler race in the scroll test: the test task's fixed sleep resumed before the due dispatch callback. The fixture now awaits the initial-visible and idle-resumed publications with bounded XCTest expectations; production timing/visibility logic and duplicate-update/teardown assertions remain unchanged.

## Local acceptance and follow-up layout

Mac build972 (product source fd79996a) is installed and running. Full CI115 on 046309a1 is green; the only differences from the packaged product were the scroll-test wait and this maintenance note. The package's own Swift run also passed 2149 tests (28 skipped). Installer run40835967907 completed both macOS and Windows x64/ARM64 lanes with verified manifests. Queued duplicate973 was cancelled before starting. No public release or Windows EXE replacement. Agent Speed pin remains unchanged.

A complete application/data backup is retained outside the checkout. Local comparison found no missing old exact-index keys and identical active event/token totals across installation. Body migration preserved the raw samples, dedup IDs and retained buckets; pre-existing client events, revisions and quarantine entries in B were unchanged. The source backup and migration receipt are retained; detailed local counts stay in ignored verification files. Physical sidebar hover/exit/pin acceptance remains distinct from the passing native pointer regression.

The final model-cost candidate restores the original thin strips across all model families. All groups use the same adaptive columns and 30-point single-line geometry. Amounts use primary 10.5-point text; Token quantities and percentages use secondary gray 9-point text. The amount is anchored at the far right after the gray Token quantity and percentage. The original subtle per-model tinted background and border are retained alongside the existing color dot. Reference costs remain excluded from totals and retain their full meaning in the header, tooltip and accessibility label. Model qualifiers stay readable during truncation. No accounting or grouping rules change. Focused SSR/projection tests and the frontend production build pass; the Swift view parses. This follow-up layout has not been natively compiled, packaged or installed; installed build972 is unchanged.


## Restore the detailed speed curves

The Codex completed-body TPS chart reuses the original detailed line/point presentation (ebbb4e55) rather than the later half-hour distribution blocks. Default is 24 hours of five-minute weighted measurements; seven days uses 30-minute rollups and 30 days uses two-hour rollups. Sparse valid buckets remain visible without a distribution minimum. Per-model selection, Token/duration/body-count details, accepted quota-reset markers, source isolation, finite/window filtering and plot clipping are retained. Missing buckets break the line and never select a nearby measurement. The activity-speed chart remains a separate metric with its existing one-minute resolution; no body-TPS/activity-speed mixing.

Sidebar restores the compact near-three-hour half-hour median sparkline (8a4a9318), keeping the latest single-body reading on the right, separate median caption, independent model axes and explicit gaps. Both platforms use their existing stores and numeric projections. No rescan, migration, retention or accounting changes. Hidden charts stop polling; hover geometry is memoized and does not read the database. The production-component preview at dev-previews/speed-history-review.html consumes only an ignored local numeric snapshot. No local snapshot is committed or uploaded.

Local frontend production build and nine focused curve/polling regressions passed. Changed native views/tests parse; full native compilation/tests remain a hosted CI gate. This follow-up is not packaged or installed; formal build972 remains unchanged.
