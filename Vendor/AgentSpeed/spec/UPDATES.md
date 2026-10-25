# Agent Speed — Update Specification

Automatic update checks with one-click install. Both platforms implement exactly this behaviour. It sends nothing
about the user except the standard HTTP headers listed below. All network traffic of Agent Speed — this update check,
the daily price-table sync, the exchange rates and the optional live reporting — and the master switch that turns it
off are listed in `spec/NETWORK.md`; with that switch off, nothing in this document runs (manual checks included).

## 1. Source of truth

- Releases are built and published by GitHub Actions (`.github/workflows/release.yml`) when a `vX.Y.Z` tag is pushed.
  Every release contains `AgentSpeed-macOS.zip`, `AgentSpeed-Windows-x64.zip`, `AgentSpeed-Windows-arm64.zip` and
  `SHA256SUMS.txt` (`<sha256>  <file name>` per line).
- Check: `GET https://api.github.com/repos/zoefix/agent-speed/releases/latest` with headers
  `Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2022-11-28`,
  `User-Agent: AgentSpeed/<current version> (<macOS|Windows>)`. No cookies, no tokens, no other headers. Timeout 15 s.
- Fields used: `tag_name`, `name`, `body` (release notes, Markdown), `html_url`, `published_at`, `assets[].name`,
  `assets[].browser_download_url`, `assets[].size`. Drafts and pre-releases are never offered.
- Asset downloads follow redirects, but every URL (initial and after redirects) must be `https` on `github.com`,
  `api.github.com`, `objects.githubusercontent.com` or `release-assets.githubusercontent.com`. Anything else aborts.
- Asset size must be ≤ 300 MiB and must match `assets[].size`.

## 2. Versions

- Current version: macOS `CFBundleShortVersionString`; Windows the assembly informational version without `+metadata`.
- Parse `[v]MAJOR.MINOR.PATCH[-PRERELEASE]`. A release is newer when (major, minor, patch) is greater; a version with
  a pre-release suffix is older than the same version without one. Unparseable versions never update.
- Builds whose version is `0.0.0` (local development) check only when the user asks.

## 3. Schedule

- Setting `autoCheckUpdates`, default on. When on: check 30 s after launch, then every 6 h. Persist the time of the
  last successful check; on launch, if it was less than 6 h ago, wait until 6 h have passed.
- Manual "Check for Updates" (settings About section and the quick menu) always works and reports the result
  (`update.upToDate`, the available version, or the error).
- Automatic checks fail silently (logged only) and retry at the next interval. HTTP 403/429 (rate limit) wait for the
  next interval as well.
- "Skip This Version" persists the skipped tag; automatic checks never offer that tag again (manual checks still do).

## 4. States and UI

`idle → checking → upToDate | available(release) | failed(reason)`, and for install
`downloading(progress) → verifying → installing → relaunching | failed(reason)`.

When an update is available (and not skipped):
- Quick menu (macOS status item menu / Windows tray and widget menu): a top item `update.menu` ("Update to 1.2.0…")
  with a small accent dot.
- Dashboard footer: a compact pill `update.available.short` that opens the update window.
- One system notification per version: macOS `UNUserNotificationCenter` (ask for permission the first time an update
  is found; if denied, rely on the in-app indicators); Windows a tray balloon (`NIF_INFO`), which Windows shows as a
  toast. Clicking it opens the update window.
- Update window (native, compact, ~460 pt wide): app icon, `update.available.title`, `update.current`, release notes
  (Markdown rendered as rich text where the platform supports it, else plain text, scrollable, max ~240 pt high),
  buttons `update.skip` (left), `update.later`, and the default button `update.install`. During install the buttons
  are replaced by a determinate progress bar with `update.downloading` (percent), then `update.verifying`,
  `update.installing`. Errors show `update.failed` with the reason, plus `update.retry` and `update.openRelease`.
- Settings About section: `update.current` + status line (`update.upToDate` / available version / `update.checking`
  / last error), `update.lastChecked`, a `update.check` button, and the `update.auto` toggle with `update.auto.hint`.
- After a successful update the new instance shows `update.done` once (dashboard banner or notification).

## 5. Install

Common steps:
1. Download the platform asset and `SHA256SUMS.txt` into a fresh private temporary directory.
2. Find the line for the asset name in `SHA256SUMS.txt`; compare with the SHA-256 of the downloaded file
   (case-insensitive hex). Mismatch → `update.failed.checksum`, delete everything, stop.
3. Extract into the temporary directory and validate the payload (below). Never extract outside it (reject absolute
   paths and `..` entries).

macOS:
- Payload must be `Agent Speed.app` with `CFBundleIdentifier == io.github.zoefix.agentspeed` and
  `CFBundleShortVersionString` equal to the release version; `codesign --verify --deep --strict` must pass.
- Target = the running bundle (`Bundle.main.bundleURL`). If its parent folder is not writable →
  `update.failed.permission` with `update.openRelease`.
- Replace with `FileManager.replaceItemAt(_:withItemAt:)` (same volume: stage the new bundle in a temporary folder next
  to the target, e.g. `<parent>/.Agent Speed.update/`), remove `com.apple.quarantine`, then spawn a detached
  `/bin/sh -c` helper that waits for this PID to exit and runs `open -n <target>`; terminate the app.

Windows:
- Payload must contain `AgentSpeed.exe` whose `FileVersionInfo.ProductVersion` (without `+metadata`) equals the
  release version.
- Target = `Environment.ProcessPath`. Rename the running exe to `AgentSpeed.exe.old` (allowed while running), move the
  new exe into place, update `DisplayVersion` under `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\AgentSpeed`
  when that key exists, start the new exe with `--after-update <old version> --wait-pid <this pid>`, then shut down.
  If anything fails after the rename, rename the old exe back.
- The new process waits (≤ 10 s) for `--wait-pid` to exit before taking the single-instance mutex, deletes
  `AgentSpeed.exe.old` best-effort, and shows `update.done`.
- The optional traffic helper service is not replaced by this flow; the new app offers its update with one
  administrator prompt when its embedded helper is newer (`spec/WINDOWS-SERVICE.md` 5).

All update activity is logged (version, outcome, error) without personal data.

## 6. Security

- HTTPS only, host allow-list above, size limits, checksum verification, signature/identity checks above, no shell
  string interpolation of untrusted values (pass arguments as arrays), temporary files in per-user private folders,
  cleaned up on success and failure.
- The checksum file comes from the same release, so it protects against corruption and tampered mirrors, not against a
  compromised repository; this is stated in README.
