# Sidebar quota hints, reset cards, radar tabs and network recovery

- Move quota pacing hint beside the quota percentage section, away from Token composition.
- Show reset-credit count in the compact expanded rail; quota details list each card's issue, expiry and redemption times using existing API data.
- Add radar ranking tabs: public official `latest + comparisons`, versus existing crowd realtime ranking. Ranking functions are reused. This is the set of models returned by the public summary, not a claim that every upstream model is present.
- Remove the compact crowd server-cache badge. A successful response can carry upstream cache provenance; this alone does not mean this app stopped polling. Preserve source timestamps and actual request-failure warnings.
- Swift: active radar store observes unavailable-to-available network paths, triggers refresh, and retries failed official/crowd/feed refreshes after 30/60/120 seconds. Stop cancels pending recovery and network observation. Healthy cadence remains 300 seconds. Shared refresh can fetch healthy sources again when one source failed, bounded to three extra attempts.
- Tauri: floating/sidebar and dashboard radar owners listen for `online`, have bounded official-summary recovery, and allow crowd recovery even when a previous snapshot exists. Online explicitly bypasses the crowd client's 10-second failed-promise cooldown; active in-flight reads remain shared. Cleanup removes handlers/timers. No index or JSONL scan changes.
- Swift max/ultra official ranking tie-break order aligned with Tauri.

Validation: 82 frontend tests and 70 Swift tests pass. Covers mounted ranking-tab selection, reset-card dates and compact count, quota hint placement, online refresh and handler removal, existing reader/ranking contracts. TypeScript/Vite build passes. Browser production-component fixtures cover the compact 2-quota-ring case with three recommendations, countdown and card count without clipping. Swift/native pointer and visual acceptance remains NOT_RUN because macOS is locked. A real outage/recovery was not induced on the user's network.

Release build and preview replacement logs: `runs/20260911-sidebar-cards/`. No public release or index migration performed.

Both release bundles built, signed verification passed, preview bundles replaced and restarted. Installed executable hashes match the just-built bundles. Exact PID/path and SHA-256 records are in the run directory. Native visual interaction remains unverified because the Mac is locked.
