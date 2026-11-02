# Independent adversarial review: native Exact append continuity

Reviewed the Swift recovery work in `e916c875` and `3e5b8c3b`, followed by the
review-driven corrections `788e3161`, `272473a0`, and `2d9371a8`, on 2026-11-02.
This is an independent source and fixture review. No native Swift compilation or
test execution occurred in this environment.

## Three findings and their corrections

### 1. The post-activation test reused a standalone owner

The first append regression called `f.index.synchronize` after activating A.
That object was created before activation, and `SQLiteDatabaseDriver` captures
its optional business binding at initialization. Its unbound driver would keep
writing the old standalone database; it would not become an A owner when global
routes changed. The expected new A total therefore did not follow from the test.

`788e3161` constructs a new candidate index after activation. It also requires
the old physical source's complete proof and bytes to remain unchanged after the
candidate adds its next event. The separate released-source subprocess harness
already starts a fresh candidate process and did not share this fixture error.

### 2. An unnecessary warm-up refresh hid a legitimate missing-raw case

The initial fixture synchronized twice before freezing. The second call installs
a `source_representations` hint for unchanged sources. A real user can instead
stop after the first scan. If an old writer later appends to source A while also
refreshing unchanged source B, B receives its first `verified_full` hint without
changing its events, checkpoint, chunks, or physical observation. If B's raw file
then disappears, the original verifier treated the added hint as a changed
source and required raw replay. It would block the entire recovery even though
B's frozen numeric history remained intact.

`272473a0` removes the warm-up from the fixture and adds a narrow proof for this
transition. It requires no previous representation, exactly the recognized new
`verified_full` representation, valid receipts on both sides, and exact typed
equality of the complete source, chunk, observation, and enrichment rows. It does
not accept a changed physical stamp, `metadata_only`, a changed checkpoint, or a
new event by that route. The complete ledger witness still has to equal all
candidate events, identities, bindings, turns, and fingerprints, so skipping raw
for this one hint cannot hide an unproved new ledger row. Negative fixtures
mutate each of these boundaries.

### 3. SQL-unique paths could still trap the Swift dictionary

`indexedSources` used `Dictionary(uniqueKeysWithValues:)` on database rows. A
duplicate Swift key triggers a process-level precondition, preventing the
migration protection UI and error aggregation from handling the condition.
This need not require a missing SQL uniqueness constraint: Swift compares
canonically equivalent Unicode strings as equal, as documented in the official
[Swift String and Character Equality guide](https://docs.swift.org/swift-book/LanguageGuide/StringsAndCharacters.html).

A local Python/SQLite experiment used the actual declaration
`path TEXT NOT NULL UNIQUE` and inserted the precomposed and decomposed spellings
of `/tmp/café.jsonl`. Its observed result was:

```json
{"binaryEqual":0,"quickCheck":"ok","rows":2,"utf8":["2f746d702f636166c3a92e6a736f6e6c","2f746d702f63616665cc812e6a736f6e6c"]}
```

This experiment establishes the SQL side of the mismatch; it is not a native
Swift test result. `2d9371a8` changes the dictionary construction to reject
duplicate source/path identities by throwing a descriptive database error, with
both source IDs retained in the message. It never chooses a winner. Its native
fixture keeps the production schema, changes two source paths and their matching
enrichment receipts to these Unicode spellings, confirms SQL uniqueness and
`quick_check`, then requires a recoverable error, continued independent
projection diagnostics, and unchanged source/frozen proofs and bytes.

## Authorization boundaries examined

The generic typed comparison still runs before the Exact exception. Every old
event, fingerprint, identity, binding, turn, retention row, and unknown-table row
must remain present with its original typed values. The mutable-table list does
not include these histories. A canonical-event coverage check also rejects a
new duplicate exclusion that would hide previously canonical consumption.

The append witness is seeded from all frozen ledger rows. For each changed
numeric source, the verifier checks complete old and new prefix chunk hashes,
uses the production parser with a bounded endpoint and the prior parser state,
and checks the resulting checkpoint. Candidate event/turn IDs are looked up in
the actual bindings, rather than reallocated according to verifier iteration
order. The final witness must equal the entire candidate ledger, including
newly added rows, rather than merely matching counts or token totals.

The derived-table check rebuilds known projections through production SQL into
TEMP tables. Historical attribution maxima are seeded from the frozen image.
The new canonical duplicate projection is checked before other projections use
the canonical view. Neither main snapshot is a writable migration target during
this proof. The coordinator's retained/candidate proof bindings and destination
comparison inside the import transaction remain in force.

The schema exception permits only the exact production definition of the
non-unique partial `retained_unreported_compactions` index. It requires the known
schema/retention revisions and compares the remaining complete schema proof,
including column, foreign-key, and other-index metadata. It does not authorize
arbitrary additive indexes, changed triggers, or removed constraints.

The v3 checkpoint exception permits only a recognized v3 receipt whose absent
compaction state corresponds to the v4 parser's completely empty compaction
state. A nonempty observation is not equivalent, and the old v3 receipt remains
v3 so a later model/compaction backfill is not falsely reported as completed.

No additional old-history deletion authorization bypass was found in these
reviewed paths. That statement describes the source review's result, not a proof
that all runtime cases or performance envelopes have passed.

## Remaining acceptance boundary

The Swift agent identified a separate legitimate case: ordinary production
`UsageEventLedger.admit` / `enrichTurn` / message-link repair can fill an older
event's model or turn fields and update its bindings. The current conservative
typed-history guard still rejects those prior-row changes, even if retention
contains the older payload. This is a remaining legitimate-history acceptance
gap; it must not be described as unknown corruption or silently covered by the
plain-append tests. The review did not request weakening the event guard to fix
it without an additional bounded semantic proof.

The TEMP witness avoids retaining all ledger rows in Swift arrays, but this is
not a whole-process memory bound. Reused production projection code and source
catalogs still allocate collections. The small formed-release fixtures and
source-count backfill gate do not establish latency or memory limits for every
large historical database.

## Verification status

The SQL Unicode experiment above ran successfully, and repository whitespace
checks passed. The code changes and all new XCTest cases have only been reviewed
statically here. The exact-source macOS formed-release gate and native regression
suite must execute the integrated candidate, preserve their artifacts, and bind
their successful verdict to that same candidate SHA before any native recovery
PASS or phase-one completion claim is justified.
