# Agent Speed independent reporting route — 2026-10-25

> 2026-10-26 状态核对：本文保留当时证据；当前完成项与剩余验收请见 [2026-10-26-speed-follow-up-status.md](2026-10-26-speed-follow-up-status.md)。早期服务端 422、Windows 尚未安装和图表尚未产品化不代表当前状态；真实整页 FPS、睡眠/切网及延迟目标仍未验收。

## Scope and baseline

Source: `runs/20261022-cache-advice-isolation/release-source`, baseline `c63b8b3e` on `codex/dashboard-scroll-quota-20261023`. Existing installed macOS 0.9.7/build954 is preserved. This change does not change body TPS, its confidence filters, the animated speed bar, cache alerts, quota cycles, or the usage/cost index.

Pinned Agent Speed 1.4.1 at `a94a67fcc78e5d8eea5f82d8d5e737bccf994e2c`; upstream MIT license and provenance are under `Vendor/AgentSpeed/`. Native Swift uses the upstream Swift core. Windows uses a persistent bundled .NET helper with the upstream C# core. End users need neither Agent Speed nor a .NET SDK installed.

Sources: Codex, Claude Code, local Claude Desktop Code/Agent sessions, DSH, OpenCode, Gemini CLI, omp, Antigravity, WorkBuddy, WorkBuddy AI, ZCode, Kimi Code, Grok Build. Discovery/parsing follows upstream default roots and environment overrides. Cloud conversations without local records are not readable. Platform/source availability follows the upstream implementations.

## Measurement and reporting

This is an independent metric; body TPS is never reused for the leaderboard. Codex settlement `output_tokens` includes reasoning; upstream request/timing inference, live window, estimated share, baseline/deltas, scheduling and bounded retries are reused. It is not a measurement of exact server generation time or network streaming speed. Timing can include first-token wait, stalls and log timing uncertainty.

The initial complete scan is a baseline, not historical token backfill. Subsequent upstream counter deltas are sent. A restart/new run similarly seeds a new baseline. Reporting is gated by persistent opt-in and stops on opt-out. No background registration, scanner or key creation before enabling. A scan failure does not alter Token Bar's historical index.

Discovery: `https://deng.codexradar.com/.well-known/agent-speed-report`.
API must remain exactly `https://speed-api.codexradar.com/api/agent-speed`; changed endpoints fail closed.
`client.app` is `CodexTokenBar`. Server acceptance of this identifier is an explicit integration prerequisite. ECDSA P-256/ES256 signing, timestamp, nonce, request body hash and scheduler come from upstream. API redirects are refused. Reporting does not use Codex credentials, auth files, or an intercepting proxy.

Allowed payload includes client/version/platform, random per-device ID, public nickname, run/sequence/timestamps, activity, token counts, speeds, estimated share, model and source/Harness aggregates. Cost, process/machine traffic and file paths are not enabled. No conversation, prompt, body, tool output, account credential or machine name is sent. Default nickname is a random `TokenBar-xxxxxxxx`, not the OS username or hostname. Standard HTTPS inherently discloses the connection address to the server; do not claim “no other information whatsoever.”

Two reporters reading the same local files can double-count: only one of Agent Speed and Token Bar should report a given source on a given machine. This is explicitly disclosed; aggregate protocol payloads do not provide request-level IDs for client-side cross-app deduplication. Shared identity/avatar/aggregation/leaderboard backend capabilities are reused rather than recreated; server interoperability remains a separate live acceptance gate.

## Consent and invitation

Settings has a persistent, default-off “参加排行榜” toggle, editable public nickname while off, status, supported-source list and site/privacy/terms links. Users may turn off at any time. Existing identity is retained for later reuse; turning off does not delete historical server statistics.

The dashboard offers a one-time invitation with a local 17.93-second silent leaderboard recording, captured from the public site at the user's request. It is marked as a recording, not live data. The 1128 × 826 H.264 clip (3.1 MB) plus high-quality poster are bundled; opening the invitation contacts no website. Default switch is off; “开启并参加” stays disabled until deliberately checked. Dismissal remains remembered. No automatic browser opening.

The video plays once, can pause/replay, and stops when dismissed/hidden. Reduce Motion disables autoplay; native Low Power Mode also disables autoplay. The unconsented invitation never invokes report registration. The preview page is UI-only and cannot register a device or send statistics.

## Files

- Swift: `AgentSpeedReportingController.swift`, `AgentSpeedReportingIdentity.swift`, `AgentSpeedReportingView.swift`; app/settings/startup wiring and `Package.swift`.
- Web: `AgentSpeedReporting.tsx`, `agentSpeedReporting.css`; dashboard/settings wiring and global CSS import.
- Windows: `tools/AgentSpeedReporter/`, Rust core/commands/settings registry and Windows build integration.
- Resources: `Sources/CodexTokenBar/Resources/SpeedLeaderboard/`, `tauri-app/public/speed-leaderboard/`.
- Evidence: `assets/2026-10-25-agent-speed/invitation.png`; tests listed below.

## Validation

PASS:
- `swift test -j 4 --filter 'AgentSpeedCoreTests|AgentSpeedReportingTests'`: 647 upstream Swift tests and 6 Token Bar consent/privacy/baseline tests. Native app and video UI compiled successfully.
- Python upstream reference: 34 transcript fixtures, 11 Antigravity databases, 23 engine cases and price cases.
- TypeScript typecheck; frontend invitation/settings tests: 23 passed.
- Browser UI: unchecked default, disabled join button until checked, public nickname/duplicate-source notice after checking, light/dark layouts, Reduce Motion keeps video paused. Bundled media is muted, non-looping, 17.93 seconds.
- Windows helper: official isolated .NET 10.0.303 build, self-tests and self-contained win-x64 / win-arm64 cross-publish passed. No global SDK installation.

The upstream tests required explicit scratch roots for all source families to avoid reading the developer's installed apps. The local fake report service accepts both client identifiers in its in-memory test schema; production schema/reference vectors remain unchanged. Real service client compatibility is **not** inferred from fake-server success.

Windows bridge validation also passed: 7 Rust reporting tests and 37 Node Windows-release script tests (one Windows-only PowerShell fixture skipped on macOS). No public release, replacement of the installed app, real device registration, or real telemetry submission was performed during implementation. Production backend compatibility and Windows interactive deployment are separate acceptance gates.

## Higher clarity recording revision

At the user’s request, re-recorded the public leaderboard at 2× device pixel density and replaced both bundled media copies. Final video: 1128 × 826, 17.933 seconds, 3,129,537 bytes; H.264 CRF 14, 30 fps container with real capture timing (174 source frames, no synthetic interpolation). The invitation aspect ratio follows the crop in both clients. No consent or reporting behavior changed.

## Final Windows build receipts

- PASS: latest helper Release build (0 warnings/errors), self-tests, self-contained `win-x64` and `win-arm64` cross-publish with official isolated .NET 10.0.303. NuGet v3 TLS fetch failed; one official v2 restore succeeded. Temporary SDK/build outputs were removed after recording receipts.
- PASS: 7 Rust reporting tests on macOS; 37 release-script Node tests, 1 Windows-only PowerShell fixture skipped.
- BLOCKED: offline Windows-target Cargo check reached `ring` C compilation but this macOS host lacks Windows SDK C headers (`assert.h`), before the Token Bar Windows crate could typecheck. This does not establish a complete Windows app build.
- NOT_RUN: actual Windows helper/app execution, DPAPI acceptance, installed invitation rendering, complete Windows installer build, real backend registration/reporting.
- Verified setup-dotnet v6.0.0 immutable tag SHA: `a98b56852c35b8e3190ac28c8c2271da59106c68`.
- Higher clarity media follow-up: native `swift build -j 4` passed; invitation UI tests 2/2 passed; browser confirmed videoWidth=1128, videoHeight=826, duration=17.933333, muted=true, loop=false.


## Build955 local acceptance follow-up

After the user explicitly authorized local replacement and real reporting, macOS build955 was installed with prior-app/preferences/three-DB rollback backups. TPS distribution and invitation changes are documented in [the build955 receipt](2026-10-25-tps-distribution-build955.md). The previous NOT_RUN statements above describe the initial source-only implementation.

The new invitation recording is 1684×1100,16seconds,60fpsplayback,10,550,916bytes; actual source capture30.6fps versus old9.8fps. Both clients have the same new asset and two-step highlighted consent hint; the nickname/hint layout no longer changes height on toggle.

Real discovery returned200, but registration returned422 `payload_invalid` at `/client/app` for `CodexTokenBar`, confirmed by one same-device signed retry. The installed UI is enabled/error; no report reader or statistics submission began. Live registration/authentication/report/leaderboard acceptance is **BLOCKED on service compatibility**, not passed. No impersonation as AgentSpeed, public release, push, or multi-client merge occurred.
