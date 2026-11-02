# Native migration diagnostic responsiveness review

Reviewed root changes `5406b88b`, `114d8a9a`, `54853720`, and `34990b51` on
2026-11-02. This note covers the diagnostic UI finding and its isolated fix;
directory identity and migration ownership are being reviewed separately.

## Finding and correction

`BusinessMigrationDiagnosticsView.refreshPreview()` ran on the main actor and
read `currentPersistenceError` and `currentMemoryPreview` synchronously. Both
properties acquire the same instance lock that `record()` holds across the
durable file write and `fsync`. Adding a one-second preparing-state refresh
therefore exposed the main actor to a slow disk operation. Animations, buttons,
and other main-actor work could wait for the diagnostic writer itself.

The UI now awaits one `PreviewSnapshot` containing the attempt identity,
persistence failure, and bounded text. The snapshot capture, lock wait, and disk
fallback all execute inside `Task.detached`; the view only checks cancellation
and assigns state on the main actor. The error and text are captured under one
instance lock after retaining one attempt, so a retry cannot combine the prior
attempt's error with a newer attempt's tail. Export uses the same joint snapshot
for its incomplete-log warning. The existing writes, `fsync`, and full retained
log export remain in place.

## Regression evidence and limits

Two XCTest cases were added in `BusinessMigrationDiagnosticsTests.swift`:

- A test-only persistence hook stops the actual writer while it holds the
  diagnostic lock. The production preview API is invoked from the main actor;
  a separate watchdog requires a main-actor heartbeat before releasing the
  writer. Its release path does not require the main actor, so a regression
  produces a bounded assertion failure instead of a deadlock. The case also
  checks that the delayed record reaches the real log afterward.
- A failed write followed by a new attempt verifies that each returned snapshot
  keeps its own attempt ID, failure state, and tail, without a stale error in the
  new attempt.

`git diff --check` passed locally. This Linux environment has no `swift` or
`swiftc`; these new XCTest cases have **not** been compiled or executed here.
The hosted native Swift test job must execute them before this change is
considered verified on macOS. The synchronous call-chain finding is a source
review conclusion, not an observed user-device freeze duration.
