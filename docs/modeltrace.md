# Model detection in the Tauri app

Open **模型检测** from the quota sidebar, select a reference-covered GPT model
(default `gpt-5.6-sol`), select **检测轮数** (1–5), and press
**开始检测**. The first round starts immediately; additional rounds are scheduled
at fixed one-hour intervals. Each round collects three valid independent replies,
with at most six attempts. This consumes the selected Codex account's quota.
Round count defaults to 1 on first use and is remembered across panel reopening
and app restarts in the sidebar WebView's local storage (`modeltrace-rounds`).
An absent or invalid value defaults to 1.
Closing the panel leaves the plan running; **停止本次计划** stops it.
The model and round count are locked while a plan is active and show that plan's
actual settings without overwriting the saved preference.

The result lists three candidates by default, expandable to five. The main
dashboard's **Token 活动 → 模型检测** calendar shows matches, differences, mixed
days and unsuccessful rounds. Select one day or two endpoints to inspect
individual rounds across all tested models for the current account and Home.
Dates use the viewing computer's local timezone.
Detection records are collapsed initially. Expanding shows three columns and
up to nine records; **继续加载** reveals nine more (three rows) each time.
Times in the compact list use `MM-DD HH:mm`; the full date is available in the
time tooltip. Each record displays its time, model and status in one row.
The sidebar's detection panel displays the latest round's full attribution result.
The date summary always includes all rounds in the selected range, not just
those currently displayed.

## What the numbers mean

This is ModelTrace's closed-set fingerprint attribution, not independently
verified backend identity. A candidate match means the first-ranked candidate
equals the requested model for that round's three probe replies. It does not
establish which model handled another conversation or every request on a day.

- The bundled bank has 17 candidates. Eight GPT models can be requested; all 17
  candidates, including Claude, participate in scoring.
- The scorer ports `static/fingerprint-core.js` from ModelTrace revision
  `d4131b30243dfa05e70180b5eedde742103f1d73`. It averages three standardized
  fused scores (distribution weight 0.75, ordered-profile weight 0.25), then
  computes `p_i = exp(beta * (score_i - maxScore)) / sum_j exp(beta *
  (score_j - maxScore))`, with the bank's three-response calibration `beta`.
- **归因概率** is `100 * p_i`, relative to the complete reference bank. It is
  neither an empirical correctness rate nor a confidence interval. Showing
  only three or five rows does not renormalize it.
- **分布相似度** is `100 * (1 - sqrt(JS(P, Q_i) / ln(2)))`, where `P` is the
  pooled integer-frequency distribution of the three replies, normalized to sum to one; `Q_i` is
  the reference distribution with the upstream smoothing, and JS is
  Jensen–Shannon divergence. See `scoring.rs` for the exact upstream formulas.
- The calendar's match proportion is matching rounds / (matching + differing
  rounds) for the selected local dates and account/Home across all tested models.
  For example, 2 matches, 1 difference and 3 unsuccessful rounds yields
  `2 / 3 = 66.7%`. Failures, cancellations, interruptions, missing references,
  tied leaders and missed schedules are excluded from that denominator.
- No model outside the bank is offered as a target. In particular this bank
  does not contain `gpt-6.1-sol`. A new bank must ship with matching calibration
  and updated parity fixtures.

## Execution and persistence

The Rust backend starts the locally resolved Codex executable's app-server over
stdio. Each probe requests `openai`, `medium`, a read-only ephemeral thread,
`approvalPolicy: never`, no provider-model fallback, no environments or dynamic
tools, and disabled shell, multi-agent and web-search features. Returned
model/provider/effort/thread metadata must agree. Tool events and server
permission requests invalidate the probe. Only a complete final JSON integer
array is accepted; no prose or truncated array repair is attempted.

Each reply requests a distinct count in 292–332. The parser preserves upstream
eligibility (55%–125% of the requested count, minimum 80 integers; at least 55%
in 1–355), records out-of-range counts, and removes out-of-range values before
fingerprinting. The request timeout is 30 seconds; a generation has a 240-second
deadline. Windows uses an owned Job Object with kill-on-close; Unix uses the
owned process group. Cancellation terminates only that probe transport.

Metadata lives in `CodexTokenBarTauri/modeltrace/modeltrace.sqlite` under the
existing platform application-support directory. Accepted integer samples and
token counts are local JSON files under `modeltrace/samples/`. Authentication
tokens and user conversation contents are not stored in this feature's data.
The scope hashes the canonical and physical Codex Home identities with
`quota::accounts::current_credential(home)?.id()`, the same credential reader
and user/account identity used by the existing quota feature. This includes its
file, keyring and auto-store handling. Token rotation retains the scope; changing
the subscription account or Home changes it. A source/account change stops the
old plan; history queries are scoped to the current source/account.

Cancellation is recorded separately from progress, so a concurrent progress
write cannot erase a stop request. A terminal plan cannot become cancelling.
Stopping between rounds changes the plan without creating a future round record.
Before each attempt, its number is saved; after each response, accepted samples
and the valid-response count are saved before the UI is updated. Recovery uses
the persisted actual start time and progress of an unfinished round.
On restart an unfinished round becomes interrupted; remaining rounds retain
their original schedule. Snapshot reads and new-plan requests retry recovery
when startup could not read credentials or the selected Home later changes.
An active plan is exposed only while the registry owns its worker. A round more
than five minutes overdue is recorded as missed, with no catch-up request.
Restarting does not create a new plan. Run IDs make repeated completion writes
idempotent. The plan and its completed round are committed together.
Transient history-read failures retry after five seconds. Successful reads stop
retrying; changing scope or leaving the view cancels pending retries and ignores
stale responses.

## Validation

`cargo test --manifest-path tauri-app/src-tauri/Cargo.toml --lib modeltrace`
runs the synthetic scorer, parser, protocol, scheduling, persistence and window
authorization tests without model access. The four synthetic scoring fixtures
compare all 17 probabilities, similarities and scores against upstream within
absolute tolerance `1e-9`. Regenerate with:

```
node scripts/modeltrace-fixtures.mjs /path/to/ModelTrace
```

The checkout must be the exact pinned revision. Frontend tests are discovered
by `node scripts/cloud/run-node-tests.mjs tauri-app/src`; the new tests cover
model selection, round-count persistence, start/stop actions, full-bank probability preservation and
calendar denominators. Run `npm run build` inside `tauri-app` for type checks
and the production frontend build.
Recovery tests cover login after startup, Home/account changes, completion/stop
races, persisted sampling progress, and cancellation during the interval between
rounds. Frontend tests cover history retry and stale-response isolation.

The ignored `live_codex_probe` Rust test makes **one real request** and consumes
quota. Opt in by setting `MODELTRACE_TEST_CODEX_HOME` to the intended signed-in
Codex Home and running `cargo test --manifest-path tauri-app/src-tauri/Cargo.toml
live_codex_probe -- --ignored --nocapture --test-threads=1`. It does not start a
multi-round plan. Native sidebar positioning and actual display scaling still
need a manual Windows/macOS smoke test.

Third-party source and license details are in `OPEN_SOURCE_NOTICES.md`.
