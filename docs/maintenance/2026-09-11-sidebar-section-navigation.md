# Sidebar section navigation and compact expiry

This update includes the preceding level-three quota pace-marker fix.

- Both detail views put the pacing hint at the left and “均匀使用参考 · 余量应为 XX%” at the right of one row. The hint remains beside the quota meter. Tauri truncates an unusually long hint while retaining its full title; Swift uses a single line and a bounded font reduction.
- Compact reset-credit display adds the earliest future expiry among available cards, formatted to month/day/hour/minute. It reuses the existing credit availability and expiry sorting. No date is invented when expiry metadata is unavailable.
- Entry targets: live rate → usage, 5h/7d → corresponding quota meter, model share → model-usage section, reset credits → card list, running → task view, crowd recommendation → ranking area. Window status goes to the radar overview.
- Navigation carries a section identifier and a request revision. Repeated section clicks remain actionable. Tauri scrolls the detail container before paint; Swift uses ScrollViewReader anchors on appearance and selection revisions. Header tab selection returns to the top. Native window geometry is unchanged; compact spacing is reduced to accommodate expiry text.
- The public/crowd ranking switch remains independent from the main quota/running/radar navigation.

Validation: 49 frontend sidebar tests and 38 Swift sidebar/reset-credit tests pass, as does the frontend build. Mounted React tests verify concrete button destinations; reducer/controller tests verify repeated requests and returning to top. Reference-line tests cover both quota periods and stale-data suppression. Production-component browser rendering confirms the one-row hint/reference, visible white marker and full compact rail including expiry without clipping. Native window/pointer validation remains blocked by macOS lock state; the browser fixture is synthetic and does not establish native acceptance.

Artifacts: `runs/20260911-sidebar-navigation/`; preview replacement evidence added after packaging. No release publication, schema/index work, or additional JSONL scanning.

Both final release bundles built and signature checks passed. Preview applications replaced and restarted; built/installed executable hashes match. Exact process paths, PID and hashes are recorded in the run directory. The intermediate marker-only build was superseded, not installed. Native visual acceptance remains pending due to lock screen.
