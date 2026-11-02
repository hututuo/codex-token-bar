# Hosted candidate 7ea05809: observed failures and remediation

Observation: 2026-11-02 17:09 UTC. Phase one is not accepted. This record
does not grant release approval or substitute subsequent source changes for
the exact candidate that ran.

Run: <https://github.com/shawway/codex-token-bar/actions/runs/41485517410>.
Remote commit `7ea058094a7f426cf6034c949b5dc4f7ab756825` has exactly the
same full tree `88f00ab4e775fe7c557c4158963873d529bcd8a1` as local
`8e1970f4db1a0608c45b8985a9bbb2663d1ca819`. Different commit metadata
does not imply identical commit IDs.

| Actual job | Result and next action |
| --- | --- |
| Source, frontend, Windows updater | Passed; these do not establish database migration acceptance |
| Swift ARM, job 125416785299 | Obtained a native runner; compile failed at three DispatchSemaphore.wait calls in an async test context. No Swift test result was produced |
| Swift Intel, job 125416785355 | Independently reproduced the same compile failure. Commit f147ab64 moves deliberately blocking synchronization and the held diagnostic writer onto DispatchQueue workers, retaining the main-actor heartbeat assertion |
| Windows native, job 125416785013 | Native production compilation passed. The non-cfg(test) fixture ran, then returned Windows sharing error 32. Full native regression was skipped. Artifact 13161559745 was downloaded and SHA-256 matched 7486472bb085bfee30a98aa62c9215f93d7a43f71486cd62f51c6d24be726eda |
| Recovery harness, job 125416856783 | Failed because RUNNER_TEMP was under /home/runner; the root creator correctly refused Home overlap. Commit bc7fe0b6 selects a writable external runner/OS temp base and keeps the ownership guard. A real child-process rerun with the nested hosted layout passed 18 Python tests |
| Recovery matrices and verdict | Historical, reader and scale jobs were skipped by their failed prerequisite. The verdict failed. A skipped matrix is never counted as a migration pass |
| Native macOS 15 | Still queued at observation time; no result claimed |

The Windows failure archive reported 40 skipped files and only 14 archived
files. This was incomplete evidence, not a complete recovered database.
Many unchanged, previously rewritten files failed the cross-API ctime
comparison. CPython documents the specific mismatch in
<https://github.com/python/cpython/issues/157671>: Windows stat/lstat may
report creation time as ctime while fstat reports change time. Commit
9f816c5d uses birth time for that cross-API comparison and still compares
all original ctime/device/inode/size/mtime/link-count fields between
successive calls of each same API. Link, reparse, root ownership and outside
hard-link rejection remain enforced. Actual rewritten-file archive and
negative identity tests passed locally; the next native jobs execute these
tests on Windows/macOS before expensive compilation.

The retained Windows fixture had reached creation of the legacy-backfill
source. That narrows the error toward later operations, but absence of
earlier scenario logs cannot prove every previous check passed. Commit
85a66838 records each real scenario's start, completed proof and contextual
failure to the launcher's already durable stderr file. File operations also
report their source file/line. The final missing-container protection probe
must still run; it cannot be skipped to make Windows green.

## Separately observed historical result

The preceding candidate `e5926386a50430a38362be38e758e2867be06b2d`
actually passed Windows formed-release 0.9.9 job
<https://github.com/shawway/codex-token-bar/actions/runs/41483193298/job/125411052907>.
The producer was the pinned release commit
`35f31628e05930993c6c07155291a9740f04953d`; committed/interrupted states
both completed resume/reopen phases with non-test production code and
typed historical proof, WAL and raw-disappearance checks. This result
validates that exact old Windows scenario/candidate only. It is not proof
for 7ea05809, Swift, other releases or the final scale matrix.

The superseded runs were deliberately cancelled after recording their
results to free hosted capacity. Earlier runner-acquisition cancellations
were a separate infrastructure failure, documented in the first-candidate
record. No partial, cancelled or stale result is consumed as a release gate.
