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

## Genuine remaining work / priority

1. Windows idle WS state currently retains “registering” after registration while waiting for source activity. Correct the state message, keeping idle waiting and power behavior intact. This is a display bug, not evidence of registration failure.
2. Installed Windows nonzero Token / cost report and HTTP/WS ACK acceptance: NOT_RUN because this machine has no source activity. Use real activity when available; do not invent usage or resend old windows.
3. Actual Mac / Windows sleep and network-switch recovery: NOT_RUN. Requires a coordinated live test so ongoing work is not interrupted.
4. Actual installed main-page rendering FPS with real data: NOT_RUN. Prior visible synthetic-host results measured scroll-loop/CPU/layout durations, not whole-page presented FPS. Keep the two evidence levels separate.
5. WS 100/250ms p95 / browser visibility target: NOT_RUN. Prior isolated ACKs around 414–439ms and website delays are different metrics. Define clock alignment, source observation, construction, ACK and browser-paint timestamps before measuring; a 10-minute / 10k-event benchmark must not be represented as already complete.

Evidence: `2026-10-25-agent-speed-websocket.md` (especially final installed Windows section), `2026-10-25-tps-distribution-build955.md`, `2026-10-25-dashboard-scroll-probe.md`; outer run `runs/20261025-windows-reporting-install/STATUS.md` and `install-receipt.json`, and `runs/20261025-ws-acceptance/install-receipt959.json`.
