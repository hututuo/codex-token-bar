# Sidebar meters and click feedback

Implemented in Swift and Tauri:

- Quota bars and rings display a white expected-remaining reference mark, using the existing pacing value; unknown or stale values hide the mark.
- Sidebar buttons flash briefly on activation and fade, without a persistent selection background. Keyboard focus remains visible.
- A segmented model Token share strip reuses today's floating-window aggregation and colors. The expanded strip opens the quota overview; the detail legend uses the same aggregation.
- Compact rail heights accommodate the extra strip: 192 without 5h quota, 250 with 5h quota. Expanded native canvas geometry is unchanged.

Validation: frontend 44 tests PASS; Swift sidebar 29 tests PASS; Rust sidebar 17 tests PASS; both release builds and signatures PASS; git diff whitespace check PASS. Evidence logs: runs/20260910-sidebar-meters/.

Both preview bundles were replaced in the original project's dist/quota-sidebar-preview directory, with before-meters-20260910 backups. Installed executable SHA256 matches each build. Fresh processes: Swift 73848, Tauri 73850. The actual Tauri floating window was confirmed through accessibility.

Full live sidebar interaction and animation visual acceptance remains NOT_RUN for this revision; the fixture layout inspection is not a frame-rate or click-feedback measurement. Windows runtime acceptance NOT_RUN.
