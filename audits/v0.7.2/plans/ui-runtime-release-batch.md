# UI, Native Lifecycle, And Release Repair Plan

> **For agentic workers:** REQUIRED SUB-SKILLS: use `superpowers:test-driven-development` for behavior changes and perform the task-specific runtime/visual acceptance before claiming completion.

**Goal:** Close the user-visible and release-process gaps that source tests alone cannot validate.

**Architecture:** Presentation state moves into small tested models, while native visibility/tray/updater ownership moves out of short-lived dashboard components. Release packaging becomes a two-stage, version-checked process with private-key custody on Mac.

**Tech Stack:** React/Tauri, SwiftUI/AppKit, Computer Use/AX screenshots, PowerShell, macOS shell release tools.

## Global Constraints

- Stable card/header dimensions: pending/success/failure copy may not insert/remove layout rows.
- Floating/status surfaces stop work while hidden without erasing same-source trusted metrics.
- UI controls use semantic icons/groups and bounded user-facing copy; raw internal errors live in diagnostics.
- Do not change chart data semantics in a visual task.
- Windows updater private key remains on Mac.
- No release upload, tag, appcast/updater publication, or stable-branch merge without explicit authorization.

---

### Task 1: Tauri Updater Platform Guard And Reminder Cadence

**Files:**
- Modify: `tauri-app/src/app/DashboardApp.tsx`
- Modify: `tauri-app/src/api/updateClient.ts`
- Add: a pure updater scheduling/presentation model and focused tests.
- Modify: `DashboardHeader.tsx` and CSS only for the stable status slot.

- [ ] Red tests: unsupported macOS Tauri makes no automatic check and renders no error; Windows startup checks once; focus/wake/interval respect a persisted several-hour minimum; manual check bypasses cadence; raw plugin text maps to bounded categories.
- [ ] Implement platform capability guard, persisted last-attempt policy, background availability state, and stable header copy.
- [ ] Run focused Node tests/build, then inspect current macOS dashboard and a Windows capability fixture.
- [ ] Commit updater behavior/UI.

### Task 2: Tauri Heatmap And Control-Group Accessibility

**Files:**
- Modify: `tauri-app/src/components/tokenActivity/HeatmapGrid.tsx`
- Modify: cache-ranking/recent-chart control-group markup.
- Modify focused SSR/model/accessibility tests and minimal CSS.

- [ ] Red AX/SSR tests require one heatmap tab stop/group summary instead of 365 buttons and expose deliberate point navigation/selection.
- [ ] Red tests require semantic group labels for ranking/chart controls.
- [ ] Implement roving one-tab-stop or grouped chart semantics while preserving pointer range selection.
- [ ] Verify keyboard traversal and AX tree on the running Tauri app; capture before/after screenshots/AX summary.
- [ ] Commit accessibility behavior.

### Task 3: Tauri Floating/Status/Tray Native Ownership

**Files:**
- Modify: floating/status React lifecycle hooks.
- Modify: `tauri-app/src-tauri/src/platform/surfaces.rs`, commands/capabilities where required.
- Modify: tray ownership code and focused Rust/Node tests.

- [ ] Red tests prove a hidden floating webview has no quota/live/unread/Radar timers or subscription.
- [ ] Red hide/reopen status test proves trusted metrics persist without active work.
- [ ] Red native test/model proves tray action reaches status panel and tray live text continues without Dashboard webview ownership.
- [ ] Implement native visibility events, background tray updater ownership, and reachable status action.
- [ ] Runtime-check repeated floating/status open-close, single window count, CPU/IO idle, tray text, and dashboard destruction/recreation.
- [ ] Commit native lifecycle changes.

### Task 4: Swift Unread Control, Floating Scale, And Monitor Lifetime

**Files:**
- Modify Swift dashboard unread control presentation.
- Modify floating panel controller/root size model and global mouse/AX monitor lifecycle.
- Modify status-rate formatting and focused presentation/controller tests.

- [ ] Red dashboard test requires always-visible gray/blue unread baseline control.
- [ ] Red scale test proves native panel and root content use one effective scale including interface scale.
- [ ] Red lifecycle test proves global mouse/AX monitor is absent while panel is closed and restored once when opened.
- [ ] Red status formatting test preserves one decimal above 10 tok/s if that remains the accepted cross-surface format.
- [ ] Implement and run focused tests; open only the new Swift build and verify smallest/common/largest scales.
- [ ] Commit Swift presentation/lifecycle behavior.

### Task 5: Long-Chart Interaction And Responsive Matrix

**Files:**
- Modify only chart presentation/interaction files after runtime reproduction.
- Add focused model/SSR/Swift presentation tests.
- Store screenshots under this audit's screenshot directory.

- [ ] Test Swift/Tauri 24h/7d/30d at minimum/common/large dashboard sizes in light/dark.
- [ ] Verify Tauri trackpad/drag scroll, latest-window alignment, date context, hover tooltip outside clipping, and keyboard point focus.
- [ ] Verify Swift trackpad scroll updates arrow/fade state and tooltip/selection remains visible.
- [ ] Fix only reproduced interaction/layout defects; chart totals/buckets remain untouched.
- [ ] Capture final side-by-side screenshots and commit lane changes separately.

### Task 6: Windows Two-Stage Release Pipeline

**Files:**
- Modify: `scripts/build_tauri_windows_release.ps1`
- Add/modify Mac-side updater signing/metadata script and tests.
- Modify README/release docs only after scripts pass.

- [ ] Red preflight tests reject version mismatch across parameter, tag, package, Cargo, Tauri config, and built binary.
- [ ] Red Windows no-private-key test must produce unsigned installers plus reviewed manifest instead of failing.
- [ ] Red Mac signer test verifies architecture/hash/manifest before generating `.sig`, `latest-windows.json`, and checksums.
- [ ] Add a release gate that runs or verifies current Rust/Node suite evidence before packaging.
- [ ] Test with disposable artifacts; never print or copy the real private key to Windows.
- [ ] Commit scripts/tests, then update bilingual docs in a separate release-material commit.

## Runtime Matrix And Gates

- macOS: Swift and Tauri dashboard/floating/status; light/dark; minimum/common/large; keyboard/AX; sleep/wake; repeated close/reopen.
- Windows x64/ARM64: autostart, second-instance activation after dashboard destruction, tray/status/floating, DPI/multi-monitor, atomic replacement, updater install/relaunch.
- UI screenshots/AX output are evidence, not substitutes for source/tests; source tests are not substitutes for native runtime behavior.
- Final whole-branch review occurs only after core data batches and this runtime batch are integrated.
