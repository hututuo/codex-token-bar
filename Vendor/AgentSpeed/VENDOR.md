# AgentSpeedCore vendoring provenance

- Upstream repository: <https://github.com/zoefix/agent-speed> (Agent Speed, MIT licensed).
- Upstream commit: `a94a67fcc78e5d8eea5f82d8d5e737bccf994e2c`.
- Vendored scope: `macos/Sources/AgentSpeedCore`, its upstream `macos/Tests/AgentSpeedCoreTests`, `windows/src/AgentSpeed.Core`, and `spec/` except `spec/research/` and `spec/prototypes/`.
- Small SVG vehicle assets remain with the spec so `spec/tools/vehicles.py` retains its inputs; no large artwork or application UI was copied.
- The upstream MIT license is preserved in `LICENSE`.
- Local adaptation: `macos/Sources/AgentSpeedCore/Reporting/ReportBody.swift` and `windows/src/AgentSpeed.Core/Reporting/ReportBody.cs` change only the report client JSON `app` value from `AgentSpeed` to `CodexTokenBar`. The Swift core acceptance test checks this client identity. Upstream report-signing vectors remain unchanged as protocol reference data. User-Agent strings, namespaces, file names, and other product identifiers are unchanged.
- Live-model metadata adaptation (2026-10-27): Swift LiveWindow and C# SpeedEngine accumulate an additional source/model projection, retaining each measured/unfinalized response model and each current in-flight agent model independently. Engine output, monitor snapshots and public `SourceModelRate` carry this additive metadata. Existing source/total rates, reference estimation, history, pricing and signed report fields are unchanged. Matching behavior tests and the product-owned shared fixture (`Tests/Fixtures/activity-model-attribution.json`) guard source/model conservation.
- Test-only adaptations: the Swift strict-body checker and loopback end-to-end server overlay the client `app` schema in memory to accept both `AgentSpeed` (upstream fixtures) and `CodexTokenBar` (this product); `spec/report-schema.json` and signed vectors remain untouched. Session and live-monitor fixture tests set explicit scratch roots for every source family so nil-root defaults cannot read files from the developer's home directory.
- Shared-read adaptation (2026-10-28): the original transcript tailers delegate only physical positioned reads to Token Bar's bounded `SharedSourceIO` target (Swift) or injected `IPositionedReadBackend` (C#). Generic implementations live outside this vendor directory. Verification probes bypass caching; upstream parsers, independent offsets, response/curve counters and report calculations stay intact. The Windows parent authenticates allowed local paths and `FILE_ID_INFO` over inherited anonymous pipes; this is not a TCP listener or proxy. OpenCode/Antigravity/ZCode SQLite sources retain native read-only SQL/WAL access. Windows source opening rejects mapped remote drives, reparse points and cloud-recall placeholders. Keep these hooks and the external target/project links when synchronizing upstream.
- The Swift target uses the checkout's existing `CZstd` package target. Its public Zstd headers are version 1.5.7, matching upstream's API version; no duplicate Zstd source is vendored here.
- The upstream Swift tests are exposed as a separate `AgentSpeedCoreTests` SwiftPM test target. Fixture paths resolve inside this vendored tree at `spec/fixtures`.

## Reuse and upstream synchronization

- Reuse public AgentSpeedCore APIs for local monitoring, source parsing, calibration, execution phases/parents, bundled pricing arithmetic, and report protocol. Keep Token Bar adapters outside the vendor tree.
- `UPSTREAM.json` pins every copied upstream file and the individually reviewed local adaptations. `python3 scripts/agent_speed_vendor.py check` verifies this offline; `check --remote` checks GitHub HEAD explicitly during release preparation.
- Before a release, review upstream changes and synchronize both Swift and C# sources/specs/tests as one revision. Preserve the local Claude no-network/no-report policy, original ledgers, client identity adaptations, event-model metadata and isolated test roots.
- Follow [the maintained sync checklist](../../docs/maintenance/agent-speed-upstream-sync.md). No upstream auto-updater, account provider or network service is enabled by importing this library.
## Local optional WebSocket extension (2026-10-25)

- Adds strict Draft-1 WebSocket capability parsing in the Swift/C# discovery models; invalid optional WS fields do not disable HTTP. HTTP remains the default. Token Bar owns each platform's connection/window controller outside the vendored reporting math.
- Adds nullable source-read observations (matched wall/monotonic tuple) through readers/monitor snapshots, consumed once. Event notifications for log files are labelled `log`, never provider token events; unknown cadence remains null. WS event debounce is 50ms while existing HTTP monitor defaults and the 3-second TPS/usage/fee rules remain unchanged.
- Swift JSON parsing adds an opt-in duplicate-key rejection for WS control messages; legacy log parsing retains its existing default. Upstream signed fixtures and report schema remain reference data, not an assertion of current receiver client-ID compatibility.
- Protocol reference: https://speed-test.codexradar.com/integration.html and its `/protocol/REPORTING-WEBSOCKET.md`; production discovery at https://deng.codexradar.com/.well-known/agent-speed-report.

- Token Bar now negotiates the upstream cost section for both HTTP and WebSocket, injects the bundled PriceBook on Windows, and reports the actual bundled price version. Unknown pricing retains known-share/unpriced-request indicators; no historical upload backfill or Token Bar accounting changes.

## Local display-only metadata (2026-10-26)

- Swift/C# parser and agent snapshots carry a `localDisplayStopped` flag for explicit failure markers. A genuine generation/tool phase clears it. This metadata does not change upstream phases, response timing, counters, report sections or signed body construction.
- Token Bar projects local colored speed bars from fresh per-agent rates (20-second source silence cutoff; stopped/idle agents excluded). Raw snapshots continue into Agent Speed reporting. The local display and reporting share one collector per process; local-only collection performs no discovery, registration or signing-key creation.
