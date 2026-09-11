# Cross-platform quota reference marker unit correction

The shared compact-panel projection emits remaining quota as a ratio (0–1), but even-pace expected remaining as percentage points (0–100). The new sidebar mistakenly validated both as ratios, hiding real reference values greater than 1. Its original synthetic fixtures also used the wrong units, concealing the problem.

The sidebar now converts the expected percentage to a ratio exactly once. The detail reference text uses the same validated conversion rather than applying quota-ratio conversion to percentage points. Existing floating-window and status-bar contracts remain unchanged; type comments document the distinction.

Regression evidence includes the real `useCompactPanelData` hook reading a quota bundle through mocked native IPC: actual remaining 0.19 renders 19%; a reset 70% of the period away produces expected 70, renders the bar tick at 70%, the ring tick at 252 degrees, and detail text 70%. Coverage also includes expected 0, 1, 100, missing, stale, and invalid references. The 1 case is explicitly 1%, never inferred to be 100%.

Sidebar suite: 45 PASS; updated IPC-to-hook-to-view contract suite: 3 PASS (overlaps the full suite). Logs in `runs/20260910-sidebar-pace-units/`. Package replacement evidence appended after successful build.

Final release build and deep signature verification PASS. Preview Tauri.app replaced; installed executable SHA256 matches build: b68c2c03634e51363599786626775a3204c213d75ea41efe0c570f174be4f089. Previous app retained as Tauri-before-pace-units-20260910.app.
