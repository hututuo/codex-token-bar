# Independent review: Swift discovery, ownership and retry proof

Reviewed `114d8a9a` (discovery and lock aggregation), `5406b88b` (live native
diagnostics), `54853720` (candidate and retained snapshot binding), and
`34990b51` (A-only jobs with absent physical parents). Review performed against
the integrated source on 2026-11-02. These are source-review findings; the
new native tests described below are not a substitute for executing macOS CI.

## Findings requiring correction

### Live diagnostics could wait for disk on the main actor

`refreshPreview()` synchronously acquired the diagnostic instance lock while
`record()` held that lock across its write and `fsync`. The new preparing-state
poll made slow diagnostic writes capable of blocking the migration UI. Isolated
fix `20cd6738` moves the complete same-attempt error/text snapshot into a detached
task and preserves durable writes. Its regression holds the actual writer lock
while requiring an independent main-actor heartbeat. See
`swift-diagnostic-responsiveness-review.md`.

### Retained original files caused an alias-only restart to look like a new input

The A-only alias tests deleted the physical originals before restart. When an
original remained, discovery returned the new physical spelling while
`tb_legacy_inputs` and `migration_pending_sources_v1` retained the original
alias. A ready A database treated that input as pending and rejected its already
registered store. An interrupted database failed the earlier journal inventory
check. Both cases preserved data but prevented normal startup after a directory
spelling change.

The migration now reconciles discovered inputs with the existing ownership
records before known/pending/journal decisions. An alias match requires:

- An absolute, standardized recorded source path.
- Equal resolved parent directories and literal leaf names.
- Two regular files with the same device and inode; a leaf symlink is rejected.
- Exactly one matching recorded path with the same store ID in every relevant
  legacy registry and journal record.
- Matching module and source identity, plus a consistent original logical path.

The matched input retains the recorded source path. An existing namespace keeps
the catalog's original logical path, module, source identity, and store ID. The
published namespace is not re-imported merely because a directory alias changed.
Pending namespaces still pass the retained-history and transactional proof
checks; alias resolution does not authorize replacement. A journal-only input
can retain its source key even when its first import failed before producing a
catalog row. Physical-path and catalog indexes keep reconciliation linear in the
number of inputs and records, rather than comparing every input to every record.

When the container's directory spelling also changes, verified retained-snapshot
ownership compares resolved parent directories while retaining the UUID-bound
literal filenames and regular-file checks. A reused receipt continues to use its
original backup and normalized paths, so the immutable attempt JSON is preserved
instead of rewritten to the new spelling. Source and destination full-proof
checks remain required. This also lets a new attempt compare against the prior
frozen snapshot after a legitimate legacy append.

Seven new native XCTest cases in `BusinessDatabaseMigrationAliasTests.swift`
cover the actual production migration API:

1. A completed A database with additional published history absent from the
   retained original; alias-to-physical restart must take the ready path and
   preserve the complete namespace proof and catalog.
2. A real Exact parser/synchronizer produces a retained source; its source lock,
   namespace, and catalog survive the Exact-root alias change.
3. An interrupted import retains its journal and all original files, then a
   standalone legacy source gains a real row before alias-to-physical retry.
   The resumed namespace must equal the new full typed source proof, and a
   subsequent reopen must remain stable.
4. A failed input with only a journal entry is repaired by the synthetic old
   producer and then resumes with its original source key.
5. A different file with the same basename and total, and a hard link at another
   physical path, both fail without changing published proofs or originals.
6. A conflicting pending store owner fails before activation and preserves the
   complete candidate proof, original bytes, and catalog.
7. An interrupted container whose own directory changes spelling reuses the
   exact existing immutable attempt JSON and original/normalized snapshot files;
   all retained bytes and receipt paths remain unchanged.

Old aliases that no longer resolve are deliberately not guessed from equal
contents or basenames. Such relocation needs a separate, explicit ownership
recovery path; this change only admits aliases whose physical relationship is
still provable. It does not infer historical inode identity that old releases
never recorded.

## Other reviewed boundaries

The discovery aggregation retains a global failure fence. A failed branch or
ownership conflict cannot become a partial input inventory. Identical physical
file/store pairs coalesce; one physical file assigned to different stores and
different physical files assigned to one store fail closed. The source-lock
array has a `defer` before any acquisition, so successfully acquired locks are
released on later aggregated failure. Blocked-input proofs open sources read
only and do not authorize import.

The retry proof now binds three distinct images: the retained normalized image,
the new normalized image, and the destination namespace. Full source proofs are
checked before coverage and again on the attached import source. The destination
proof is checked inside the replacement transaction before any old objects are
dropped. The narrow quota maintenance-clock and representation-backup-location
exceptions leave the remaining typed history comparison in place. I found no
new bypass of these checks in the reviewed commits. Legally changing Exact
checkpoint and aggregate rows are being handled in the separate Exact coverage
work; this review does not declare that work verified.

`resolvedDirectoryIdentity()` fixes the previously identified case where an
A-only job has no physical staging parent: it resolves the nearest existing
ancestor and appends the absent components literally. It does not follow an
untrusted database leaf. The original stage's catalog path is retained.

## Validation status

`git diff --check` passed. The diagnostic fix received an additional independent
static review from the Swift recovery agent. This environment has no Swift
compiler or macOS runtime; the new seven alias tests and two diagnostic tests have
not been compiled or executed here. Their hosted native results are required
before treating these fixes as verified. No claims about native timing, memory
limits, or real-user database recovery are derived from source inspection alone.
