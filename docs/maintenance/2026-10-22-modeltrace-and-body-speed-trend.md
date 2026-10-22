# ModelTrace and retained body-speed trends

## Product contract

Both native macOS and Tauri/Windows expose a manual ModelTrace entry beside
body-speed information. The main window opens a centered model-fingerprint
panel; the sidebar opens that panel in the main window rather than embedding
another large panel at the edge.

Default request model is `gpt-6.1-sol`; the light setting is the Codex API value
`low`, verified with this machine's `model/list`. A manual run creates three
independent ephemeral threads in one owned app-server, requests 307/319/331
integers, and overlaps the three generations. Replies are routed by thread
and turn. Invalid replies do not cause retries. A failed/cancelled run cannot
produce a partial three-sample attribution. The transport is independent of
the persistent quota reader; quota refresh does not wait for inference.

User configuration/Home selects the Codex route. Only the model, low reasoning,
ephemeral-thread behavior and no interactive approvals are requested per
thread. The prompt forbids tools; any observed tool/permission request invalidates
the sample and terminates the run. Source/account changes are checked during
the run. Cancellation interrupts known turns and reaps the owned transport.

The pinned 17-model bank does not include GPT-6.1 Sol. This is deliberately a
feature-comparison mode; an Astra-like result does not establish the backend
identity, prove unchanged capability, or guarantee that Luna was excluded.
UI percentages are relative match scores, not identity correctness rates.
All 17 candidates remain in scoring even when only the first five are shown.

Automatic detection defaults off. The interval defaults to 24 hours and can
be selected from 1/6/12/24/48/168 hours. Enabling/changing it schedules the
next run after one interval. A due run uses the same single-flight execution
path as manual detection; missed intervals do not create a catch-up burst.
Changing source/account resets scheduling for the new scope. A restarted
unfinished manual run is marked interrupted and is not resumed. Auto scheduling
requires Bar to be running; it is not an OS wake/scheduled task.

ModelTrace history and its settings live in the feature's own
`modeltrace/modeltrace.sqlite` under each platform's application-support
directory. Runs retain numeric probe samples and available usage metadata;
no user conversation contents or credentials are saved in this feature.

## Body-speed storage

The runtime no longer reads/writes the experimental `observed-speed-*.json`
snapshots. They are left unchanged. Completed-body samples are reconstructed
from recent, uncompressed local rollouts using the existing bounded reader:
up to 64 recent paths, 8 MiB per file and 64 MiB per pass; no compressed
history decoder or historical accounting scan is triggered. Initial coverage
therefore depends on locally available timing/text pairs and bounded tails,
not a claim of complete 30-day backfill.

New stores are separate SQLite files, `body-speed-<source digest>.sqlite`,
under `CodexTokenBar` (native) or `CodexTokenBarTauri` (Tauri). The main exact
token index and cost ledger are not migrated or reset. Independent speed
schema version is 1.

- `speed_samples`: ID, completion time, model, inclusion state, and serialized
  numeric/location metadata. No response text. Low-confidence records remain
  available in detail history. Retention remains the existing 15/30-day setting,
  default 30 days.
- `speed_sample_ids`: compact numeric contribution ledger retained for 30 days.
  An upsert/correction adjusts the previous bucket contribution transactionally.
  Replaying the same IDs cannot add a second contribution.
- `speed_5m`: UTC-aligned five-minute model buckets storing token sum, measured
  duration sum and sample count, retained for 90 days. Raw-detail expiry does
  not subtract already measured historical totals.
- `speed_trend_meta`: schema and retention settings.

Qualified body duration is strictly greater than 400 ms, compared at the
source timestamps' millisecond precision. No minimum token-count requirement.
The existing 2–500 TPS, consistent timing/quantity and network-warning checks
still apply. Thus 399/400 ms are excluded, 401 ms may qualify. This policy is
shared by detail labels, model summaries and trend inclusion on both platforms.

Each point is `sum(outputTokens) / sum(durationSeconds)` for qualified completed
bodies assigned by their completion time. It is not total tokens divided by
300 seconds, and it is not an average of per-sample TPS. Idle time is not added
to the denominator; unmeasured buckets remain gaps. Models are separate lines.
The 24-hour chart reads five-minute points; 7-day and 30-day views group stored
totals to 30 minutes and 2 hours to keep rendering bounded. The underlying
five-minute values stay in SQLite.

Runtime collectors cache numeric history in memory. Persistence compares IDs
and changed metadata and writes only deltas after sample changes. Chart reads
occur on visibility/range/sample changes, with a slow visible-window refresh
on Tauri. No per-frame database query or repeated full-history JSON rewrite.

## Verification

Focused Swift tests cover the shared scorer fixtures (all 17 scores and
probabilities), parser rejection, early parallel completions, cancellation,
SQLite retention/idempotence/corrections and 400-ms boundaries. Rust tests
cover the same bank/parser and interleaved-event cases plus Windows ownership
code at platform build time. Frontend tests cover line segmentation across
missing buckets and existing speed/sidebar behavior.

Real local plaintext replay and SQLite measurements are opt-in through
`CompletedBodySpeedTests.testLocalProductionReaderAudit`; the audit asserts
that valid retained IDs were actually stored, not just that repeated empty
writes are idempotent. Paid live probes are separately opt-in through
`ModelTraceTests.testOptInLiveParallelRun`; ordinary tests never start inference.


## Integration evidence (2026-10-22)

A paid, explicit live run of the default 6.1 Sol / low configuration completed
all three parallel probes in 71.702 seconds. The real run exposed an existing
quota transport policy that discarded notifications without RPC IDs. The raw
transport now has an opt-in notification allowlist; quota-only callers retain
their previous filtering behavior. ModelTrace and auto-resume explicitly retain
the events they consume. A real-pipe regression covers both policies.
Native automatic scheduling is bound at application startup and follows source
changes independently of the main window being open.

The local bounded plaintext audit reconstructed 228 numeric records and 72
recent-day model buckets. SQLite occupied 491,520 bytes; bulk persistence took
about 0.007 s, a recent-day query about 0.00035 s, and an idle bounded-reader pass
about 0.0057 s. These are measurements for this dataset, not a storage forecast
for every user.

Validation: native focused regressions 157 passed, 5 skipped; native live probe
suite 7 passed including the paid run; macOS Rust 154 passed, 1 ignored; frontend
1,214 passed and production build passed. Actual Windows x64 Rust 154 passed,
1 ignored; Windows frontend build and ARM64 library cross-check passed. The
Windows source archive is recorded under runs/20261022-modeltrace-integration;
subsequent native-only notification/startup wiring and CSS meter color changes
are outside that Windows archive. No Windows ARM64 hardware run, feature-build
installation, or public release has been performed.
