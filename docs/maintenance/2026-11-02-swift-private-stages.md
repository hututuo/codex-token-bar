# Swift recovery: private parser jobs and retained-stage continuation

Baseline: `41058ffe4b59fb921d2bdf962db1d0624aac9b87`.

## Correctness boundary

The authoritative Exact ledger continues to use the existing container A and its
module-owned schema. This change does not replace A, alter historical token
accounting, or delete legacy source databases.

Previously a namespaced backfill created four permanent A tables for each parsed
rollout, and accumulated every job before beginning the complete-generation
publication transaction. 4,124 sources could therefore create more than 16,000
transient tables in the shared ledger. Repeated connection/schema setup and
candidate enumeration grew with the number of pending jobs.

New parser jobs use the existing standalone stage format in
`staging-private-v1/<logical-index-name>/`. This path is intentionally outside
`BusinessDatabaseMigration.Configuration.specification`: a restart leaves those
jobs with their Exact owner instead of importing them into A. Their complete
marker, byte count, integrity checks, source-prefix checks and all-or-none
publication transaction are unchanged. Jobs are removed only after that complete
generation commits. A failed publication retains both the previous history and
the completed jobs.

Candidate names are collected once under the index operation lock; parser workers
read that immutable inventory and independently check their deterministic primary
path. Legacy physical stages and already-imported A stage namespaces remain
recoverable using the existing validator. Future or corrupt stages still block
replacement. A verified completed enrichment stage whose checkpoint reset now
requires a full rebuild is retained while a new job is built; its known purpose
change is no longer misclassified as a future software version.

## Regression coverage

Added native XCTests cover:

- private jobs do not increase A's schema size;
- failure after the first source import rolls back the entire publication;
- all completed private jobs survive a fresh startup and resume without parsing;
- startup does not accidentally import private jobs into A;
- completed-job cleanup follows commit;
- checkpoint reset plus a growing rollout preserves the old verified stage;
- corrupt retained-stage byte counts continue to fail closed without parsing;
- the existing retained physical-stage import test continues to exercise A-stage
  reuse, and the scale probe checks A's schema size while jobs are running.

Local validation in this Linux workspace: `git diff --check`. Native compilation,
XCTest execution, and the 13/128/512/4,124-source timing gates require the supported
macOS/Xcode environment and are not claimed as passed here. Already-formed large
sets of A stages still need a separate native recovery timing run; the new path
prevents further schema growth but does not erase them to obtain a faster result.

Per-record diagnostic `fsync` remains unchanged. Full diagnostic durability has
not been weakened to improve the timing numbers.
## Retained legacy jobs and directory aliases

An independent review found that a legacy job already imported into A could be
missed after its physical file was deleted and startup changed from a configured
directory alias to that directory's physical spelling. The owner index resolved
by stable module/source identity, but stage inventory still compared literal
directory paths. Inventory now resolves the parent directory without requiring
the old database leaf to exist, while retaining the catalog's original logical
path and store identity. Resolution walks to the nearest existing ancestor
before appending missing path components, including A-only jobs that never
created physical staging directories. The regression test imports a real
staged parse via an alias, removes both legacy database files and the entire
staging directory, restarts with the physical root, and
requires publication without invoking the parser. This XCTest still requires
the supported macOS CI environment; it has not been executed on the Linux host.
