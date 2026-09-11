# Sidebar trend and seven-day quota sampling — 2026-09-10

## Scope

Both sidebar quota detail views now include a compact last-24-hour Token and remaining-quota chart. Token is blue with its own amplitude scale; five-hour quota is green and seven-day quota purple on the 0–100% scale. Missing quota samples break the line and absent five-hour data hides that series. Click/drag (Swift) or click (Tauri) selects a sample and its values. The chart uses linear paths to avoid inventing overshoot. It shows 288 existing five-minute samples; it does not scan JSONL or build an index.

Tauri adds a source-bound, read-only `read_sidebar_trend` command that projects only `(timestamp, tokens)` from the existing same-Home last-good dashboard cache. Only an open detail surface polls it, at five-minute intervals, with overlapping requests suppressed. It joins quota history already fetched by the sidebar. Swift observes the existing usage and quota stores and limits the chart arrays to 288 samples.

## Seven-day trough defect

The seven-day view previously used hourly series. Quota history chooses the latest observation at the end of each hour, so an intra-hour low of 7%, followed by 17%, was absent before smoothing began. Both renderers now use the retained five-minute series whenever it covers the hourly history; the viewport remains seven days. Token, calls, cache/model attribution, point selection and quota comparison all use that same five-minute interval. Existing virtualization remains in use. Thirty-day aggregation is unchanged.

A short legacy fine cache does not replace a longer hourly history. It continues using hourly data until the normal refresh supplies coverage. This is a rendering/cache selection change, with no schema or release-index migration change.

## Verification

- PASS: 56 TypeScript/React tests, including actual mounted mini-chart click selection, null gaps, quota ratio units, seven-day 7% trough preservation, unchanged Token totals, and short-cache fallback.
- PASS: 115 Swift sidebar/chart/quota-estimator tests, including equivalent 7% trough regression and existing hourly-cache coverage tests.
- PASS: TypeScript/Vite build and Rust cargo check (existing warnings).
- PASS: Browser visual inspection of production detail components with synthetic 288-point chart; compact chart fits the detail card, other content remains scrollable.
- Native visual interaction verification: blocked by macOS lock screen during this turn. Browser rendering and tests do not establish native visual acceptance or frame rate.
- Release builds and preview replacement: recorded in `runs/20260910-sidebar-trend/` after completion.

## Installed preview result

- PASS: both macOS release bundles built, code signatures verified, and preview apps replaced/restarted. Built and installed executable SHA-256 match; JSON evidence and exact new processes are in the run directory.
- Tauri: `d384ec185fbb0f6d5ad61f0847682b67da30f1061bf43cce0248270fab3b3367`.
- Swift: `753192f6548a87ba09c30b5ecf3502f87e987d78b840eeb4aca32d475e3eb502`.
- Tauri startup log confirms main dashboard and both sidebar React surfaces initialized.
- Full 30-day fine-series fixture: 8,640 retained samples, seven-day viewport selects 2,016 samples with matching Token total and 7% minimum. Preparation measured 2.6ms in one local Node run; this is not a frame-rate measurement.
- Native click/hover visual acceptance remains NOT_RUN due to lock screen. No release published.
