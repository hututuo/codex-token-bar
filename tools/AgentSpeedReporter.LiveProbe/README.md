# Agent Speed Windows live probe

This standalone project links the production Windows DPAPI key store, WebSocket session, report timing builder, and payload whitelist. It is kept outside the shipping helper project and does not add a production command-line mode.

The probe is intended for one isolated Windows account and performs only these actions against the pinned official API: create a new `TokenBar-Win-check-*` test device, send one zero-usage HTTP report with the negotiated cost summary, send zero-usage WebSocket reports with that cost summary and unknown/null source timing, hold the negotiated ping interval open for 22 seconds, reconnect with the same run and the next sequence, then sign a DELETE for only the device it created. It asserts all six negotiated cost fields and the bundled price version. An idle report has zero cost amounts and `knownShare: 1` because there is no live output denominator. It never reads agent transcript data and does not print identity keys, request headers, signatures, or report bodies.

Run `--self-test-fixture` to check the synthetic empty report locally without network access before running the live probe.

Use an isolated working directory and a verified .NET 10 SDK. Preserve the sanitized stdout JSON and build/self-test logs as evidence. If cleanup does not report `deleted`, keep the isolated DPAPI identity directory so the newly created test device can be revoked with its own key.
