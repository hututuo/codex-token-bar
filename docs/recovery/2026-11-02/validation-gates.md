# Recovery validation gates

## Problem and change

At the inherited recovery branch `41058ffe4b59fb921d2bdf962db1d0624aac9b87`, the repository contained `check_formed_release_upgrade.py` and `check_backfill_scale.py`, but no workflow invoked either script. Normal Swift tests used the scale fixture's default of 13 sources. The existing public-version workflow produced v0.9.7 data (including a v0.9.3-to-v0.9.7 pair); it did not execute the v0.9.8–v0.9.11 formed-state matrix. The presence of these scripts was not evidence that those gates passed.

`production-database-recovery.yml` is now a reusable and manually dispatchable workflow with an exact `source_sha` input. Full project CI calls it as a required job and includes its success in the `checked-source.json` dependency chain. The public-v0.9.7 workflow is a required nested job as well, so signing cannot accept a later-release-only result. Keeping invocation in that single parent workflow avoids running the expensive matrices twice for one push or pull request. This workflow neither builds release installers nor signs or publishes an update.

| Gate | Actual work | Required result and preserved evidence |
|---|---|---|
| Harness contracts | Python tests for wrong source identities, missing/duplicate reports, incomplete matrices, nonfinite budgets, failure collection and fixture isolation | All five harness suites succeed; logs uploaded even on failure |
| Public v0.9.7 | Reuse the pinned released Swift producer and Windows Rust v0.9.3-to-v0.9.7/retained-manifest probes against the exact candidate | Both native jobs pass, including their required fixture/test markers; original synthetic inputs and proof logs retained |
| Production readers | Existing non-`cfg(test)` Rust fixture on Windows and macOS | All required module/reader/stage checks; JSON and native log |
| Formed releases | Compile fixed public v0.9.8, v0.9.9, v0.9.10 and v0.9.11 Rust sources, form committed and interrupted A states, then run the exact candidate in separate resume/reopen processes on Windows and macOS | Four explicit phase results per release/OS; released-source identity and unchanged-production-file manifest; build/process logs; complete isolated synthetic state archives |
| Native Swift formed releases | Compile the pinned v0.9.8–v0.9.11 Swift sources and use production APIs to form committed/interrupted ledgers, then resume and reopen with the exact candidate | Released-source byte manifest; required XCTest proof markers and results; original synthetic states and all logs retained |
| Native Rust scale | Build the non-test production fixture in the actual optimized release profile on Windows and macOS, then run cold publication, real model backfill and warm no-op at 13/128/512/4124 sources | Per-source facts, typed numeric digest, source-byte digest, bounded stage peaks, monotonic backfill progress and zero warm staging; actual Cargo profile and CPU accounting where supported |
| Native Swift scale | Run the real namespaced backfill XCTest with 13, 128, 512 and 4,124 sources | Exact source/event/parser counts and token total, successful XCTest, monotonic cumulative completion, unchanged legacy bytes, timing profile for every requested size |
| Verdict | Require source resolution, all harness suites and all native jobs | No failed, cancelled, skipped or missing dependency; `recovery-checked-source.json` binds the outcome to source SHA and workflow run |

The formed-state harness no longer stops after the first independent scenario fails. It collects committed and interrupted state results, records producer failures as unverified phases, and retains each scenario's synthetic state. A failing resume also records what happened on the subsequent reopen instead of hiding that process. All four required results must be present and passing for the matrix to pass. The late-quota write rejects any producer path outside the disposable fixture and requires a nonempty committed WAL.

The scale runner records its requested sizes, currently running size and execution deadline. An empty/partial/duplicate matrix cannot report success. NaN, infinity and boolean timing values cannot disable budgets. A profile marker alone does not pass the gate: the entire named XCTest must also have passed, including assertions after the marker was emitted.

## Toolchain and budgets

- Rust: the same locked `1.93.1` toolchain and locked Cargo dependencies used by project CI. The historical matrix fetches full repository history so pinned public tags are available and checked before extraction. The probe is added only to temporary source archives; it does not rewrite historical production algorithms.
- Native Swift: `macos-26`, `DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer`, with the same Tiktoken LFS resource preparation as full application CI. This is deliberate: the earlier profile attempt used the macOS 15 default compiler and crashed during SIL generation before producing any scale sample. That failed attempt establishes no performance result.
- Scale sizes: 13, 128, 512 and 4,124. Swift has a 1,500-second process deadline; Rust has a 1,200-second build/process deadline. Both actual backfills must finish within 600 seconds and never leave a progress callback gap over 30 seconds. These are test budgets, not a promise about all user hardware or historical byte volumes.
- Required jobs fail on missing artifacts or incomplete reports. Artifacts are kept for 30 days. A job-level timeout remains a failed gate; it must never be relabelled as a pass from a partial report.

## Evidence limitations that remain explicit

1. Rust and Swift have separate formed-release matrices. Rust on macOS is not evidence for the shipped native Swift application. The Swift matrix has been implemented, but its presence in the workflow is not a passing run. All runtime claims must identify the final candidate SHA and actual required job outcomes. Native supporting suites must also report every named alias, diagnostics and Exact-append test as passed; a filter matching no tests cannot pass.
2. Each committed Rust producer forms real A/Exact/B data using its released implementation. The interrupted producer commits one partial quota partition before activation. Its legacy quota input is explicitly synthetic SQL; this is not a complete replay of all historical schema11 manifests, old parser stages, v1 pending journals or two divergent Exact copies. The older v0.9.7 recovery lane and targeted fault-injection tests are still necessary.
3. The scale fixture has one event per source. It covers source-count overhead, repeated staging and progress behavior at 4,124 sources. It does not represent the incident's hundreds of thousands of events, large compressed files, total bytes, UI responsiveness or installed-app resource usage.
4. Typed proofs are checked at the recovery/owner boundaries implemented by the probe. The tiny Exact fixture uses totals, two Home identities and removed raw sources. It is not a general proof that every possible unknown schema or conflicting historical field can be recovered automatically.
5. The required gates use disposable synthetic inputs. They do not open a user's installed application or production databases, and they do not constitute Windows ARM64 or native GUI interaction acceptance.

## Verification performed and remaining

Local Linux validation after these harness/workflow edits:

- Current Python harness suites: formed Rust 12, formed Swift 12, Swift scale 5, Rust scale 7 and native-reader report validation 9 tests passed. These check subprocess results, isolated filesystem handling, rejection of missing/duplicate/false proofs, failure collection and timing/profile budgets.
- Current CI evidence Python suite: 13 tests passed, including refusal of missing Rust scale jobs, incomplete sizes, a development-profile result or a relabelled runtime. The release-contract test file also passed.
- Workflow YAML parsed successfully; pinned release matrix, fixed Swift compiler and required verdict dependencies were checked.
- `git diff --check` passed.

Later Linux Rust source-count runs, including two failed 4,124-source attempts and a subsequent pass before the latest seal-integrity fix, are recorded in `status.md` and the retained run reports. The final integrity-fixed candidate must repeat those checks. Windows and native Swift execution results must be appended from hosted runs for the final integrated source SHA. No native runtime or upgrade pass is claimed from the local Python tests, historical reports, or existence of jobs.
