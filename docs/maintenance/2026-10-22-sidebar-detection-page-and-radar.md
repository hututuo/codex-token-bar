# Sidebar detection page and Radar clock consistency

## Changes

- Sidebar ModelTrace now navigates to its own third-level page on both implementations. The homepage modal reuses the same content. Existing source/account checks and manual three-request behavior remain in place; viewing the page does not start a probe.
- ModelTrace participates in module visibility. At least one entry stays visible so removing the redundant bottom Menu button cannot lock users out. Legacy all-hidden preferences retain ModelTrace as a recovery entry. Explicit visibility changes still remeasure and shrink the rail.
- Shared native Radar state and boundary schedule drive the edge, rail status and detail card. The schedule wakes at announcement expiry and local freshness expiry, including Reduce Motion. Tauri refreshes its time-dependent summary alongside the title and edge.
- The chart guide has two instructions (hover preview, then two-click interval calculation) and a visible cursor press. It remains display-only with reduced-motion support.

## Live upstream check

Checked 2026-10-22 around 21:25 Asia/Shanghai. Public current.json had window_open=true, opened_at=2026-10-22T14:55:22+08:00, closed_at=null and no countdown deadline. The homepage open announcement also had no data-window-closes-at attribute and displayed pending official confirmation. No finish time is inferred from prose. The top-level monitored_at is older than the window announcement; it is not used as the start/end time.

## Verification

- Swift selected sidebar, ModelTrace, recent chart and Radar countdown tests: 82 selected, 81 passed, one opt-in skip, zero failures. Includes production native rail/detail captures, last-visible persistence, no-deadline open window and both normal/low-frequency boundary entries.
- Frontend: 149 passed, including in-place detection, no automatic request on page open, source-scoped manual start, visibility, Radar expiry parity, chart guide and hit targets.
- Rust: seven focused offline/locked settings/auth tests passed. Main and quota-sidebar-detail can invoke existing ModelTrace commands; quota-sidebar cannot invoke them or the old modal opener.
- TypeScript and Vite production build passed.
- Native local installation is recorded separately in the task run receipt. Windows source is synchronized; a Windows build, installed runtime and hardware interaction are not asserted by these checks.
