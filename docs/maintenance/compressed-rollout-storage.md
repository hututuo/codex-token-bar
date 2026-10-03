# Compressed Codex rollout storage

The usage index reads both `.jsonl` and `.jsonl.zst` history through one logical
source reader. This supports local on-disk history compression; it does not
change model context compaction, token accounting, prices, quotas or account
selection. Sources are selected from actual files, independently of the Codex
compression toggle.

## Source identity and cost

Both representations use the existing logical `.jsonl` path and source ID.
Plain JSONL wins when both exist. Discovery, active rollout references, the
session catalog, staged parsers and ledger reconciliation use the same reader.
Offsets, lengths and chunk hashes remain decoded JSONL bytes. Compressed bytes
are never counted as usage or added as a second source.

For a complete trusted checkpoint, a stable single frame with a declared
logical size and preserved mtime can reuse the existing numeric ledger without
parsing its body again. Pending or incomplete enrichment prevents that shortcut.
The representation receipt records this as `metadata_only`: it is not a content
hash proof. File identity and change time invalidate the process-local frame
layout cache; they are not the ledger identity.

Unindexed, partial, changed, unknown-length and multi-frame sources use streaming
decoding and the existing staged parser and reconciliation. An unknown-length
stream needs an initial length pass; the process caches that result for the same
physical observation. There is no expanded temporary history file. Decoder
windows are capped at 128 MiB, and I/O uses bounded buffers. Ordinary JSONL keeps
its inexpensive metadata path.

After Codex materializes a compressed source and appends ordinary JSONL, the
existing prefix/chunk proof and logical checkpoint decide whether an incremental
append is valid. Existing events are reconciled rather than added twice.

## Schema 14

Supported old indexes continue through the established migrations. This change
adds a single 13-to-14 SQLite transaction: `source_representations`, the
`rollout-storage-v1` component revision, and an upgrade-backup locator. It does
not rewrite the existing event, ledger or checkpoint tables, change parser or
accounting revisions, or introduce a second repair queue or switch manifest.
Unknown versions and inconsistent component structures remain fail-closed.

An existing schema-13 database receives one consistent SQLite backup, including
committed WAL data, before the additive transaction. The deterministic backup
suffix is `.schema13-before-representations.sqlite`. A completed valid backup is
reused after an interrupted attempt; unfinished temporary copies are discarded.
It remains the first pre-upgrade baseline and is never restored automatically.
The transaction either commits the table and marker together or leaves schema
13 and its ledger intact. Existing older migration retention remains unchanged.

## Numbers and raw text are separate

Missing source text does not delete published numeric history. A restored
compressed source can recover its numeric association using metadata while its
old raw-text bindings remain unavailable. On first excerpt access, the selected
source's existing full chunk hashes are checked against decoded bytes, with EOF
and physical stability checks, before bindings become available. This currently
requires a full content proof for that selected source, not a range-only proof;
it does not recount all historical sources. Later unchanged excerpts reuse that
proof. Sources with no text offsets are not decoded merely to browse a turn.

A corrupt or truncated stream must not publish a partial replacement. The last
trusted ledger remains available and diagnostics include the physical path and
structure/decode stage. Token-only indexes cannot recreate lost full chat text.

## Verification scope

Regressions exercise ordinary/compressed precedence, single/unknown/multi-frame
reading, seeking and truncation; complete-index reuse without parsing; cold
indexing and resumed appends; preservation on corruption; catalog logical
signatures; additive migration and rollback/retry; and delayed raw-text proof.
Existing old-index and paginated-history suites still apply. Synthetic schema
relabeling is labeled as a fixture, not a released-client upgrade demonstration.

Full Swift, frontend and Rust checks run on hosted CI, with Rust on macOS and
Windows. A green run proves that source and its test fixtures, not a real
customer's recovery or an installed Windows upgrade. Release packaging,
installation, customer recovery and live file-lock behavior require separate
acceptance. This implementation does not publish an application release.
