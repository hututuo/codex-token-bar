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
