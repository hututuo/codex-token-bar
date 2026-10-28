# WebSocket latency retest — 2026-10-26 13:18–13:24 Asia/Shanghai

## What registration means

A successful device registration is an accepted response from the speed service's POST /v1/devices, with the expected device ID and username. It establishes a public-key/device/nickname identity on that server. It is independent of WebSocket readiness and the later acknowledgement of a statistics report. The diagnostic used separate new identities and zero usage; production identity and consent were untouched.

## Original target

The saved 2026-10-24/25 REPORTING-WEBSOCKET section 12 specifies p95 <=100ms from the earliest local source read to server atomic commit/read visibility, and p95 <=250ms to browser paint. The baseline assumes an established TLS/WebSocket session, measured client/API RTT p95 <=50ms, stable network, a visible dashboard and at least 10 minutes / 10,000 events. It is not a promise of 100ms round-trip on every network. Source-read/merge time is outside this report-construction probe; cross-machine clocks were not calibrated, so the ACK interval is not a measured one-way commit time.

## Measurements

All requests used the product's native URLSession WebSocket, P-256 device signing, exact signed inner JSON, ready validation and run/sequence/hash-matched ACK ledger. No fake usage was submitted; body delta and live amounts were zero. The route check resolved the API to 104.26.15.186 and routed through utun1024, gateway 198.18.0.1. Network configuration was read, not changed.

1. Existing lifecycle probe: 3/3 ACKs, 515 / 425 / 425ms, including client suspension/reconnection and a heartbeat interval. Separate test device registration removed by the existing probe (its old receipt does not record cleanup status).
2. First instrumented attempt: 3 reports attempted, 2 ACKs (665 and 1282ms), then missing ACK / reconnect. Each acknowledged report spent 10ms in signing/scheduling, 0ms packing, and the server reported 8ms / 4ms processing. One Ping round-trip was 474ms. Test failed the requested sample-count check. Cleanup returned HTTP200. This failure is retained; it is not excluded from overall reliability observations.
3. Retry: 31/31 ACKs, zero dropped/rejected/timed-out/unknown windows. The first report is retained in raw samples; the next 30 make the warm summary below. 11 explicit Ping probes were interleaved. Cleanup returned HTTP200.

| Warm sample metric | Count | p50 | p95 | max |
|---|---:|---:|---:|---:|
| Signing and scheduling | 30 | 11ms | 14ms | 19ms |
| Envelope packing | 30 | 0ms | 1ms | 1ms |
| Send to valid ACK | 30 | 430ms | 883ms | 951ms |
| Server-reported processing | 30 | 6ms | 9ms | 13ms |
| Construction/reservation to valid ACK | 30 | 441ms | 896ms | 956ms |
| WebSocket Ping round trip | 11 | 410ms | 1255ms | 1255ms |

Percentiles use nearest rank. The retry's p95 is conditional on that run and is not the formal all-events target: an earlier run had a missing ACK. Neither source observation latency nor website paint was measured. Server processing comes from the server's ACK field; it does not prove the absence of any edge/ingress/output queue outside that field.

## Interpretation

The approximately 400ms baseline is dominated by the path after socket handoff. The 410ms Ping median closely matches it, while local signing and server-reported application processing are small. Evidence points to network/proxy/edge round-trip latency and jitter rather than local token collection or P-256 signing holding each packet for 400ms. The test does not identify a specific VPN node, carrier link or server-edge queue; do not call the whole remainder pure WAN latency or solely the backend's fault. The current measured RTT fails the <=50ms benchmark prerequisite, and this probe cannot certify the 100ms source-read-to-commit target.

## Code and verification

AgentSpeedWebSocket retains only its most recent valid ACK timing breakdown (bounded, no contents/credentials). Ping measurement is explicit-only and not called by ordinary reporting. A gated test writes timing-only receipts using an isolated zero-usage registration. ACK matching/timing unit test passed. The 31-report explicit native live probe passed; the first failed attempt is preserved beside it. No formal app replacement/restart, public release or multi-client merge.

Raw receipts: [preflight](assets/20261026-ws-latency/tokenbar-latency-preflight-20261026.json), [first instrumented attempt](assets/20261026-ws-latency/mac-breakdown.json), [retry](assets/20261026-ws-latency/mac-breakdown-retry.json). Full logs remain under runs/20261026-ws-latency/.
