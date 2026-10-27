# macOS sidebar and body-speed scrolling performance

User report: hover between level one and two feels choppy; scrolling the speed/table page also stalls. Based on native build943, branch codex/sidebar-transition-performance-20261023.

## Cause and implementation

An installed-process main-thread sample showed repeated BodySpeedTrendView range/model scans. Its per-point predicate evaluated focusModel, which scanned every point again; entries, bounds, summaries and tooltip repeated this work. The view also observed every LiveRateMonitor publication, including unrelated live-rate updates.

The chart now receives an Equatable input consisting of historical points, range, preferred model order, error and a minute-aligned time axis. Its child does not observe LiveRateMonitor. One projection per chart render resolves models and selection once, filters once and sorts into disconnected segments. New samples and range/model selection still update immediately. The time axis advances at minute granularity when the live monitor publishes; five-minute bucket values and TPS calculations are unchanged.

The native hover clock no longer forces synchronous display on every NSWindow frame. The fixed SwiftUI canvas moves via setFrameOrigin; only genuine canvas-size changes call setFrameSize. The clipping window, pointer hit area, 0.44/0.24-second motion, collapse grace, display placement and one TPS-row height allowance remain.

## Evidence

Outer run directory: runs/20261023-sidebar-transition-performance.

- Installed build943 sample: installed-943-before-transition-sample.txt (taken during active Codex work, not an idle CPU claim).
- Opt-in production-view benchmark uses 3 models x 288 five-minute points, publishes an unrelated live refresh every 100ms, and runs 3 open/close cycles. Both runs are debug builds on the same Mac; synthetic numeric points isolate UI work. They are not production throughput or guaranteed FPS measurements.
- With the speed page visible, refresh/layout median: 2396.15ms before, 1.25ms after; p95: 2665.44ms before, 2.83ms after. Before: only six refreshes and no sub-200ms resize intervals during that phase. After: 42 refreshes, 154 such resize intervals, median12.44ms, p95 25.33ms.
- Without the chart visible, resize interval p95: 25.24ms before, 23.19ms after. The major demonstrated gain is removal of chart-induced blocking, not a claim that every frame always meets a 120Hz budget.
- 54 selected regression tests: 53 pass, 1 opt-in preview skipped. Coverage includes projection/model selection, aggregation gaps, input changes, fixed host size during61 reveal frames, genuine canvas growth, existing sidebar geometry/drag/hit routing and dynamic TPS row height.

No scanner, SQLite schema, retained usage/sample data, tokenizer or speed measurement algorithm changes. No Tauri/Windows performance implementation changes in this patch; the shared model palette is updated in both clients. A separate read-only Tauri audit found a possible first-measurement retarget, which is not proof of the native macOS issue and is outside this native patch.

## 本机版 / local build

候选 build944：修复测速趋势重复计算；减少侧栏展开时的同步绘制和无效布局。只替换本机版，不发布公共更新。

Candidate build944: remove repeated speed-trend computation and unnecessary synchronous drawing/layout during sidebar reveal. Local replacement only; no public release.

Deployment and actual runtime acceptance are recorded separately in the run README/receipt after completion. Retain build943 as rollback; do not restore older databases when rolling back the app.


## Additional common-interface fixes (build945)

- DashboardView no longer observes all LiveRateMonitor publications. LiveRateView continues to observe them directly. An observing scope exists only around the settings sheet, preserving live floating/status previews; its publication-driven rerender has a production-scope regression test. Runtime subscriptions continue to refresh actual floating, sidebar and status surfaces independently.
- Heatmap pricing/model cell styles are prepared on usage/mode changes. A revision-keyed Equatable cell grid stays outside hover and range-overlay updates; its geometry still changes with interface size.
- Sidebar today-model shares update only when the model breakdown rows change, not every current-rate publication.
- Floating-panel page descriptors are calculated once per row and passed to both navigation buttons, rather than redoing pricing/page projections for each button.
- Common sixth-generation palette is Astra #e58a24 (orange), GPT-6.1 Sol #4299f5 (blue), GPT-6 Luna #d277e8 (purple). Both Swift and TypeScript registries match. Usage, activity-rate segments, body TPS, trends and model labels continue using the shared registry.
- Common-UI regression: 218/218 pass; runtime/refresh/interface-scale/palette suite46/46 pass; Web palette/gradient/parity12/12 pass. Initial broad run had one old source-string assertion for a removed pageCount argument; it now checks shared descriptors passed to both buttons, and final218/218 passes.
- Deep and light production-component palette screenshots are under palette-preview/. These are explicitly labeled synthetic numeric fixtures, not actual model speed claims.

Build944 was packaged as an earlier performance-only candidate and never installed. Final local candidate is build945; rollback remains installed943. Actual installed acceptance and further profiling are recorded in the outer run README/receipt.
