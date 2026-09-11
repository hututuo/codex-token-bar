# Detail quota pace marker

The level-three quota meters omitted the expected-remaining input/overlay although the level-one/two meters already displayed it. Swift's detail `SidebarValueBar` now receives the existing window even-pace value normalized to a fraction. Tauri's detail meter adds a non-interactive white tick using the same `sidebarExpectedFraction` helper as its rail. Both five-hour and seven-day meters are covered. Unknown/stale quota suppresses the marker. Existing nonlinear animation and reduced-motion behavior are retained; no reader, timer or index changes.

Validation: 29 Swift sidebar tests, 7 frontend display/meter/card tests and TypeScript/Vite build pass. The real IPC-unit contract test verifies a 70% detail tick, a simultaneous 50% five-hour tick and suppression when stale. Browser inspection of the production component shows the white tick at 70% independently of the 42% remaining fill. Native visual acceptance is separate from these checks.

Build and preview replacement evidence: `runs/20260911-detail-pace/`.
