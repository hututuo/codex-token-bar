# AgentSpeedCore vendoring provenance

- Upstream repository: <https://github.com/zoefix/agent-speed> (Agent Speed, MIT licensed).
- Upstream commit: `a94a67fcc78e5d8eea5f82d8d5e737bccf994e2c`.
- Vendored scope: `macos/Sources/AgentSpeedCore`, its upstream `macos/Tests/AgentSpeedCoreTests`, `windows/src/AgentSpeed.Core`, and `spec/` except `spec/research/` and `spec/prototypes/`.
- Small SVG vehicle assets remain with the spec so `spec/tools/vehicles.py` retains its inputs; no large artwork or application UI was copied.
- The upstream MIT license is preserved in `LICENSE`.
- Local adaptation: `macos/Sources/AgentSpeedCore/Reporting/ReportBody.swift` and `windows/src/AgentSpeed.Core/Reporting/ReportBody.cs` change only the report client JSON `app` value from `AgentSpeed` to `CodexTokenBar`. The Swift core acceptance test checks this client identity. Upstream report-signing vectors remain unchanged as protocol reference data. User-Agent strings, namespaces, file names, and other product identifiers are unchanged.
- Test-only adaptations: the Swift strict-body checker and loopback end-to-end server overlay the client `app` schema in memory to accept both `AgentSpeed` (upstream fixtures) and `CodexTokenBar` (this product); `spec/report-schema.json` and signed vectors remain untouched. Session and live-monitor fixture tests set explicit scratch roots for every source family so nil-root defaults cannot read files from the developer's home directory.
- The Swift target uses the checkout's existing `CZstd` package target. Its public Zstd headers are version 1.5.7, matching upstream's API version; no duplicate Zstd source is vendored here.
- The upstream Swift tests are exposed as a separate `AgentSpeedCoreTests` SwiftPM test target. Fixture paths resolve inside this vendored tree at `spec/fixtures`.

## Reuse and upstream synchronization

- Reuse public AgentSpeedCore APIs for local monitoring, source parsing, calibration, execution phases/parents, bundled pricing arithmetic, and report protocol. Keep Token Bar adapters outside the vendor tree.
- `UPSTREAM.json` pins every copied upstream file and the six reviewed local adaptations. `python3 scripts/agent_speed_vendor.py check` verifies this offline; `check --remote` checks GitHub HEAD explicitly during release preparation.
- Before a release, review upstream changes and synchronize both Swift and C# sources/specs/tests as one revision. Preserve the local Claude no-network/no-report policy, original ledgers, client identity adaptations and isolated test roots.
- Follow [the maintained sync checklist](../../docs/maintenance/agent-speed-upstream-sync.md). No upstream auto-updater, account provider or network service is enabled by importing this library.
