# Swift interrupted import: frozen history guard

## Confirmed defect and changed boundary

The startup coordinator previously treated membership in
`migration_pending_sources_v1` as permission to replace an existing namespace.
`importSnapshot(replaceExisting: true)` then dropped that namespace before
copying the new source snapshot. A legacy writer could truncate or change a
source after an interrupted import, or another writer could change A; the next
retry could replace complete active history with the changed input. Keeping a
backup on disk did not make that replacement correct.

The coordinator now requires a full proof of the current unfinished namespace
to match a retained normalized snapshot recorded by `tb_store_imports`. The
original/normalized snapshot pair must have the expected store directory and
UUID-based filenames and must be regular files. A new normalized snapshot must
cover the retained normalized image before replacement is authorized. The
retained proof is rechecked inside that comparison, and the exact A proof is
rechecked inside import's write transaction before any namespace object drops.
The coordinator also pins the new normalized source's full proof before
coverage and requires that proof both during coverage and against the attached
source inside the import transaction. This binds both sides of the authorized
replacement; changing the candidate after coverage cannot reuse an earlier
successful comparison.
An empty namespace also has an expected proof, so a concurrent first write
cannot be mistaken for an empty destination.

The durable database receipt is committed together with namespace import. It
can therefore recover a crash before `attempt-UUID.json` and `receipt.json` were
written. Human-readable receipts remain useful provenance; their absence does
not authorize guessing which live namespace can be overwritten.

## Automatic recovery conditions

These are implemented conditions, pending execution of the new native tests.
They are not a claim that every historical user state has passed acceptance.

| Formed state | Required proof | Result |
| --- | --- | --- |
| Unchanged interrupted import | Current A equals the retained normalized image; new image has the same full proof | Resume with the same history |
| Same-schema pure row append | Every prior typed value, hidden row ID, duplicate multiplicity and autoincrement high-water mark survives | Import the appended history |
| Released Exact writer appends or adds a rollout during unfinished import, including raw files already gone | All frozen numeric/identity facts survive; the complete candidate ledger, ownership, checkpoints and production projections satisfy the durable proof below | Import the complete incoming ledger and keep both source images |
| Released Exact writer fills NULL model/turn metadata across one or several rewrites | Old numeric/time/known non-NULL fields remain exact, old model versions and old turn generations survive, current bindings have valid owners and references | Resume with all formed generations even when raw disappeared before migration |
| Database import committed before JSON receipt | Database receipt identifies a retained normalized image equal to A | Resume after validating the new image |
| Quota policy 3 maintenance with appended observations | Same schema; all observation rows survive; maintenance keys, row IDs, value types, policy and unknown values stay identical; finite clock moves forward within valid bounded seconds | Resume with the new maintenance time |
| Exact schema 13 to 14, additive representation metadata | Existing normalizer produces the supported schema on the isolated copies; all prior rows survive | Resume after coverage proof |
| Exact representation-backup path differs between isolated normalization and a legacy application | Only that metadata value differs; both expected owned sibling backups are valid schema-13 images with identical full proofs; metadata row identity/type is unchanged | Treat the paths as equivalent evidence |
| Frozen v0.9.8/v0.9.9 schema lacks the later retained-compaction query index | Only the exact production non-unique partial index may be added; schema proofs excluding that single index must match completely | Preserve the frozen history while accepting the known additive query index |

Generic coverage compares encoded SQLite values, including REAL bit patterns,
INTEGER types, NULL, BLOB and embedded-NUL text. It uses a bounded-cache TEMP
B-tree, never a large in-memory array of history. Main tables are explicitly
qualified, so a legacy user table named `retry_coverage` cannot collide with
the internal TEMP proof table. Different schema contracts must first pass the
existing normalizer; the retry proof does not invent a schema upgrade.

The quota exception is limited to `quota.swift` and the existing policy-3
maintenance table. It does not allow future policies, unknown-key changes,
clock rollback, invalid timestamps or changed observations. The Exact path
exception is limited to `exact.swift` and `exact.swift.retired`; it does not
authorize changing any event token value. It reads only the expected sibling
backup paths, not an arbitrary path copied from metadata.

## Protection states that remain acceptance gaps

An independently changed destination, missing/mismatched frozen evidence,
truncated source, unsupported schema contract, or unknown same-key row change
keeps the startup protection gate closed. New and old snapshots are retained.
This prevents silent loss; it does **not** mean that the affected user can
already enter and use the application normally.

A general Exact reparse can update existing source checkpoints, parser
receipts, generations and aggregate rows rather than only append typed rows.
This change does not claim automatic coverage for all such transitions. A
separate semantic proof is required before permitting their replacement;
counts, totals, or a successful `quick_check` alone are insufficient. The
existing normalizer still handles known first-time migrations on isolated
copies. This guard does not replace those migrations or relax their version
checks.

### Durable Exact continuation proof

`ExactRetryAppendCoverage` remains a separate compatibility boundary for
recognized schema-14, ledger-revision-2 images produced by the released
0.9.8–0.9.11 chain. The caller checks the complete schema, full typed contents
of all unaffected tables, hidden row identities, duplicate multiplicity and
sequence high-water marks. Only recognized bookkeeping, event metadata,
bindings and projections enter semantic comparison. Listing a table as mutable
does not authorize dropping any fact. Unknown tables, opaque data, old
identities, fingerprints, logical-turn mappings, corrections, unresolved
observations and retained revisions still require complete typed coverage.

The former implementation authorized changes by replaying from the frozen
checkpoint or a single frozen metadata state. Independent review demonstrated
two legitimate counterexamples: G0→G1→G2 reparses retain G1 event metadata while
bindings refer to G2; and raw files can disappear after the old writer has
committed the complete database but before migration. The final raw file cannot
reconstruct vanished intermediate generations. `ExactRetryDurableHistory`
replaces that authorization; the old single-reparse witness implementation has
been removed rather than accumulating exceptions for each number of rewrites.

The durable proof requires:

- Every frozen event ID, source ID, time, numeric component, accounting kind,
  reported/legacy value and SQLite storage type remains exact. Known model,
  logical-turn and assistant metadata cannot be cleared or replaced. NULL
  fields can acquire information; filling a model additionally requires the
  complete old event payload and its old raw positions in retained revisions.
- Source identity and session ownership remain fixed. Every event has one
  binding owned by that same source. A binding claiming availability belongs
  to the current source generation and lies within that generation's saved
  prefix. Same-generation positions and known links cannot change; a full
  reparse can establish a new UUID generation and new raw locations. Missing
  sources can mark text unavailable while leaving all numeric history intact.
- Logical turn mappings retain all old rows. A new mapping must be referenced
  by a same-source event; allocated event and turn IDs stay in the correct
  sequence interval and cannot share another source or identity role. A raw
  prompt key can legitimately represent a different retained logical turn
  from one event's earlier turn, so no false equality between those two fields
  is imposed.
- The complete candidate's recognized columns, row-ID contracts, references,
  integer/REAL/BLOB types, fingerprint codec, counted component arithmetic,
  checkpoint JSON round trips, prefix chunk structure and source receipts
  remain valid. New unresolved diagnostics require a real source owner,
  typed payload, finite time, valid identity codec and valid generation. A
  current-generation diagnostic is bounded by the current prefix and cannot
  simultaneously claim an available event binding. Intermediate-generation
  diagnostics remain historical evidence; they need not belong to the latest
  raw generation.
- Frozen canonical consumption remains visible by ID and exact numeric fields.
  The current canonical exclusion set and dashboard projections are rebuilt
  with production functions into TEMP tables and compared by complete typed
  rows. Attribution starts from frozen historical maxima. A NULL-to-known
  model can reclassify a bucket only when its complete frozen floor is
  explained by the frozen event ledger. An unexplained larger maximum cannot
  be erased. Text rebinding alone never authorizes resetting that floor.

The proof reads the complete candidate and imports that same complete snapshot;
it does not copy only selected events, flatten retained versions or synthesize
a new history from totals. TEMP copies and comparison B-trees use the caller's
bounded disk-backed cache. Source inventory and production projection memory
remain subject to their existing bounds; this change is not a claim about the
independent 4,124-source performance acceptance gate.

### Raw evidence is supplementary and explicitly labelled

For a changed source whose raw bytes still match the incoming checkpoint's
complete saved prefix, `ExactRetryRawCorroboration` runs the production parser
and verifies numeric observations, current binding positions, identities and
the checkpoint. The prefix can be followed by newer unindexed bytes; they
remain for ordinary synchronization after activation. Missing raw, unreadable
raw, a raw file rewritten after the database commit, or a file that changes
while being examined cannot revoke already durable history. Each source log
records `evidence=durable-history` and a separate `rawEvidence` result, such as
`current-prefix-parser-and-bindings`, `recorded-missing`, `raw-unavailable` or
`raw-differs-from-durable-prefix`. A contradiction against an unchanged,
hash-matching prefix remains a failure, with independent sources still logged.

Current raw model, timestamp and assistant positions are not treated as proof
of historical metadata: the real writer preserves those fields from earlier
associations. The proof protects all known frozen values directly and preserves
new formed values as recorded history. Without independent raw evidence, a
coherent new 55-token observation cannot be distinguished from an externally
fabricated but internally coherent 55-token row. The migration makes no claim
to authenticate such external history. It guarantees continuity of the frozen
facts, internal ownership/integrity of the incoming database, full preservation
of both images and publication of exactly the validated candidate.

This changes two earlier test assumptions deliberately. A later raw rewrite is
now a successful durable continuation, with a log stating that the raw file no
longer corroborates the saved prefix. An arbitrary model replacing a frozen
NULL cannot be called externally disproved merely because final raw has a
different model; known-model replacement, missing retained payload, broken
references, hidden old events and typed numeric changes remain rejection cases.
Metadata-only representation hints are accepted when they agree with their
source receipt; they are not evidence for numeric accounting.

### Native cases, historical gates and remaining boundaries

The native tests include real old-writer append, a new rollout, independent
allocation order, NULL metadata completion, repeated G0→G1→G2 completion,
all raw files removed **before** migration, and an old writer that already
observed the removal and marked sources missing. Successful migration compares
the whole imported namespace proof against the independently verified new
normalized snapshot, preserves opaque NUL/BLOB data, verifies original files
and frozen evidence byte-for-byte, and reopens without raw or reparsing.
Counterexamples retain positive controls and cover lost old events, same-total
numeric changes, known metadata replacement, broken or cross-source references,
canonical hiding, unknown-table loss, schema-role swaps, destructive triggers,
a newly allocated orphan turn, malformed unresolved diagnostics and a candidate
changed between coverage and final publication.

The source catalog also reports canonically equivalent Swift path keys as an
ordinary error rather than triggering an unchecked Dictionary precondition.
Recognized v3 checkpoints still permit only the absent-versus-strictly-empty
compaction field equivalence; the imported v3 receipt remains unchanged. The
one known later retained-compaction query index may be added only after every
other schema proof remains equal. No frozen image is modified to obtain these
proofs, and unknown future schema/checkpoint revisions do not enter this path.

The actual unchanged-release subprocess gate remains mandatory: v0.9.8,
v0.9.9, v0.9.10 and v0.9.11 each produce committed, interrupted and enriched
states, and the candidate must resume then reopen in separate processes. The
Swift matrix is independent of the Rust two-scenario matrix. The complete
candidate namespace, second Exact owner, retained versions and old source
proofs are checked; aggregate totals alone do not satisfy that gate.

The enriched scenario now makes the unchanged released process form G1 and G2
in sequence. It retains a complete closed G1 database image and full typed
proof, both raw representations and the original G0 evidence. The source's
event metadata must stay at G1 while G2 bindings move and both turn generations
remain. It then removes A and B raw files **before** candidate startup. Candidate
resume compares the whole imported A namespace with the receipt and independent
normalized snapshot, ingests 11 tokens through a new rollout (155→166), removes
that new raw file, and reopens in another process with B still at 310. Both
candidate reports must explicitly prove `repeatedMetadataGenerationsPreserved`,
`rawMissingBeforeMigration` and `completeImportedNamespacePreserved` in addition
to the earlier model/retention/owner/WAL checks. The Python validator rejects
missing or non-boolean flags, lost intermediate rows, collapsed turn generations,
unchanged bindings, changed evidence bytes, and a raw file still present at the
handoff. Its 18 contract tests passed locally; this is not native execution.

This implementation is not yet native acceptance. No Swift/macOS toolchain is
installed on the Linux work host. A portable SQLite check parsed the exact new
reference queries against extracted production table DDL and a synthetic
reference graph; it checked SQL grammar/reference rules only. Hosted macOS
compilation, XCTest, the unchanged released-version subprocess matrix and scale
acceptance are still required. Python harness tests are likewise contract tests
and cannot replace native execution.

Unknown same-key numeric correction, source reassignment, provenance rotation,
a missing frozen proof or an independently changed unfinished destination still
block replacement. An unexplained attribution floor, an older incomplete
checkpoint outside the recognized receipt contract, or source truncation while
A remains complete also needs a separately demonstrated recovery decision.
These protections preserve files but must not be represented as all affected
users already being able to enter the application. Raw disappearance alone,
multiple legitimate metadata generations and recorded text unavailability are
now intended automatic continuation states, pending their native gates.

## Verification added and execution status

`CodexBusinessDatabaseTests` now covers typed append versus REAL/INTEGER
replacement, hidden row-ID replacement, embedded-NUL text truncation, removed
BLOB rows, autoincrement regression, internal TEMP-name collision, and a write
to A between reading the expected proof and importing. It exercises the
quota clock exception against policy, identity, unknown-key and numeric
conflicts.
An additional adversarial regression mutates the covered candidate before
import, once by removing an old record and once by changing two record values
while preserving their total. Both attempts must reject replacement and leave
the old namespace proof unchanged.

`BusinessDatabaseMigrationTests` now covers truncation, an independently
changed unfinished namespace, a committed namespace without JSON receipts,
quota clock plus observations, and the real Exact normalizer performing
schema 13 to 14 both privately and in the old source. The Exact regression also
changes a numeric observation while backup-path equivalence still holds and
requires that comparison to fail.

No Swift compiler or macOS runtime is installed on the Linux work host.
`git diff --check` passes. New XCTest execution, the historical-version reader
matrix, and supported-toolchain scale acceptance are still required; neither
code inspection nor a portable SQL experiment substitutes for those gates.
A portable SQLite probe did verify that a read-only main database can use the
TEMP write transaction used by this comparison, that explicit main-table
qualification avoids the name collision, that typed encodings distinguish the
chosen INTEGER/REAL and embedded-NUL cases, and that this probe left the input
file bytes unchanged. It did not execute Swift code.

## Independent failures before import

Import and final source verification collect every independent store failure in
one attempt and withhold activation on any error. Discovery now also continues
past independent root, enumeration, manifest and ownership failures, and lock
acquisition reports every conflicting Exact owner. A blocked attempt runs
read-only integrity proofs against the safely discovered inputs and records
which imports were skipped and why. It never creates a candidate or chooses an
overwrite source from an incomplete inventory. Normalization and publication
that depend on that missing ownership proof remain explicitly unexecuted.

An Exact root nested inside support can enumerate the same file twice. The
inventory coalesces only a matching device/inode and stable store identity.
One physical file assigned to two stores, or two physical files assigned to one
store, blocks migration as an ownership conflict. The configured Exact root may
itself be an alias encountered during support traversal; its dedicated root
traversal validates the target while arbitrary descendant symlinks stay
forbidden. Two configured Exact roots naming the same physical directory are
not treated as two independent histories.

Additional native regressions cover two bad manifests in separate roots plus
one corrupt and one healthy independent SQLite input, two simultaneously held
Exact operation locks, a real parsed Exact index nested inside support, and a
hard link assigned to conflicting store names. They remain unexecuted on this
Linux host, like the other new native XCTest cases.

## Startup diagnostics while work is running

The native startup page now keeps one read-only diagnostic panel mounted during
preparation and failure. Its bounded 100-record preview refreshes once per
second from the current in-memory journal, and complete persisted attempts can
be exported while migration is still running. Export retains the existing
fixed-boundary snapshot behavior. Disclosure state, export progress and export
results survive a retry; log refresh does not recreate the action controls.

Retry and signed software-update controls remain available only on the failed
preparation page. The running panel has no path that starts another migration
or installer. A bounded scroll area for the aggregate failure message prevents
many independent errors from pushing those recovery controls off the page.
Native rendering and interaction validation are still pending macOS execution.
