# Required recovery evidence through signing and publication

## Findings and repairs

Review of the integrated CI change `18d39315` found that it added
`database_recovery_required: true` to `checked-source.json`, while
`release_packet.py` still required the old three-field dictionary exactly.
Consequently the signing step would reject every new CI result. Merely
accepting an extra flag would not establish that the native gates ran.

The cloud console also called an old, fixed revision of all reusable
workflows. Selecting a new candidate source did not update those workflow
definitions, so the console's checks could omit the new recovery gate.

The repaired chain is:

1. `ci.yml` waits for its required `database-recovery` reusable workflow.
2. Its evidence job downloads
   `recovery-checked-source-${source_sha}` from the **current run**, into
   `recovery-evidence/recovery-checked-source.json`.
3. `ci_evidence.py seal` validates the native verdict's source SHA, run ID,
   actual dependency results, all four formed releases and all four Swift
   scale sizes. It embeds the complete verdict, including its coverage limits,
   in the version-2 CI evidence. Missing or unsuccessful proof cannot produce
   the success file.
4. The signing guard downloads `ci-passed-${source_sha}` from the explicitly
   selected CI run and verifies the proof **before** the protected signing
   job. The signing implementation independently verifies it again.
5. The signed packet retains `checked-source.json` as a hashed supporting
   artifact. Packet schema 2 requires this file; the publication verifier
   checks its outer and nested SHA/run identities again. It is not one of the
   nine public update assets and contains no signing key.
6. The cloud console uses local reusable-workflow references, keeping its
   check/build/sign/publish protocol at the caller's immutable commit while
   still passing the resolved candidate source SHA explicitly.

Older three-field or flag-only CI evidence and old schema-1 signed packets are
intentionally rejected. A candidate must obtain the current required checks
and be signed again. This changes release evidence, not installed databases,
historical releases or existing public updater keys.

## Permissions and source identity

The recovery workflow still needs only `contents: read`. It accepts the
caller's exact 40-character SHA, and its checkout/test jobs use that resolved
SHA. The evidence job uses a same-run artifact download with no additional
GitHub API token. Signing and publishing retain their existing `actions: read`
permission for explicitly selected cross-run downloads; no new signing secret
is available to CI or the pre-approval signing guard.

The same-repository `./.github/workflows/...` syntax selects the caller's
commit, not an independently moving branch. This follows GitHub's
[reusable-workflow reference rules](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows).
The artifact action documents that an omitted token/run selects the current
run and a named artifact extracts directly into the requested directory;
cross-run downloads require an explicit token/run. See the official
[download-artifact inputs](https://github.com/actions/download-artifact#inputs).

`run-guard.py` checks successful same-repository workflow provenance; it does
not equate a dispatch workflow's `head_sha` with the candidate SHA. That is
appropriate for workflows accepting `source_sha`: the artifact contents bind
the candidate, and this repair now checks both the CI envelope and native
verdict against the requested SHA and CI run.

## Local verification and remaining gates

- Thirteen Python tests passed, including flag-only proofs, omitted jobs,
  failure/cancellation/skips, partial or duplicate matrices, source/run
  mismatches in either envelope, nonboolean passes, and a real CLI seal/verify
  round trip. Failed input produces no success file, and existing output is
  not overwritten.
- A signer integration test rejects unproved evidence before network/key
  operations. A packet-verifier test rejects a mismatched nested recovery
  run even when all packet file hashes match.
- All three cloud-script test files passed, including the consumer tests.
- No actual signing, release publication, Cargo build or native Swift run was
  performed for this review.

The current native verdict truthfully covers Rust formed-release states on
Windows/macOS and native Swift source-count scale. It still does not prove
native Swift formed-release v0.9.8–v0.9.11 states. A subsequent integration
now requires the public-v0.9.7 workflow as the `public-v097` dependency and
validates its pinned release SHA in the verdict. Both its Swift and Windows
jobs must succeed; duplicate standalone push/PR triggers were removed. This
wiring is not evidence that those native jobs have executed for the new
candidate. Real final-source results remain required.
