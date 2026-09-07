# 2026-09-08 compatibility and project cleanup

Baseline: latest formal release v0.9.1 (`6e2889f8ecef771719eb58cab0366f505500c2c5`). Reviewed main `8dc66bc631e154518b8c5945376e3425464aeef0` plus the pending dual-platform changes.

## Changes

- Real floating-window onboarding demonstrates docking and returning to floating mode. Interruption restores geometry and does not persist completion. Monitor changes cancel playback; restored windows are clamped to an available display.
- Swift startup opens independently of the dashboard's first appearance. Tauri retains native reopen handling.
- Radar accepts the current large table and numeric `models`/`points` response shape; Swift falls back to table volunteer counts. Both interfaces explain that Radar quota is not locally calculated.
- Swift rejects unknown accounting revisions before migration writes. Known incomplete stages are quarantined without altering their bytes and rebuilt; unknown or corrupt artifacts remain protected.
- Migration switch facts are durable before retirement. Interrupted cleanup can resume, including legacy manifests whose rollback was already removed. Missing/damaged active databases preserve rollback evidence.
- Tauri V22 caches use complete binding checks. Both final index schemas are 12; structural migration phase 11 is not the final schema version.

## Validation and limits

Swift final suite: 1482 executed, 4 skipped, 0 failures. The unchanged frontend suite passed 1039 tests; Rust final recheck passed 1049 with 5 ignored and one separately verified large case filtered. macOS bundles passed signing checks and were activated. Tauri close/reopen was verified after cache cleanup; Swift startup/main-window presence was verified, while its final close/reopen inspection was interrupted by the Mac locking.

Final validation results are recorded in `runs/20260908-project-cleanup/REPORT.md`; original audit and suite logs remain in `runs/20260908-release-compat/`.

Windows x64/ARM64 installation, mixed-DPI monitors, macOS multi-display/Space/fullscreen and old-binary downgrade against a new database were not accepted in this maintenance pass. No new version was published or pushed to main. Existing release artifacts and tags remain intact.

## Cleanup scope

Removed two clean obsolete worktrees whose changes were merged or patch-equivalent, and thirteen remote branches already merged into published origin/main. Exact old refs and restoration commands remain in the cleanup evidence folder.

Removed obsolete preview app bundles and regenerable build caches. Retained the current Swift and Tauri runnable bundles, one pre-cleanup rollback pair, formal release artifacts, source and audit evidence. User session data and application databases were not cleanup targets.
