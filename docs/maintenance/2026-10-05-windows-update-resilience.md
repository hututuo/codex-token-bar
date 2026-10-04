# Windows updater resilience

## Verified problem boundaries

A new executable could restore persisted availability for its own version before
the four-hour check interval elapsed. This is independent of the reported older
Start-menu executable. Customer installation paths remain unverified.

The published updater dependency ignored ShellExecuteW's failure return and
cleaned up the application before attempting launch. The NSIS payload policy
allowed skipping failed writes. Launch, payload replacement, registry version,
shortcut repair and running-version acknowledgement are different boundaries.

## Changes

- Filter cached equal/older/invalid versions before presentation; use semantic
  version precedence, ignoring build metadata. Initialization is serialized and
  marked complete only after loading. Filtering stays in memory until regular
  persistence to avoid a canceled initialization's detached cleanup write.
- Return alreadyLatest for an install-time check with no newer release; reread
  registry state on every install return and immediately reconcile the tray.
- Keep Tauri download/signature verification. The pinned local 2.10.1 patch only
  checks Windows launch errors and moves cleanup after successful launch.
- Validate the current executable belongs to the registered current-user
  installation; bind NSIS to that directory with the last unquoted /D= argument.
  Unknown or mismatching installations require the official manual installer.
- Forbid skipped payload writes in both manual and automatic installers.
  Repair only existing product-owned canonical Start-menu/desktop shortcuts
  after successful payload installation, respecting /NS.
- Record source/target versions, destination, timestamp and launch failure in
  update-install-attempt.json. A later process confirms only matching directory
  and version at least the target. An old/other copy remains unconfirmed.
  Receipt corruption never discards valid update-monitor availability.

## Verification

Local: 32 tests of extracted production state core, receipt and launch gate;
11 updater UI/bridge tests; 102 script tests passed, one platform-only skip.
The lightweight Rust harness substitutes disk writes/platform bindings and is
not a full Tauri build or Windows acceptance result. Full frontend local tests
require removed build dependencies and run in hosted CI.

Hosted CI includes the real production hooks in a small NSIS installer:
failed ShellExecute, locked payload abort in silent/interactive modes before
registration, Chinese/space destination and existing shortcut repair.

## Limits

No installer transaction or crash/blackout rollback is claimed. A successfully
started installer is pending until the new process verifies its version/path.
Unknown duplicate installations and user-created links are not deleted or
rewritten. Existing customer recovery, actual old-to-new app upgrade and release
acceptance remain separate from source/unit/fixture validation. This change
does not touch token indexes, session files or account features.
