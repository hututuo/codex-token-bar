# First hosted candidate: failures and follow-up

This is an observation record, not a recovery acceptance result. All linked
jobs below belong to remote commit
`f6582f3df82b4eb11fd787bf252a940717a73637`, whose tree exactly matches local
`fff58c0e01a73f6d105ab2999a3b6cad4841c9d0`. They do not validate subsequent
pending-history, Swift metadata, updater ownership or fixture changes.

Run: <https://github.com/shawway/codex-token-bar/actions/runs/41478671352>.
Observation time: 2026-11-02 16:32 UTC; this is not a final job-status list.

| Actual hosted result | Evidence and implication |
| --- | --- |
| Source, frontend, Windows updater and recovery harness-contract jobs passed | The first published candidate reached real hosted execution; these checks do not establish database recovery |
| Windows native production fixture failed after compilation succeeded | [Job 125392932737](https://github.com/shawway/codex-token-bar/actions/runs/41478671352/job/125392932737) returned OS error 2; the Python launcher supplies five child directory overrides without creating them, while native fixture isolation validates existing canonical directories. Full native regression steps were skipped after this failure |
| Windows independent readers failed at the Exact import receipt assertion | [Job 125393269700](https://github.com/shawway/codex-token-bar/actions/runs/41478671352/job/125393269700) returned `Exact legacy import or active receipt missing`. Inspection found the probe queried an uncanonicalized input path although production receipt keys use a canonical physical path, including Windows' extended path prefix. The corrected probe must prove stable StoreSpec identity and match the complete receipt identity; a later Windows run must confirm the diagnosis |
| Public 0.9.7 and formed-release jobs failed before historical execution | The new fork has no public release tag refs. [Swift public job 125393271996](https://github.com/shawway/codex-token-bar/actions/runs/41478671352/job/125393271996) obtained a native macOS runner but failed resolving `v0.9.7^{commit}`; this is not a Swift build or migration result. Windows release jobs showed the same tag prerequisite failure |
| Windows release scale remained in progress; remaining native macOS work was queued or cancelled by dependency/fail-fast behavior | No final scale or native Swift pass is claimed |

## Follow-up boundaries

Commit `46aaf215` fetches only the required public tag refs from the canonical
upstream and retains the pinned commit checks. An actual isolated, initially
tagless clone accepted the matching refs without changing candidate HEAD;
an intentionally conflicting tag was rejected without overwriting it.
This fix is included in remote `d168187f86e9a31e146d7674256badce87b68eaa`,
whose full tree `ef7694917b4e8cd9bae84459a114e951bc7b73da` matches local
`21025fc36149111526f13613032952d36648431d`. Its queued run is not evidence
that any failed job has been resolved.

The Exact receipt probe now separately verifies namespace existence and a
canonical `source_path` / `store_id` / `logical_path` / module / active receipt
tuple. It first requires the original and canonical input paths to return
the identical StoreSpec, so changing the assertion cannot hide a production
namespace-routing bug. Failure records expected and actual receipt facts.

Python launcher preparation and failure-state retention are separate changes
under implementation. A failed or timed-out fixture must preserve its owned
synthetic state and diagnostics; removing the temporary root on exception
would prevent independent diagnosis. Neither a relaxed assertion nor an old
PASS report may substitute for rerunning the exact new native candidate.

## Additional local evidence, 16:33 UTC

The CI evidence consumer now requires Swift scenarios `committed`,
`interrupted`, `enriched` and both `resume` / `reopen` phases. Thirteen Python
consumer tests and sixteen Swift formed-harness contract tests passed.
Three Node cloud pipeline / manifest / release-contract files passed (the
Node summary counts files, not individual assertions). These results verify
the evidence contract and script behavior, not native Swift compilation or
the correctness of a particular user database migration.
