# 0.9.5 dual-platform preparation

Status: local candidate; public publication NOT_RUN.

## Data preservation

After the Codex desktop update, all 7,906 frozen backup artifacts retained their logical SHA-256. Of 3,581 previously captured rollouts, 3,575 were unchanged and six grew by append only; none was missing or rewritten. All 14,594,918,864 original bytes matched. The seven root SQLite schemas and migration counts matched; this is a structure check, not a claim that every mutable database row was unchanged. New token-count records retained the previously supported field shapes.

Before replacing the installed Mac app, a full app backup and closed, consistent SQLite snapshots were captured. Installing 0.9.5/906 preserved all 475,321 prior events, every event field and every source owner. The post-install snapshot contained 475,406 events and 76,416,292,172 tokens. Physical, canonical, compact and attribution totals matched; the publication certificate matched generation 19843. Later new activity may increase these counts.

## Release lanes

The native macOS app uses the existing Sparkle key and ad-hoc code-signing policy. It is not notarized. Build 906 passed 1,782 Swift tests with ten skips. Source, packaged and installed executable identities are recorded in the private local evidence, separately from the final source commit. Native local startup and chart opening passed; natural low-hit notification triggering and long-duration soak are NOT_RUN.

The Windows lane uses native Windows MSVC builds for x64 and ARM64, separate Tauri update signatures and `latest-windows.json`. It adds the same cache diagnostic pipeline through a persistent sidecar, a source-bound command, one shared frontend provider and the dashboard/reminder entry points. Test and artifact status must be filled from the completed Windows gate before publication.

## Retention and accounting contract

Archive, move and delete mark source availability but retain previously recorded numeric history and cache-pair facts. A log rewrite retains the prior generation. Fork ownership follows the existing replay observer, so newly authored rounds after a fork remain eligible. Identical, complete fingerprints at the same timestamp within the same UUID may be reversibly excluded from canonical totals; physical event rows remain intact. Partial fingerprints and different UUIDs are not merged. Anonymous legacy attribution floors remain separately preserved.

Canonical projection, compact/attribution totals and scan certificate publish together. A failed scan keeps the last committed publication. Swift and Rust retain their respective transaction designs rather than sharing an artificial cross-language transaction wrapper. Cache sidecar snapshots use one read transaction and do not acquire the writer lock or migrate storage on a read-only access.

## Recommendation stability

With a small cohort addition, two nearly equivalent early change points previously swapped the recommendation from about 15 to about 3 minutes. Both implementations now select the greatest high-reuse decline among early two-segment candidates within delta BIC 2 of the optimum. Model-order selection and the later risk line remain unchanged. This is a statistical tie rule, not a hard-coded time or a cache-TTL guarantee. Synthetic perturbation and scale tests accompany the local-data comparison.

## Verification and release boundary

Frontend full suite: 1,211 pass, one skip. Frontend production build: PASS. Additional focused chart/source-race and notice tests: PASS. Native macOS package/signature checks: PASS; Gatekeeper rejection is expected under the existing ad-hoc policy.

Do not infer ARM64 device acceptance from an ARM64 build, Windows runtime acceptance from frontend previews, or public release acceptance from local packaging. Public push, merge, tag, GitHub Release, asset upload and appcast publication remain NOT_RUN. The final release review packet and Finder DMG inspection are required before upload authorization.
