# RadarBench public-response fixtures

These JSON files are historical public-response samples from AICleverYet commit `52622ffd3b35cbeb92a0c6d54d92f28d06c13773`, whose documentation records a capture on 2026-10-11. The bytes are preserved from the source fixtures. They are not customer incident data and do not verify the current live API.

- [Binding source](https://github.com/lcp2021211/AICleverYet/blob/52622ffd3b35cbeb92a0c6d54d92f28d06c13773/Tests/RadarCoreTests/Fixtures/bench-binding.json)
- [Summary source](https://github.com/lcp2021211/AICleverYet/blob/52622ffd3b35cbeb92a0c6d54d92f28d06c13773/Tests/RadarCoreTests/Fixtures/bench-summary.json)

The binding metadata and its 64 task members were cross-checked against the official DRadar final64 contract at commit `374726ed89a8af534a2c78a551d1afb8735c66e2`. The public website routes used by the captured client are `/data/radar-bench-binding.json` and `/api/radar-bench-score?model=…&effort=…&view=summary&selection=user-selected-v1` on `https://codexradar.com`.

The summary uses `radar-bench-public-summary-v5-150-daily-graded-count`, `radar-bench-v2-150`, and a score maximum of 150. Its score is already scaled; valid zero differs from missing score. Coverage counts tasks, while `graded_runs_count` counts graded runs. API-equivalent benchmark cost is not a Token Bar user's personal bill.

The earlier raw 100-point v1 summary and the candidate DRadar v2 API are separate contracts. These fixtures do not authorize guessing their units or treating them as the current website API.
