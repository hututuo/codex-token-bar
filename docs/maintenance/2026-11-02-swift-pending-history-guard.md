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
| Released Exact writer continues ordinary append or adds a new rollout during unfinished import | Every old typed historical event/identity/binding survives; changed source prefixes, parser checkpoints, complete new ledger rows and production projections pass the separate proof below | Import the complete incoming ledger without resetting its checkpoints |
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

### Bounded Exact append proof

`ExactRetryAppendCoverage` implements a deliberately separate schema-14,
ledger-revision-2 compatibility path for ordinary continuation by a released
writer. It is reached only when the generic typed comparison finds changes
exclusively in the recognized source bookkeeping, metadata and projection
tables. Any uncovered event, ledger identity/binding/turn, retained-history
row, unknown table, or unknown column still rejects replacement.

The source catalog is compared with typed digests, so unchanged sources do
not require their raw files to remain present. A released writer can add a
`verified_full` representation hint on the first unchanged refresh after a
full parse. That absent-to-present hint is accepted without raw bytes only
when the complete typed source checkpoint, prefix chunks, enrichment receipt
and physical observation are identical to the frozen image, and the new known
hint agrees with that observation and logical prefix. The complete ledger
witness still disallows any new event or identity for this skipped source.
Changed physical observations, `metadata_only` hints and unrecognized hint
transitions do not receive this exemption. No extra warm-up scan is a recovery
prerequisite.

For every source whose parser evidence changed, the verifier pins the current
raw reader, verifies **all** frozen prefix chunks and
**all** incoming prefix chunks, and runs the actual bounded incremental parser
from the frozen checkpoint to the incoming recorded size. A raw file may
already have additional bytes beyond that size; those bytes are left for
normal synchronization after activation. Parser state, resume offset, chunk
hashes, source probe and recognized parser receipts must agree. Unknown JSON
checkpoint fields cannot be lost through Codable's permissive decoding.

A TEMP witness starts with all frozen typed event, identity, binding, turn and
fingerprint rows. Only complete rows justified by the parser's emitted events
and their incoming raw-to-logical bindings can be added. Every incoming row in
those tables must then equal that witness. This rejects missing new events
behind an advanced checkpoint, extra fabricated identities, and replay whose
numeric total happens to match while individual values differ. The verifier
does not allocate new logical IDs; real multi-source append order is preserved.

The canonical exclusion set and all four dashboard projections are regenerated
with the production projection functions into TEMP tables and compared by
complete typed rows. Attribution starts from frozen historical maxima, then
runs the production lineage aggregation with maximum preservation. An incoming
cache cannot erase a retained maximum or invent an increment. Existing
canonical history must also remain visible. Generation counters, publication
receipts, coverage certificates and storage-maintenance clocks have explicit
bounded checks; all other metadata values remain subject to typed coverage.
Both full snapshot proofs are still bound to the later import transaction.

This does **not** authorize arbitrary source rewrite, old-event correction,
provenance rotation, dropped ledger bindings, or a changed source whose raw
prefix is no longer available for verification. Such states remain protected
acceptance gaps rather than being silently converted to ordinary append.
Independent session-catalog mutations are still subject to the ordinary typed
history rule. No claim of complete phase-1 acceptance follows from this code.

An ambiguous source catalog also fails through an ordinary diagnostic error.
The catalog loader does not construct a dictionary with an unchecked unique-key
precondition: SQLite BINARY uniqueness permits distinct Unicode encodings that
Swift treats as equal strings. Such a pair retains both source rows and reports
their IDs instead of terminating the process or choosing a surviving owner.

The v0.9.8/v0.9.9 source review identified two required differences from later
releases. Their recognized v3 parser receipt predates the v4 compaction parser,
and the checkpoint omits `compaction`. Only when the recorded receipt is that
explicit v3 revision and production replay yields a strictly empty compaction
state may absent and empty be treated as equivalent. The imported receipt is
kept at v3, so this proof cannot mark the historical parser upgrade complete.
Nonempty compaction state, changed accounting, and unknown revisions still
reject. The later `retained_unreported_compactions` index is also absent from
those old normalized images. Its exact declaration is shared with production
installation; its addition is accepted only after all remaining schema proof
evidence (objects, columns, foreign keys and other indexes) compares equal.
No frozen file is altered to obtain either proof.

Eight new native tests cover the real freeze→legacy append→resume path, extra
unindexed raw bytes, an unchanged source with its raw file deleted, differently
ordered repeated appends, a new rollout, deletion/reopen after activation, and
negative history/checkpoint/chunk/projection/identity/raw-rewrite cases. The
same attempt records each changed-source proof and continues independent raw
source, metadata and projection checks after a rejection, while withholding
import. A two-source corruption case requires both failures in one log. These
tests have not run on this Linux host. A narrow portable SQLite experiment did
execute the actual production dashboard and attribution SQL against read-only
main plus TEMP shadow tables; the four derived dashboards and preserved
attribution maximum matched the selected fixture and the main file bytes did
not change. That is SQL evidence only, not Swift compilation or native recovery
acceptance. The actual released-version subprocess gate and macOS XCTest remain
required.

If a newer legacy source is truncated while A and its frozen snapshot remain
complete, this guard preserves both sides and blocks. It does not yet select
the frozen image as an automatic fallback or reconcile a contradictory
same-key accounting value. Those recovery decisions remain explicit stage-1
acceptance gaps.

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
