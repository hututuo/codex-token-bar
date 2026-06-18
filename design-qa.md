# Design QA

## Visual Source

- Main dashboard reference: `Assets/DashboardPreview.png`
- Floating panel reference: `Assets/FloatingPanelPreview.png`

## Implementation Checked

- Main dashboard screenshot: `runs/20260618-tauri-ui-match-swiftui/window-typography-2.png`
- Floating panel screenshot: `runs/20260618-tauri-ui-match-swiftui/floating-typography-2.png`
- Side-by-side comparison: `runs/20260618-tauri-ui-match-swiftui/comparison-typography.jpg`
- Viewport: Tauri macOS main window, 1180 x 860, light mode.

## Result

Passed for this migration pass.

- Main dashboard now follows the SwiftUI reference structure: centered account header, compact quota strip, stats strip, live rate card, token activity heatmap, and visible 24-hour section entry.
- Typography was reduced and softened for the Tauri/Windows-rendered frontend by using system fonts first and lowering the high web-style font weights.
- Floating panel no longer clips the quota row and now keeps the quota labels on one line.
- Large shadows and blur-style visual effects are not used in the migrated layout.

## Known Differences

- Tauri shows its native title bar in debug/dev captures, while the SwiftUI release screenshot has a different macOS shell treatment.
- Live values differ between screenshots because they come from the current local data/mock fallback rather than the historical screenshot state.
