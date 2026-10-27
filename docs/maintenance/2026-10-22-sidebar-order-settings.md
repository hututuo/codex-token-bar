# Sidebar ordering and permanent settings

The second level now renders six modules from a persisted order: ModelTrace, speeds, overview, tasks, Radar, reset credits by default. ModelTrace has no added top margin. Native content is top aligned with 12pt padding; the parallel WebView removes the old first-item automatic centering margin. One TPS-row reserve is retained below the content.

A permanent bottom Sidebar Settings entry opens its own third-level settings page. The existing pin/refresh/dashboard utilities sit above it. Each row controls visibility and has up/down buttons; Restore Default Order only restores ordering. Hidden items retain their place. All modules may be hidden, since settings always remains reachable. Existing per-page visibility checkboxes remain available.

Swift uses UserDefaults quotaSidebarModuleOrder and existing hidden-module preferences. Tauri uses sidebarModuleOrder in its existing atomic settings file, exact six-entry permutation validation for saves, legacy/unknown/duplicate normalization for reads, and event synchronization between rail/detail. Config is read once per mounted webview and written on edits; no extra scanner or polling loop.

Validation: Swift54 selected,53 passed,1 opt-in skip,zero failures; frontend82 passed; Rust10 focused settings/command/auth tests passed offline/locked; TypeScript/Vite build passed. Native production window fixture captured default, multi-model, hidden and settings views. Frame heights582/582/625pt preserve the one-row growth budget. Browser component preview verified reorder, reload persistence, hide all/recover, reset order and exactly12px top inset. The preview uses labeled fixture data and a local mock native bridge; this is not a Windows hardware acceptance claim.

Local package/install evidence is in runs/20261022-sidebar-order-settings; Windows source updated, Windows build/install/hardware acceptance NOT_RUN. Usage-index, billing and TPS databases are unchanged by this feature.
