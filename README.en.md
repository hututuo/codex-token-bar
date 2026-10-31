<p align="center"><img src="Assets/showcase/icon.png" width="80" alt="Codex Token Bar"></p>
<h1 align="center">Codex Token Bar</h1>
<p align="center"><b>Stay focused. Keep usage, quota, and progress in sight.</b></p>
<p align="center">Flexible desktop views · Official quota · Cache alerts · Usage history · Model TPS</p>
<p align="center"><a href="README.md">简体中文</a> · English</p>
<p align="center"><a href="https://github.com/hututuo/codex-token-bar/releases/latest">Download</a> · <a href="#installation">Installation</a> · <a href="#the-rest-of-your-workbench">All features</a> · <a href="docs/DEVELOPMENT.md">Development</a></p>

How much quota is left? Which sessions are running? Did the cache hit? How quickly is a model writing? **Token Bar keeps that context in your peripheral vision. Expand it when you need the details.**

Native Swift / SwiftUI on macOS; Tauri + React + Rust on Windows x64 and ARM64. Usage accounting and body-speed analysis run locally and support concurrent sessions.

## Local statistics across clients

Codex remains the default. When supported clients such as Claude CLI or Claude Desktop are detected, enable them explicitly and switch between individual and aggregate views. Claude reads only local transcripts and existing quota caches, never making requests to Anthropic; unavailable local quota is not fabricated. Official Codex quota requires a locally signed-in Codex.

Leaderboard reporting is a separate, default-off option that can be disabled at any time. It uploads only permitted speed, Token, model, and Harness statistics, never conversations or account credentials; Claude sources are excluded. Two local business databases preserve the Codex ledger and additional client/speed records. Upgrades keep backups, and deleting original transcripts does not erase recorded history.

## See what is happening without switching windows

**An edge sidebar, floating panel, menu bar / tray, and dashboard. Choose the view that fits your work.** Official quota monitoring is built into those views.

<p align="center"><img src="Assets/showcase/displays.gif" alt="Edge strip, hover summary, quota details, left/right docking, and floating panel using production UI components" width="100%"></p>

| View | What it does |
|---|---|
| Edge sidebar | Dock left or right, snap to an edge, and remember placement. A narrow strip at rest, a summary on hover, and details on click. |
| Floating panel | Keep rate, usage, tasks, model shares, and quota on the desktop. Drag it, choose content and order, and adjust colors, type size, and opacity. |
| Menu bar / tray | Keep a status entry while the main window is hidden. Appearance and customization vary by platform. |
| Dashboard | Review usage, quota, charts, cache rankings, model speeds, and session management together. |

**Quota and pacing in the same place.** Show the 5h / 7d windows and reset times actually returned for the account, plus Reserve when provided. The white marker is an even-usage reference, not another measured quota. Reset-credit details display the count, source, and expiry when returned; the app does not automatically redeem credits.

## Follow the timeline to see where quota went

**How much did that task use? When was today's busiest stretch? Select a period and compare local usage with quota changes.**

<p align="center"><img src="Assets/showcase/usage.gif" alt="Production usage chart switching between 24-hour, 7-day, and 30-day views" width="100%"></p>

- **24h / 7d / 30d trends:** five-minute buckets in the 24-hour view. Toggle tokens, calls, cache hits, API-equivalent costs, and quota series.
- **Hover, scroll, and select:** review historical windows and aggregate a selected interval, including model composition and quota changes. Infer a reference window budget from usage and quota movement within the same cycle.
- **365-day activity heatmap:** daily, weekly, cumulative, model, cost, cache, and quota views. Select two dates to summarize a period.
- **Model and token breakdowns:** separate input, cached input, and output. Cached input is already part of input.

<p align="center"><img src="Assets/showcase/heatmap.png" alt="Annual token activity heatmap" width="100%"></p>

Measured remaining quota, pacing references, and API-equivalent costs are labeled separately. **API-equivalent costs are estimates using known model prices, not actual subscription charges.** Unknown prices produce a known-price subtotal or an unavailable state.

## Quota dropping unexpectedly? Check the cache

After a model, reasoning-effort, or context change, **the sidebar can notify you when a request has low cache reuse**, showing its hit rate and related session. Check the recent operation without returning to the dashboard.

<p align="center"><img src="Assets/showcase/cache-reminder.gif" alt="Demo: change reasoning effort, enable Fast, send a message, and show a low-cache-hit reminder" width="100%"></p>
<p align="center"><a href="Assets/showcase/cache-reminder.mp4">Watch the complete 12-second demo with sound effects</a></p>

Alerts are optional; the first request in a new context is exempt. They use reported token usage, **not elapsed idle time**. Model, effort, and context changes are possible investigation leads, not causes proven by the alert.

The dashboard also ranks sessions or turns by cache hit rate, with cached / uncached token counts, search, filtering, and context.

## What is running, and which model writes faster?

**The activity curve shows work in progress. Body TPS compares output samples.** The sidebar shows the latest qualified reading per model within 30 minutes; details include 15- and 30-minute averages.

<p align="center"><img src="Assets/showcase/body-tps.png" alt="Per-model body TPS averages and the six latest traceable samples" width="100%"></p>

| Metric | Meaning |
|---|---|
| Live activity rate | A local estimate across sessions, visualizing work cadence. Stops on a recognized interruption and finishes within five seconds of normal completion. |
| Body TPS | Locally tokenized completed assistant prose divided by its logged start/end duration, including intermediate messages and final text. Latest readings, model averages, and traceable samples. |

The dashboard shows six recent samples. Details identify **time, session, turn, body ID, body type, tokens, duration, TPS, and confidence**. Short timings, inconsistent timing, and anomalous rates remain explainable but do not contribute to model averages.

Body TPS may include network waiting; it is not pure server generation throughput. Hidden reasoning and tool returns are not body-speed samples. The animated activity rate is not stored as a measured speed sample.

## The rest of your workbench

| Feature | Capability |
|---|---|
| Concurrent tasks | Running main sessions and subagents, model and reasoning effort, completion and unread feedback. |
| Durable accounting | Already-indexed usage survives archive, move, or deletion. Count new fork-owned turns and avoid double counting compressed / uncompressed sources. |
| Reference feeds | Official Radar suggestions and trends plus community RadarBench rankings and coverage. Third-party source and data status are identified. |
| Session management | Search, archive, unarchive, and create / verify / export recovery packages. Inspect the affected scope and back up before permanent deletion. |
| Session enhancements | Optional Markdown export, project moves, IDs, paste fixes, reading width, and scroll restoration. |
| Isolated instances | Separate Codex Home and desktop data directories, launch / stop, configuration and session synchronization, conflict retention, and verified rollback. |
| Automatic continuation | Select an exact session; configure intervals, daily schedules, quota recovery, or specific failures, with cooldown and daily limits. Off by default. |
| Desktop customization | Floating content, order, colors, text size, opacity, completion feedback, and surface toggles. |

“Auto-approve ordinary operations” is a separate, disabled-by-default continuation option. Dangerous actions, extra permissions, manual input, and unknown requests remain blocked. Legacy direct deletion from the Codex sidebar is disabled; use Token Bar's session-management workflow.

**Interactive showcase:** [source](docs/showcase/index.html). Run `python3 -m http.server 8080` from the repository and visit `http://127.0.0.1:8080/docs/showcase/`. Try sidebar modes, left/right placement, full details, floating-panel paging, chart legends, and time ranges.

Display surfaces, usage charts, and body TPS use an owner-authorized snapshot of real local statistics, dated in the view. They are neither live monitoring nor model benchmarks. Surfaces use production cross-platform components and styles. The separate cache film uses a simulated scenario and a natively rendered Bar warning. See [asset provenance and rebuild instructions](docs/showcase/README.md).

## Installation

Download the installer for your platform and matching `SHA256SUMS` from [GitHub Releases](https://github.com/hututuo/codex-token-bar/releases/latest).

If Windows version 0.9.8 cannot open with “Ledger preparation incomplete,” install the new version over the existing installation. Do not uninstall or delete the data directory, old databases, or migration receipts.

| Platform | Asset | Requirements |
|---|---|---|
| macOS Apple Silicon | `CodexTokenBar-v0.9.9-macos-arm64.dmg` | macOS 14+. Open the DMG and drag the app to Applications. |
| Windows x64 | `CodexTokenBar-v0.9.9-windows-x64-setup.exe` | Intel / AMD Windows 10/11. |
| Windows ARM64 | `CodexTokenBar-v0.9.9-windows-arm64-setup.exe` | Windows on ARM; the app binary is ARM64. |

Optional checksum verification; compare the result with the matching release manifest:

```bash
shasum -a 256 CodexTokenBar-v0.9.9-macos-arm64.dmg
```

```powershell
Get-FileHash .\CodexTokenBar-v0.9.9-windows-x64-setup.exe -Algorithm SHA256
```

The macOS app is ad-hoc signed and not notarized. If blocked on first launch, confirm Open Anyway in System Settings → Privacy & Security. Windows installers do not currently have commercial code signing; SmartScreen may show an unknown-publisher warning. Download from this repository's Releases. The installer handles missing WebView2 according to its default policy.

Alternative macOS command: installs the latest release and replaces an existing application.

```bash
curl -fsSL https://raw.githubusercontent.com/hututuo/codex-token-bar/main/install.sh | bash
```

macOS uses Sparkle; Windows has a separate Tauri update channel. Checks run every four hours by default and installation requires confirmation. If updating fails, use the installer for the same architecture and retain local history.

## Data and common questions

- **Sources:** local Codex Home `sessions/` supplies usage and turns; SQLite metadata supplements session information. Token Bar keeps its own local statistics index. Quota and reset credits come through the official local Codex app-server, with networking and authentication handled by Codex.
- **Privacy:** the app does not upload prompts, output, session logs, or account quota. Account queries and external Radar feeds require networking; feed references and local statistics are labeled separately.
- **Missing 5h / Reserve:** only windows returned for the account are shown.
- **Quota unavailable:** confirm Codex is signed in and can access the account, then report the platform, version, and application diagnostics.
- **Deleted sessions:** already-indexed usage remains. Usage never read before its source was lost cannot be reconstructed from nothing.
- **Follow-up timing advice:** the old advice, cache-interval chart, and additional scanner remain isolated and inactive. Cache accounting, alerts, and the cost ledger remain available. [Historical design](docs/design/cache-retention-dynamic-p95-drop.md).

See [development and maintenance](docs/DEVELOPMENT.md) for source builds, packaging, update signing, and the optional Codex sidebar patch.

## Feedback

[Open an issue](https://github.com/hututuo/codex-token-bar/issues) with OS version, application version, error text, and screenshots, or join the WeChat group.

<p align="center"><img src="Assets/wechat-group-qr.jpeg" width="240" alt="WeChat group QR code"><br><sub>The code expires; report an expired code through an issue.</sub></p>

## License

GNU AGPL v3. The original Codex Token Bar [MIT notice](LICENSES/CodexTokenBar-MIT.txt) is preserved. Codex++ attribution and modifications are documented in [OPEN_SOURCE_NOTICES.md](OPEN_SOURCE_NOTICES.md).
