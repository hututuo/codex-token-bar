# Native Swift formed-release gate

## Purpose and execution

`scripts/check_swift_formed_release_upgrade.py` supplements the existing
Rust formed-release matrix and the separate real-v0.9.7 producer workflow.
It creates a new XCTest source file inside two fresh Git archives: a pinned
public Swift release and the exact candidate commit. No production algorithm,
resource, dependency manifest or version marker is rewritten.

Run one release per native macOS job, with the project's pinned Swift/Xcode
toolchain and Git LFS available:

```sh
python3 scripts/check_swift_formed_release_upgrade.py \
  --release 0.9.8 --output swift-formed-state-evidence
```

The required release matrix is `0.9.8`, `0.9.9`, `0.9.10`, `0.9.11`. The
immutable release commits come from the existing Rust formed-release script;
the script checks each public tag against its pinned SHA before extraction.
`Sources/`, `Vendor/`, `Package.swift` and `Package.resolved` must match their
Git blob identities before injection and after compilation. The new test's
content hash, compiled role and source SHA are recorded separately.

The script prepares the archived dependency resources, verifies the exact
TiktokenSwift revision and binary Git/LFS identity, and builds tests using
`swift build --build-tests --disable-automatic-resolution`. It locates the
resulting native XCTest bundle and invokes the single injected test through
`xcrun xctest`. Producer, candidate resume and candidate reopen are separate
processes. A producer must exit exactly 86 at the intended abrupt-exit point;
candidate phases must exit normally and the named XCTest must pass.

## State matrix

All three scenarios begin with real released APIs creating two standalone Exact
Homes with the same session UUID and totals 155/310, a populated quota
database with a preserved AUTOINCREMENT high-water mark, and one B event.
The quota table is created by the released initializer; the isolated seed
observation is explicitly synthetic SQL. Exact and B events use the released
production parser and writer APIs.

| Scenario | Released process | Candidate resume | Candidate reopen |
| --- | --- | --- | --- |
| Committed A | Complete the released migration; use the released A owner to add 7 tokens absent from the original legacy database; preserve all partition proofs; commit a WAL marker and `_exit(86)` with the connection open | Recover WAL, retain all released partition proofs and 162/310 totals; append 11 through the candidate owner; repeat without parsing; remove raw files; retain 173/310 | Reopen after raw disappearance; require the same typed event rows and 173/310 without parsing |
| Interrupted A | Exit after the second actual import/receipt commit: quota and Exact A exist, Exact B is still pending. A separate old-release process then appends 17 to the same original rollout and runs the real legacy index, changing its source/checkpoint/derived state while leaving the unfinished A untouched | Resume the real pending batch; retain the unchanged quota proof and import the full updated Exact history, including both the old 155 and late 17. Append the candidate's 11 once; remove raw files; retain 183/310 | Reopen after raw disappearance; require the same typed event rows and 183/310 without parsing |
| Enriched interrupted A | Freeze the same unfinished A, then run a separate unchanged released writer over a rewritten rollout that legitimately fills a missing model and turn. Preserve both original database images and the changed raw inputs; require the old numerical observations, stable identities and retained revisions | Prove the released metadata transition through the production parser, reconcile the complete incoming durable tables, and append the candidate's 11 once; retain 166/310, including the original unclassified history and its later attribution | Reopen without raw files and require the same complete typed event and retained-history proofs and 166/310 |

The committed case specifically detects falling back to a stale legacy
original: its released A contains history the original does not. All cases
require the legacy database byte hashes and full typed proofs at final
producer handoff to remain unchanged by the candidate. The interrupted case
also preserves a byte-identical pre-append Exact original and proves that
every old typed event remains in the released writer's updated source.
Existing A namespace proofs are compared before candidate startup and again
afterward, including tables outside the familiar event/ledger list. Only the
explicitly changed unfinished Exact partition can differ: its full incoming
durable tables must equal the real old writer's updated tables. Other formed
partitions must retain their full proof.
Exact durable tables, quota identity/sequence, B's full typed proof and the
committed crash marker are also checked.

## Safety and failure evidence

The runner selects a canonical, writable OS temporary base outside the real
home and creates an exclusive `tokenbar-swift-formed-*` root. Each scenario
has a native-validated ownership marker. It never changes `HOME` or invokes
`Configuration.production()` / `startProduction()`; every database and Home
path is explicitly inside the owned fixture. Credential variables and
unrelated app path overrides are not passed to the native child. Timeouts kill
only that child's newly created POSIX process group.

No unsupported-host fallback is permitted. Linux cannot return a native
pass. Missing/ambiguous bundles, absent WAL, incomplete producer proof,
wrong source identity, failed or skipped XCTest and missing phase reports all
fail the gate. A resume failure still records the independent reopen result;
one scenario failure does not hide the other scenarios. Complete synthetic
states, build logs, dependency identities, native phase logs and JSON proof
reports remain in the output directory for artifact upload.

## Verification status and limits

Local verification performed on Linux:

- Sixteen Python contract tests passed, including a real disposable Git
  archive/injection proof, real subprocess exit/deadline checks, producer and
  report negative cases, failed-phase collection, credential filtering and
  state archive retention, required old-writer append and frozen destination
  proof, pre-append original preservation, released metadata enrichment and
  rejection of a report that silently omits any scenario or candidate phase.
- All four actual public release archives were extracted and the injected
  source was checked: 884, 884, 885 and 886 production blobs respectively
  remained unchanged. This is source-identity evidence only.
- A separate agent reviewed the template against the archived Swift API
  signatures and the migration exit boundary. Review feedback added full
  namespace proof comparison after recovery, and the integration owner
  required the separate released Exact append before candidate recovery.

**Native build and execution are pending.** This workspace has no Swift
compiler or macOS runtime. The harness and source checks do not establish any
upgrade PASS, and there are no native timing or formed-state results yet.

The recovery workflow now requires the `swift-formed-release` job. Its four
release runs, runtime identity, all three scenarios, both candidate phases
and the complete release matrix are mandatory in
the verdict consumed by CI, signing and publication. Missing or partial Swift
evidence is rejected even if every Rust job succeeds. This wiring is not a
native pass: the final source SHA still needs all four real native runs and
their artifacts.

These are synthetic, small histories through the real archived Swift APIs
under XCTest. They do not replace native GUI acceptance, performance at real
history byte volumes, every damaged/intermediate incident variant, or the
separate v0.9.7 starting-state proof. B is formed and preserved here, but this
does not exercise every provider-specific B import or future schema change.
The enriched case currently covers one released full reparse. Repeated
rewrites and their intermediate historical turn associations remain under
independent review; this matrix is not a claim that all such transitions
already work.
