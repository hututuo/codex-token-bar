# Claude isolated-account usage discovery

## Scope

The historical usage ledger previously discovered only the selected
`CLAUDE_CONFIG_DIR/projects` (or `~/.claude/projects`). Claude Launch Center
can place local CLI/Desktop transcripts in separate, registered account
directories, so those requests never reached the importer.

Automatic discovery now also reads the launcher's bounded v1 ID registry at
`~/.local/share/claude-adapter/accounts/registry.json`. It derives only these
transcript roots:

- The selected/default Claude projects directory, keeping its existing priority.
- `~/.claude-official-guarded/projects` for the registered `existing` account.
- `accounts/<registered-32-hex-id>/code/projects` for registered isolated accounts.

This is a historical ledger fix. It does not change live quota/account selection,
speed capture, authentication, account isolation or launcher configuration.
An explicit Token Bar path preference remains exclusive.

## Integrity and bounds

- Registry reads are limited to 32 KiB and 16 account records. Unknown versions,
  invalid or duplicate IDs, and registry symlinks are rejected with an incomplete
  discovery notice. Labels never become paths.
- No account-parent crawl, wildcard profile search, Desktop storage scan,
  settings read, credential read or provider request is introduced.
- Existing directory traversal/file/classification budgets apply across roots.
  Repeated physical roots/files are removed while keeping the first logical path
  for existing checkpoints. Child symlinks remain excluded.
- The production scanner still rotates bounded batches and atomically commits
  each file's observations and checkpoint. Partial JSONL tails remain pending.
- Event IDs, schema, existing rows and effective-response SQL are unchanged.
  Copied histories with recreated session IDs are still merged by the existing
  `(client, raw model, response ID)` projection. Backfill uses the production
  importer, never manually inserted totals.
- Rust retains the existing `source_roots` interface used by other client adapters;
  its internal companion carries the additional incomplete-discovery status.

## Regression coverage

Swift regressions cover registered roots, ignored unregistered/Desktop storage,
CLI/Desktop classification, selected aliases, malformed/oversized registries,
duplicate IDs and registry links. A production-scanner regression introduces an
account after the first scan, imports new responses, deduplicates a copied
response, repeats the scan, completes an appended partial tail, retains history
after source deletion and checks the explicit-path override.

Rust covers the corresponding registry bounds, physical-root aliases, copied
responses, repeated imports, partial-tail completion, explicit overrides and
source deletion. All native compilation/tests and packaging run in hosted
workflows; no local build or dependency installation is required.

## Verification record

Product source: `05e059ba09181bf4a97026dda47470d5ee6551e2`.

- Hosted project checks `45871401564`: passed Swift, macOS Rust and Windows Rust.
  The Swift run executed 2,578 tests (38 intentional skips); macOS Rust passed
  1,863 tests and Windows Rust passed 1,805 (14 ignored on each platform).
- Public v0.9.7 upgrade check `45871401547`: passed. Candidate packaging
  `45871552221`: both macOS and Windows passed. These checks cover this source,
  not later performance or multi-root live-monitor changes.
- Installed macOS `0.9.11 / build 1061` from this exact source, with the previous
  application, preferences and pre-upgrade ledger retained for rollback.
- Read-only verification at **2026-11-27 03:43:05 +0800** found all **2,008**
  video requests and **263,914,258** input tokens including cache in the ledger.
  Pending requests and reduced counts were both zero.
- The complete isolated-account set was also present: **2,083** requests and
  **289,842,334** input tokens including cache; all **102** source-file
  checkpoints were present. No pre-existing physical event was missing.
  This matches the earlier completed-backfill verification, with no extra
  effective requests on the subsequent observation.

The production importer performed the backfill; no SQL totals were inserted.
Private account names, transcript paths, request-level evidence and maintenance
backups remain outside tracked source. This establishes historical ledger
recovery on the installed Mac. Multi-root live-speed support, later performance
changes, and Windows live acceptance require their own verification.
