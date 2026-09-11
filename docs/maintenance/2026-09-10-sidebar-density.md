# Sidebar readability, density, and cycle summary

## Changes

- Tauri Agent count: a descendant `span` selector meant for the role caption applied an 11px line height to the animated digits. Limit that rule to the caption and give the numeral viewport and digit spans a 26px line height. Keep the 49px ring and existing flip animation.
- Crowd radar: the client still polls every 300 seconds; native successful-response sharing lasts 20 seconds. A live HTTP 200 response returned Age=34, max-age=30, stale-while-revalidate=60, x-codex-cache=HIT. The former `旧` label therefore indicated source cache freshness, not a stopped client. Rename to `缓存`, explain its origin, and include native network observation time in the radar details. Do not fake freshness or increase request frequency.
- Calendar: collapse to a horizontal, truncatable summary alongside the disclosure button; expanding reveals the full-width calendar. Swift combines the date, scheduled reset, and usage breakdown into one summary rather than stacking each label.
- Detail overview: six metrics in two rows, today input/cache/output composition with cache counted once, cache hit ratio, known API-equivalent cost, reset-credit/pace status, and all nonzero model rows with both Token share and API-equivalent cost. Reuse existing floating-window model grouping and pricing. Running-task metadata uses a compact horizontal layout on Tauri.

## Verification

- Frontend sidebar and StatsStrip suite: 58 PASS; additional density regression: 1 PASS.
- Numeral CSS regression: PASS, 26px numeral viewport and line height.
- Browser render inspection: production components and CSS with synthetic data; count 12 fully rendered, five model rows accessible, composition and metrics inspected at 600px detail height. This is not native animation/FPS acceptance.
- Initial Swift sidebar suite: 29 PASS. Final build, replacement, and fresh launch evidence appended below after completion.
- Evidence directory: `runs/20260910-sidebar-density/`.

## Live follow-up

Tauri preview first density revision launched as PID 6969. Native dashboard screenshot confirms a one-line cycle selector/date and horizontally arranged model cards. A separate official Radar initial 18s request timeout was visible; a fresh direct request to current.json returned HTTP 200 in 1.318s. This is distinct from the crowd cache header evidence. Dashboard crowd labels now distinguish source cache from a failed local refresh as well. Radar component tests: 7 PASS.

Final Swift source sidebar tests: 29 PASS. The first release attempt was rejected by SwiftPM because the final layout edits occurred during compilation; that candidate was not installed. A clean final release rebuild is running after source edits finished.

## Completion

Final Swift and Tauri release packages built and passed deep signature verification. Both installed preview executable hashes match their respective build outputs. Swift PID 11454, Tauri PID 10682; Tauri startup confirms rail, detail, dashboard summary, and analytics ready. Old preview bundles retained.

Swift SHA256: 4608a6a5752821f47141100289a0603b1c4feeaa020f6162b7380bc7fb4449b3
Tauri SHA256: 0d01ed0853df99539fae0d02978a4b51968fd9e085d355d87d6c64f721ab09a5

Total relevant tests: frontend 58 + density 1 + Radar component 7 + Swift sidebar 29, all PASS. Full native interaction/animation acceptance for both apps and Windows runtime remain NOT_RUN. No new index migration, source scan, or refresh timer was introduced for this UI task.
