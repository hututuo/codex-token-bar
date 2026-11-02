# Rust production recovery evidence

This record separates the actual native application routes from the older
`cfg(test)` SQLite paths. It is phase-one evidence and limitations, not a claim
that the three requested phases, platform acceptance, or a release are complete.

## Correctness changes and evidence

| Change | What was reproduced and fixed | Verification already executed |
|---|---|---|
| Pending imports outside current discovery roots | A frozen receipt could hide later committed rows from an old writer indefinitely. Recovery now compares the live source, requires it to cover the frozen history, and refuses to replace a destination with independent changes. | Business-store tests, including late append, deleted source, corrupt backup, truncated source, v1 journals and independent failures. |
| External live SQLite WAL | Opening a nonempty WAL read-only can change the WAL's ctime. Treating that as a competing writer rejected valid reads. Reusing only size/mtime also misses same-allocation WAL reuse. | Three targeted WAL tests; the full Exact suite; non-test native fixture with old columns, WAL-only mutation, active-rollout readers, malformed replacement and a write-refusing source handle. |
| Current quota query and stable account identity | Integration left a literal `{}` in a SQL projection. Test-only writer filtering also disagreed with the production account scope. | 75 quota tests, plus actual retained-row/history reads in the native fixture. |
| Visible model progress | The native multi-source probe reproduced completion at N/N followed by link repair reporting 0 through N under the same model-backfill phase. | Link repair has its own `repairingLinks` phase. The new focused regression and existing message-ranking regression passed. Native source-count runs observe model progress directly. |
| Last-good startup data stored only in A | Startup required an old physical `.sqlite3` file and used an import route when that file existed. It now reads a registered A namespace first, then known physical locations read-only if that namespace is absent. Home/revision/generation/provenance are read in one transaction. | 50 startup tests; native default fixture proves A-only identity, last-good restoration, a concurrent publisher, unchanged old bytes, no implicit registration/import and refused writes. |
| Failed Exact preparation and pending recovery | A failed discovery could be followed by a writer-enabled retry of an old Exact journal. Final verification could also quarantine/rebuild a bad snapshot. | `24a5b4e7` carries an inspect-only policy through both paths and binds it to catalog identity. 94 business-store tests and the native 13/13 suite passed, including the new bootstrap combination and v1/v2 policy/ownership regressions. |

`Container` identity checks, read-only source handles, immutable frozen proofs,
and rejection of unknown/conflicting inputs remain part of these paths. The WAL
change ignores only the read-induced WAL ctime mutation. It retains main-file
identity and ctime, and WAL device/inode/size/mtime checks across a read; nonempty
WALs are reread rather than accepted by a metadata cache.

The new pending-policy fixture keeps the default native suite at 13 named
scenarios. Within `bootstrap`, it creates a real pending Exact import outside
current discovery, appends historical rows, damages another frozen backup while
its source remains identical, and adds a malformed manifest to the current
root. Both failed attempts must preserve the Exact namespace proofs, journals,
receipts and backup bytes while an independent quota journal recovers. After
removing only that synthetic malformed manifest, the native bootstrap must
recover both Exact histories and the backup, then remain idempotent. A small
schema-14 fixture exercises the real coverage/import routes; it does not replace
released-version data or parser acceptance.

## Executed local test groups

These are Linux results from the integration sequence, not one final clean
cross-platform acceptance SHA. Native readers and final platform CI must be run
again after the last integration commit.

| Group | Actual result | Local evidence filename |
|---|---|---|
| Business stores after the pending-policy fix | 94 passed, 0 failed, 0 ignored | `tokenbar-rust-pending-policy-tests.log` |
| Exact/parser/index after WAL fix | 356 passed, 0 failed, 9 ignored | `tokenbar-rust-exact-fixed-tests.log` |
| Targeted WAL cases | 3 passed | `tokenbar-rust-wal-tests.log` |
| Quota history after query/identity fix | 75 passed | `tokenbar-rust-quota-verified-tests.log` |
| Migration diagnostics | 7 passed | `tokenbar-rust-business_migration_log-tests.log` |
| Startup read paths | 50 passed, 0 ignored | `tokenbar-rust-startup-readers-tests.log` |
| Measurement guard error/panic reset | 1 passed | `tokenbar-rust-fixture-guard-tests.log` |
| Default non-test native readers | 13/13, including all five new bootstrap proofs and all six startup proofs; 10 artificial concurrent-writer assertions | `tokenbar-rust-pending-policy-native.log`, `native-production-readers.json`, `native-production-readers.log` |
| Scale report harness | 7 Python tests passed | `scripts/tests/test_rust_backfill_scale.py` |
| Native-reader report provenance | 2 Python tests passed, including timeout/incomplete reruns and missing pending-policy proofs | `scripts/tests/test_business_store_fixture_harness.py` |
| Source-count fixture isolation | Existing directory, live symlink and dangling symlink rejected before A creation; external sentinel unchanged | `rust-fixture-isolation.json` |

The native-reader harness captures source SHA and tracked-worktree state before
building. It writes a failed/incomplete report at the start of each invocation,
so a timeout or incomplete rerun cannot leave a prior PASS attributed to new
source. The startup native result was obtained with then-uncommitted changes
that subsequently became `4b2fb577`; its stored provenance is retained as such.
The pending-policy native result records `75b09537` plus a dirty worktree; those
Rust/harness edits subsequently became `24a5b4e7`. Neither local report is
relabelled as a clean final-source proof.

## Source-count performance probe

`scripts/check_rust_backfill_scale.py` builds the example with an explicit Cargo
profile and records the actual compiler artifact profile. It executes 13, 128,
512 and 4,124 distinct sources in isolated native processes. `--profile release`
must resolve to a non-test, optimized artifact with debug assertions disabled;
the word “release” in a report is insufficient.

Every source has a unique session identity and independent known token facts.
The gate checks each source's five numeric token fields and a typed digest of
17 numeric/identity/link columns before backfill, after backfill and after the
warm run. It also requires all original synthetic source bytes unchanged,
exactly one event per source, every model restored, no pending migration, and
zero warm staging jobs or revision changes.

Cold and backfill execute the actual dashboard/sync owners. Peak stage stores
and physical tables are measured after all workers in each real batch finish
and before publication can remove them. The observed fresh-run bound is four
stores and 16 tables, not a zero measured after cleanup. Progress is observed
from the actual product setter. Monotonicity applies specifically to the
`backfillingModel` phase; cold/warm do not claim a vacuous monotonicity proof.

Only the fixture's artificial per-job concurrent-writer injection is disabled
during timed phases. The default 13 scenarios continue to exercise that
injection and require a positive assertion count. Production transactions,
diagnostic durability, seals and fsync behavior remain enabled. A guard clears
the suppression state on success, returned error and panic.

### Unoptimized baseline — failure retained

The first full native run used source `351e1b0466aabe045719e059ec65e7ad97f4f250`
with the dev profile. Its overall result is **FAIL** and remains available as
`rust-source-scale-full-native/report.json`.

| Distinct sources | Cold seconds | Backfill seconds | Warm seconds | Result |
|---:|---:|---:|---:|---|
| 13 | 3.3514 | 3.3725 | 0.01616 | PASS |
| 128 | 28.854 | 26.404 | 0.01784 | PASS |
| 512 | 100.712 | 109.909 | 0.05305 | PASS |
| 4,124 | Cold publication observed; full run interrupted | Incomplete | Not reached | FAIL at the unchanged 1,200-second execution deadline |

At 1,199.84 seconds the 4,124-source process had used about 1,361.67 user CPU
seconds and 659.44 system CPU seconds. This establishes substantial active CPU
work; it does not by itself identify Rust versus SQLite execution or quantify
fsync latency. `/proc` I/O counters were unavailable. The interruption left
4,124 published numeric rows totaling 8,996,506 tokens, with the same typed
digest observed after cold publication; model enrichment had not published.
That read-only interrupted-state diagnostic is an evidence anchor, not a pass
or a substitute for successful resume.

### Optimized comparison

The explicit release comparison uses source
`75b09537b219243b48b6c0b28437a3557ee9ff6f`, with tracked TS/docs edits reported as
a dirty worktree. The actual artifact is opt-level 3, non-test, with debug
assertions disabled. `rust-source-scale-release-comparison/report.json` passed
both requested sizes with every data/progress/peak assertion intact:

| Distinct sources | Cold seconds | Backfill seconds | Warm seconds | User / system CPU seconds |
|---:|---:|---:|---:|---:|
| 13 | 1.6153 | 1.6399 | 0.00531 | 3.3925 / 2.3095 |
| 128 | 16.7265 | 16.0271 | 0.00915 | 33.9971 / 25.3768 |

The full optimized matrix is a separate run and is **FAIL**, retained as
`rust-source-scale-release-full/report.json`:

| Distinct sources | Cold seconds | Backfill seconds | Warm seconds | Result |
|---:|---:|---:|---:|---|
| 13 | 1.9948 | 1.9435 | 0.00708 | PASS |
| 128 | 15.5490 | 15.9795 | 0.00983 | PASS |
| 512 | 63.5428 | 69.8067 | 0.02900 | PASS |
| 4,124 | 581.0332 | Incomplete after the remaining process budget | Not reached | FAIL at 1,200 seconds |

The 4,124-source release process consumed 1,246.36 user and 791.50 system CPU
seconds. Its cold phase still observed at most four stage stores/16 tables and
a maximum progress gap of 1.112 seconds. Read-only inspection after termination
found the complete 4,124-row numeric publication and the same typed/source
digests as the retained dev interruption, zero published models, 3,768 pending
rows, and a passing SQLite quick-check. This is retained diagnostic evidence;
the run did not complete backfill, warm validation, or recovery.

The measurements show that selecting a release build alone does not resolve
the throughput problem. The latency budgets stay at
600 seconds for backfill, 30 seconds between progress callbacks, and 1,200
seconds for each complete native process. Independent size failures are kept
with their original roots, stdout, stderr and CPU usage, and do not suppress
later requested sizes. Missing, duplicate, partial or invalid profiles fail the
matrix. A later optimized pass cannot relabel the dev baseline as passing.

### Lifecycle measurements and a bounded connection reduction

Feature-only native timers added in `bd1d94c8` measure actual application scopes
without changing transactions, diagnostics, seals, or durability settings. Their
scope IDs include the measurement epoch, so a guard that ends after a phase
cannot contaminate a later phase. Nested and parallel wall scopes overlap;
their totals must not be added or compared directly with elapsed wall time.
The feature is absent from the shipped application and ordinary unit tests.

In `rust-source-scope-profile/report.json`, the release 128-source backfill
completed in 16.521 seconds with all integrity checks passing. It opened A for
writing 2,817 times. The 640 stage-signature observations accounted for 14.031
cumulative scope seconds, while parsing 128 sources accounted for 0.024
cumulative seconds. Sealing accounted for 1.382 cumulative seconds. These
measurements locate the repeated-connection cost; they are not a syscall-level
attribution of fsync or kernel I/O.

Each already-sealed signature observation previously loaded a complete seal
row twice, using the first result only for `is_none()`. Reusing that single row
within the same call removes one connection while preserving the missing-seal
path and subsequent validation reads. There is no cross-call cache. The native
comparison retains the same 600/30/1,200-second budgets and every data, progress,
and physical-peak assertion. The four requested sizes all passed in
`rust-source-reuse-seal-full/report.json`:

| Distinct sources | Cold seconds | Backfill seconds | Warm seconds | Result |
|---:|---:|---:|---:|---|
| 13 | 1.8809 | 1.5705 | 0.00554 | PASS |
| 128 | 14.7366 | 15.0786 | 0.00885 | PASS |
| 512 | 55.9669 | 54.2917 | 0.03002 | PASS |
| 4,124 | 477.9824 | 597.3149 | 0.16738 | PASS |

The 4,124-source process took 1,075.797 seconds overall, using 1,106.452 user and
645.487 system CPU seconds. All 4,124 models were restored. The 17-column typed
numeric digest before and after is
`a11a56d51f27bc780d7b15431c5f6af0c74bc48ec9d398e7615d925e4c608b1a`, matching the
retained baseline numeric publication. Source bytes remained unchanged; the
total remains 8,996,506 tokens. Cold/backfill peaks were four stage stores and
16 tables, the maximum backfill progress gap was 1.445 seconds, and warm work
created no stages. Only 2.685 seconds remained in the 600-second backfill budget;
this is a pass on this build and host, not evidence of a large performance
margin or acceptance on other operating systems.

The report records `bd1d94c8` plus a dirty worktree. The sole runtime optimization
in that fixed binary subsequently became `71c8aec2`; later uncompiled fixture
changes were not included. The same binary then passed the default 13 scenarios
in 9.447 seconds with ten artificial concurrent-writer assertions, recorded in
`rust-reuse-seal-fixed-default-readers/report.json`. That report includes the
binary SHA-256 and explicitly excludes later seal-content negative cases. It
must not be reused as validation of those later changes.

The original attempt at syscall tracing was blocked by the environment's ptrace
restriction before the application ran. Its failed artifact is retained as
`rust-source-lifecycle-profile`; no syscall measurements are claimed from it.

## Subsequent integrity regressions: acceptance remains open

The optimized scale binary above predates the following discoveries. Its PASS
cannot establish the correctness or performance of the new fixes.

The non-test native recovery path reproduced acceptance of an altered stage:
changing `tokens` and `input_tokens` from 120 to 121 left the old seal, row count,
logical size, raw source and manifest unchanged. The positive control first
accepted the original artifact; the negative case then failed with
`retained stage numeric corruption bypassed its unchanged seal`. Evidence is in
`rust-seal-content-red/confirmed-negative.json`; the original wrapper report
looked in stderr, while the executable writes its error JSON to stdout. Both
records remain available, and the corrected report explicitly identifies that
reporting mistake.

The new implementation checks actual typed rows, footprint and a trusted
producer schema in one read transaction, and checks the same proof again under
the destination's write transaction before replacement. Existing validation
cannot create a missing seal or replace the caller's previously verified proof
with a later re-seal. The schema contract comes from the actual producer DDL
audit, not from a candidate artifact's own claim. Unsealed supported artifacts
are preserved and reparsed from a verified raw prefix; they are not sealed in
place. An already-sealed artifact with a missing seal is rejected and retained.

The subsequent non-test run passed the retained numeric-change, import-time
numeric-change, explicit re-seal, retained column-swap, pre-publication column-
swap and missing-seal checks, then exposed a separate actual data-loss path:
an older correct 120-token prefix replaced two pending rows totaling 175 tokens
with one row totaling 120. Those 55 tokens had not yet reached the published
ledger, so an unchanged published summary was insufficient evidence of safety.
`rust-seal-schema-pending-red/report.json` records exit 1, the expected native
failure, binary SHA-256, source identity, original fixture root and the before/
after facts. The raw source still contained the full 175-token history.

The pending-history fix must compare actual reconciled per-event identities,
numeric facts, bindings and fingerprints inside the same write transaction. The
native gate requires rejection of the 175-to-120 replacement with the full main
namespace proof unchanged, successful repetition of the complete 175 candidate,
and successful recovery of an unsealed artifact only when its original source
prefix is still available. Truncated, rewritten and missing-source cases must
leave pending and artifact history unchanged. Those later controls were not
reached by the RED run. The subsequent real non-test run in
`rust-stage-integrity-native-first/report.json` did execute and pass them, along
with all 13 original scenarios and all nine stage/pending proof fields. It used
a dev build from `a7d4d5d0` plus recorded dirty native sources, took 34.658 seconds,
and records a per-file source digest plus binary SHA-256
`a522802548e3a08c55b9d9568cd6d9e31777da9c4e1c31028d47b7deabf7866e`.
The complete-candidate retry and unsealed rebuild also retain known models and
two distinct conversation turn groups. The default concurrent A-writer probe
remained enabled. This Linux result includes the corrected Windows receipt
assertion, but it does not establish Windows behavior.

The pending-protection module's ten tests also passed, and the complete Exact
related test group passed 369 tests with nine deliberately ignored cases and
zero failures in 202.55 seconds. Those tests exercise real accounting/recovery
logic with the ordinary test connection configuration; they remain separate
from the non-test native proof above.

A further review identified the preservation boundary between cloning an old
stage and deleting its original namespace. Normal same-index sync owners hold
the operation lock, but the public migration/namespace operations cannot rely
on that lock covering every caller. The added native counterexample copies a
real 120-token artifact, installs the real 175-token complete candidate into its
original namespace before deletion, and requires both the old copy and the
new complete artifact to remain. The old behavior actually deleted that newer
namespace: `rust-stage-preservation-race-red/confirmed-negative.json` records
the expected native failure and an independent read-only catalog check proving
that the racing namespace is absent. The copied old 120-token artifact and the
independent complete 175-token candidate are still observable.

Deletion now compares the actual copied `StoreSpec` and full row/schema proof
under an IMMEDIATE transaction before retiring its receipt or deleting objects.
It does not reinterpret the source path between copying and deleting. The real
non-test run in `rust-stage-integrity-native-cas/report.json` passed all 13
scenarios and all ten strict proof fields, including preservation of both sides
of that race, in 36.051 seconds. The binary SHA-256 is
`3a60123cc872c36b7be448f1f6a09c39049bb253b1adfa5d4c57e9310de7b6fb` and the recorded
source is `5ba4075d0` plus the individually hashed dirty native sources. Eleven
artificial concurrent A-writer assertions ran; none were disabled. The ordinary
unconditional cleanup retains its previous transaction behavior; only the new
conditional deletion performs the full proof CAS. The subsequent container
group passed 98/98 tests, including row, schema and owner mutation rejection and
the successful unchanged-content deletion path.

The final optimized scale revalidation remains open. A separate review is also
checking whether the missing-source enrichment path can replace an already
durable pending generation with a tombstone; passing the staged-import checks
does not establish safety at that other deletion entry point.

The isolated container tests currently pass 97/97, including three added
same-snapshot, owner/state/seal and schema-role tests. A separate test passed for
all six complete historical producer schemas and rejects a semantic column swap
against every trusted contract. The first run of the new schema-role test lacked
`sqlite_sequence`, which the real Exact index creates; SQLite therefore rejected
the fault's `ALTER TABLE` before it reached verification. The test now creates
and drops a seed AUTOINCREMENT table to reproduce that real prerequisite. The
initial 96/97 result is retained rather than counted as a product rejection.

## Nine default-ignored cases

The 356-test result did not run these nine. Their required inputs are deliberate;
synthetic tests cannot silently replace them.

| Tests | Reason and required separate evidence |
|---|---|
| `protected_historical_fixture_preserves_every_numeric_column` | Needs a closed immutable historical snapshot via `CODEX_TOKEN_BAR_RETENTION_RUST_FIXTURE`. |
| `actual_v097_route_preserves_full_proof_and_deleted_source_history`; `actual_v097_pending_source_disappearance_recovers_verified_snapshot`; `actual_v097_quota_initializer_rows_and_sequence_reach_a` | Dedicated required public-v0.9.7 workflow supplies released-implementation inputs. |
| `actual_release_nine_upgrades_rewrites_and_appends`; `actual_release_historical_database_upgrades_and_keeps_incremental_scan`; `actual_release_relocation_uses_supplied_cache_path` | Require actual isolated v0.9.1 exports and original Home identity; the historical full-database test specifically needs the 164-file backup. |
| `live_exact_index_cold_and_warm_scans_when_explicitly_enabled` | Explicit local full-history opt-in; it must not access a real Home by default. |
| `live_paginated_rollout_matches_reconciled_total` | Requires a selected migrated rollout and an independently reconciled total. |

## Remaining acceptance boundaries

The source-count test has one event per synthetic source. It does not represent
the incident's historical byte volume, long/compressed sessions, already-formed
massive old A-stage catalogs, installed-app resource use, or GUI responsiveness.
The fresh batch bound does not prove the cost of recovering thousands of
previously retained stage namespaces.

Required public-version producers, formed committed/interrupted states, native
Windows and native Swift macOS behavior, and clean final-source provenance are
separate gates. See [validation-gates.md](validation-gates.md). Phase two must not
be treated as accepted merely because source edits, unit tests, or this record
exist.
