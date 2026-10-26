# Speed follow-up status — 2026-10-26

Current status reconciles earlier source-only and blocked snapshots; the historical evidence is preserved.

## Completed before this follow-up

- Scheme ③ (P25–P75 distribution band + median, accepted quota-reset markers) is implemented and was installed on Mac, subsequently build959.
- `client.app=CodexTokenBar` is accepted by the service. Earlier HTTP422 receipts are historical failures, not a current blocker.
- Mac build959 produced real reports and positive leaderboard cost; unknown cost remains unknown, not zero.
- Windows 0.9.7 was installed and completed registration, HTTP runtime and helper start/stop checks. Original data were preserved. Its final baseline is reporting disabled / HTTP. The test machine has no Codex activity; its empty-source errors are expected.
- Windows independent HTTP/WS cost protocol probe passed 19 checks. This does not substitute for nonzero installed-client source activity.

## This follow-up: invitation autoplay

- Native invitation: muted automatic playback while exposed, looping at the end; hide, minimize and occlusion pause it. Return resumes automatic playback. Focus loss alone no longer pauses a still-visible window. Manual pause survives visibility changes. Reduced motion / low power suppress automatic playback; explicit Play remains available.
- Tauri invitation: same loop, document-visibility resume, persistent manual pause, and dynamic reduced-motion behavior. No new network requests, polling or reporting activation.
- PASS: 9 focused Swift tests (including the existing native visibility tests); 4 invitation/media React tests; TypeScript + Vite production build; diff whitespace check.
- Independent native UI preview rebuilt using the production view, visibility probe and playback policy. Its controller remains a stub and cannot register, monitor, report or write production preferences.
- Formal Mac/Windows applications were not replaced or restarted during this follow-up; no release or multi-client merge.

## User decision after this audit

- Idle behavior should follow the pinned Agent Speed scheduler (METRICS 11.5): no activity since startup is quiet; after activity, use negotiated idle heartbeat (last saved discovery: 60 seconds); after 10 minutes idle send leaving and become quiet. Registration success should be shown independently of whether an activity report exists. No need for continuous artificial zero reports; idle deltas never reset server totals.
- User accepts isolated nonzero synthetic regression coverage instead of requiring new real Codex activity on the empty Windows machine. Keep public leaderboard and real accounting free of synthetic increments.
- User explicitly changes the earlier no-fallback requirement: transient WS transport failure must fall back to HTTP. Stored preference stays WS; effective channel is HTTP until manual retry/restart. Preserve device/signing identity, discard unacknowledged windows and baseline a fresh HTTP run, and show fallback status. Do not bypass authentication, TLS/protocol errors, revocation/replacement or Retry-After via fallback.
- Physical sleep/network-switch acceptance is explicitly deferred. Installed main-page performance acceptance is left to the user; previous source fixes and component metrics remain the evidence available.
- Delay attribution is unresolved: 416–439ms was client body construction to ACK, not pure server processing or website rendering. Historical receipts did not retain the ACK processingMs breakdown. The observed website delay around 10–12s is a different downstream metric, and cannot be assigned solely to either side from those receipts. No new public traffic benchmark performed here; attempts to refresh discovery/docs returned HTTP403 from this environment, so saved protocol/spec evidence was used and not represented as a fresh capability confirmation.

## Source changes after the user's decision

- Native controller now falls back from transient socket transport failure to a fresh HTTP run, retaining signing identity and stored WS choice. Explicit retry starts WS again. Intentional idle pause, sleep cancellation, TLS/auth/protocol rejection and Retry-After do not trigger fallback. Known WS send/signing error is retained during cancellation so a signing failure cannot be mistaken for a network break.
- Native and web settings text describes fallback instead of promising WS-only reconnection.
- Swift controller simulation proves the same device signs the new HTTP report, the run changes, historical output 1,000 / cost 90,000 micro-USD is excluded, and only the new 250 output / 1,234 known micro-USD plus one unpriced request enters the report. Selected transport stays WS; explicit retry clears runtime fallback; disabled reporting emits nothing further.
- PASS: Swift 13 XCTest cases plus 15 Swift Testing cases; 3 explicit-public-network tests skipped. React invitation tests: 4 passed; TypeScript / Vite build passed. These are local simulations/regressions, not fresh installed-app or public leaderboard acceptance. Windows backend local self-tests also pass, including nonzero signed HTTP body after fallback, known/unknown cost deltas, status/error preservation, transport/security/rate-limit exclusions, and the long-normal-connection versus sleep-gap distinction. The exact Rust status parsing regression passed and verifies both waiting state and preserved WS preference during HTTP fallback.
- Existing performance source fixes remain in place; this change does not claim new whole-page FPS or physical sleep/network-switch acceptance. Formal applications were not replaced/restarted; no release.

## Latency retest update

A subsequent native zero-usage test now records signing/scheduling, socket-to-ACK and server processing separately. Warm retry: 31/31 ACKs, build-to-ACK p50 441ms / p95 896ms; signing p50 11ms; server-reported processing p50 6ms; Ping p50 410ms. One earlier instrumented attempt missed its third ACK and is retained. Current path RTT does not meet the <=50ms prerequisite; formal source-read-to-commit 100ms acceptance remains unproven. See [the complete retest](2026-10-26-websocket-latency-retest.md).

## Original audit list (historical snapshot, superseded above)

1. At audit time, Windows idle WS state retained “registering” after registration while waiting for source activity (now fixed in source). Correct the state message, keeping idle waiting and power behavior intact. This is a display bug, not evidence of registration failure.
2. Installed Windows nonzero Token / cost report and HTTP/WS ACK acceptance: NOT_RUN because this machine has no source activity. Use real activity when available; do not invent usage or resend old windows.
3. Actual Mac / Windows sleep and network-switch recovery: NOT_RUN. Requires a coordinated live test so ongoing work is not interrupted.
4. Actual installed main-page rendering FPS with real data: NOT_RUN. Prior visible synthetic-host results measured scroll-loop/CPU/layout durations, not whole-page presented FPS. Keep the two evidence levels separate.
5. WS 100/250ms p95 / browser visibility target: NOT_RUN. Prior isolated ACKs around 414–439ms and website delays are different metrics. Define clock alignment, source observation, construction, ACK and browser-paint timestamps before measuring; a 10-minute / 10k-event benchmark must not be represented as already complete.

Evidence: `2026-10-25-agent-speed-websocket.md` (especially final installed Windows section), `2026-10-25-tps-distribution-build955.md`, `2026-10-25-dashboard-scroll-probe.md`; outer run `runs/20261025-windows-reporting-install/STATUS.md` and `install-receipt.json`, and `runs/20261025-ws-acceptance/install-receipt959.json`.
