# Fifth hosted candidate: actual results and remaining blockers

This record is not phase-one acceptance or a release approval. It distinguishes
completed native evidence from subsequent fixes that still need a native run.

## Exact source and run

- Remote candidate: `86b31b1854f145c395dbb8f0335427e55a0d71d1`.
- Equivalent local commit: `76cb4506500c08277589ae59a8f9e92a1b2b670a`.
- Verified complete tree: `75a69e8b32cd31a9dde896d0af12942ad536cc47`.
- [Hosted run 41488693186](https://github.com/shawway/codex-token-bar/actions/runs/41488693186).
- Observation: 2026-11-02, approximately 17:29 UTC. Jobs still running at this
  observation are not treated as passes.

## Completed native observations

| Job | Actual result | What it establishes |
|---|---|---|
| Windows public 0.9.7, `125425995166` | PASS | Actual public 0.9.7 inputs, retained 0.9.3 schema-13 history, non-test resume/reopen, missing-A refusal, retained/interrupted manifests and both combined 0.9.10 incident cases passed. The unavailable-source case preserves its settled 155 projection; readable inputs continue to 162/310. |
| Windows formed 0.9.8, `125425994450` | PASS | The pinned released binary formed committed and interrupted states. Candidate resume and separate-process reopen passed all four combinations, typed history/WAL/raw-disappearance checks and totals `[162, 310]`. |
| Windows formed 0.9.10, `125425994683` | PASS | The same four combinations passed for the independently pinned 0.9.10 producer. |
| Windows formed 0.9.9, `125425994617` | Build FAIL | The restored Cargo target referred to a plugin permission file in a removed temporary source archive. Migration did not execute. |
| Windows formed 0.9.11, `125425994668` | Build FAIL | The same path-sensitive build-output cache defect, before migration. |
| Windows production readers, `125425994587` | Native FAIL | All earlier scenario progress was retained. `park-and-restore-container-a` failed at `business_store_fixture.rs:663` with Windows sharing violation 32. The actual report records `working_tree_dirty: false`. |
| Intel Swift, `125425790860` | Compile FAIL | `ExactRetryRawCorroboration.swift:98:79` passed a `UInt64` offset to an `Int64` binding. No Swift test ran. |
| Recovery harness, `125425852999` | PASS | The hosted temporary-root selection fixes execute successfully; this is harness evidence, not migration acceptance. |

The Windows main native job separately completed its production recovery probe,
then entered its full regression suite. Its probe passing while the reader job
fails at the same source establishes a scheduling-sensitive failure; it does not
justify ignoring the failing reader job. The suspected in-process background
maintenance owner must be drained explicitly before testing container absence,
while still executing the real maintenance work and the unchanged absence fence.

The Windows failure archive now contains all 54 regular synthetic files with no
skips (`archiveComplete: true`). This is actual Windows evidence for the corrected
cross-API `stat`/`fstat` identity check. The previous candidate's incomplete
14-file archive is retained separately and is not retroactively called complete.

## Downloaded, digest-verified artifacts

| Artifact ID | Bytes | SHA-256 |
|---|---:|---|
| `13163762016`, Windows 0.9.8 formed state | 253132 | `a75e7dd1c428832aed849e856c075d6fe85f45390622a4cf7359a41266ca8697` |
| `13164011255`, Windows 0.9.10 formed state | 251712 | `0b710d6d7a6af2ba0957af01d761fa8abfe3a29faaedd788f6c1c82287bc0414` |
| `13163921378`, Windows reader failure | 4024053 | `e18cd33fe3c88eb0f2b79ac275248c95d243fdeebb61f0e79f34eb5aedde6da3` |

The archives, raw job logs, source manifests, synthetic state and actual report
JSON are retained in the continuation evidence. They contain isolated synthetic
application data, not a user's database. Only the named source and scenarios
passed: this does not establish 0.9.9/0.9.11, Swift, ARM or a later candidate pass.

## Subsequent narrow fixes

1. `6bae38f9` gives each release and candidate archive its own fresh Cargo target.
   Vendored Tauri build-script metadata contains absolute permission-file paths;
   neither a previous attempt's target nor the other producer's target is valid.
   Only registry/download caches remain shared. Each executable is copied and
   hashed before its build directory is removed, bounding simultaneous disk use.
   Per-build source/target paths, status, error and executable hash are retained.
   Fourteen local harness tests pass, including separate sources, separate
   attempts, a pre-existing stale target and retained failed-build evidence.
   These tests deliberately use a compiler substitute; actual native builds
   remain required.
2. `3c6ba183` uses `Int64(exactly:)` once at the Swift raw-offset entry point and
   passes the verified value to both queries. Out-of-range input fails closed;
   no truncation is used. This needs a new native compile and regression run.
3. The separately committed formed Swift matrix now has the actual released
   writer produce G0/G1/G2 metadata generations and removes original raw inputs
   before candidate migration. All five enriched-history proof fields are
   required by the CI signing/publication consumer. Python checks are not a
   substitute for this native matrix.

## macOS scheduling and evidence boundaries

ARM jobs in this run remained queued during the observation, and prior runs
reported that a hosted runner could not be acquired after repeated attempts.
Intel jobs actually started and produced compiler feedback. Recovery jobs are
therefore scheduled on the standard `macos-26-intel` Swift and `macos-15-intel`
Rust runners. This is a scheduling decision, not a claim that an unexecuted ARM
job passed. The final application CI still requires **both ARM and Intel full
Swift regressions**; a queued, skipped or cancelled ARM job remains a blocker.
The sealed recovery verdict identifies its actual `x86_64` architecture and
runner labels and rejects a missing or relabelled architecture.

The parent CI concurrency key also includes the exact requested source SHA.
Different isolated candidates can now receive native compiler feedback without
waiting behind an older candidate's unavailable runner. Repeated requests for
the same branch/source remain serialized; existing evidence is not cancelled.

GitHub's primary runner references confirm these are standard runner labels:

- [macOS 26 general availability and architecture labels](https://github.blog/changelog/2026-02-26-macos-26-is-now-generally-available-for-github-hosted-runners/).
- [Standard hosted runner specifications](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job).

## Still required before phase two

The final committed candidate needs all native historical and scale gates.
Current Rust work additionally addresses valid pending history when raw logs
disappear: total preservation alone is insufficient, because actual testing
found omitted prompt/assistant association fields and an ordinary sync path
that remains blocked before publishing durable history. Exact path-owner
recovery, the maintenance/park race and the Swift installer continuation
interaction also remain under implementation or independent review.

No code change, authored test, earlier candidate pass or infrastructure retry is
recorded as completing those remaining checks.
