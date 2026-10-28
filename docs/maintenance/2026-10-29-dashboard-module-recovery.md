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
