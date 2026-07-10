# v0.7.2 Human Review Coverage Ledger

Coverage states: `pending`, `manual-reviewed`, `double-reviewed`, `runtime-validated`, `closed-with-exception`.

| Domain | Swift | Tauri | History | Parity | Runtime/UI | Evidence |
|---|---|---|---|---|---|---|
| Source selection and Codex Home propagation | double-reviewed | double-reviewed | manual-reviewed | double-reviewed | pending | Commander confirmed defects in both lanes. |
| Codex CLI and desktop App discovery | double-reviewed | double-reviewed | manual-reviewed | manual-reviewed | manual-reviewed | Source identity/discovery is aligned; current macOS quota renders, but arbitrary install/runtime matrix remains. |
| Usage JSONL discovery and active rollout paths | double-reviewed | double-reviewed | double-reviewed | manual-reviewed | pending | Core path traced; archived-session scope remains policy-gated. |
| Fork/subagent replay semantics | double-reviewed | double-reviewed | double-reviewed | double-reviewed | closed-with-exception | Two-second grace retained by accepted dense-replay evidence; no naïve change allowed. |
| Session shard and aggregate cache validity | double-reviewed | double-reviewed | double-reviewed | manual-reviewed | pending | Windows replace and date/offset projection defects confirmed. |
| Total/today/request aggregation | double-reviewed | double-reviewed | double-reviewed | double-reviewed | manual-reviewed | Current dashboard values rendered; long lifecycle/date/source runtime matrix remains. |
| Local date and UTC offset behavior | manual-reviewed | double-reviewed | manual-reviewed | double-reviewed | pending | Tauri pending regression confirmed from source; midnight/offset fixture required. |
| Quota app-server lifecycle and parsing | double-reviewed | double-reviewed | manual-reviewed | double-reviewed | manual-reviewed | Both stderr/cancellation seams remain open; Swift transport has zero native coverage. |
| Account plan and quota history identity | double-reviewed | double-reviewed | double-reviewed | double-reviewed | pending | Shared database identity incompatibility confirmed. |
| Reset-credit read and presentation policy | double-reviewed | double-reviewed | manual-reviewed | double-reviewed | pending | No consume/redeem mutation found; live external schema not exercised. |
| Quota cadence, wake, retry, and stale success | double-reviewed | double-reviewed | double-reviewed | double-reviewed | manual-reviewed | Tauri five-minute backend freshness conflict confirmed. |
| Live-rate SQLite and rollout sources | double-reviewed | double-reviewed | double-reviewed | double-reviewed | pending | WAL/replacement/runtime rotation tests remain. |
| Live-rate attribution, dedupe, estimation, and caps | double-reviewed | double-reviewed | double-reviewed | double-reviewed | manual-reviewed | Dual-source duplicate/refcount candidates need deterministic tests; cap policy accepted. |
| Unread/task-completion/mark-all-read | double-reviewed | double-reviewed | double-reviewed | double-reviewed | pending | Partial tail, native authority, pruning, and same-thread completion gaps confirmed. |
| Radar public/full/detail schedule | double-reviewed | double-reviewed | manual-reviewed | double-reviewed | manual-reviewed | Key obfuscation accepted; live network/full-detail schedule not exercised in this audit. |
| Provider scan/backup/sync/verify/rollback | double-reviewed | double-reviewed | double-reviewed | double-reviewed | pending | P1 data-safety repair batch active; only disposable-fixture runtime is permitted. |
| Settings persistence and source switching | double-reviewed | double-reviewed | manual-reviewed | double-reviewed | pending | Tauri atomicity and both-lane source transition defects confirmed. |
| Dashboard/floating/status/tray synchronization | double-reviewed | double-reviewed | manual-reviewed | double-reviewed | manual-reviewed | Current dashboards captured; floating/status/tray lifecycle remains open. |
| Startup, sleep/wake, focus, and timers | manual-reviewed | double-reviewed | manual-reviewed | manual-reviewed | pending | Native long-sleep/wake/date/source lifecycle not completed. |
| Update check, packaging, and release metadata | double-reviewed | double-reviewed | double-reviewed | double-reviewed | manual-reviewed | macOS Tauri unsupported-updater UI observed; real Windows install/relaunch remains. |
| Error taxonomy and pending/stale/failure UI | double-reviewed | double-reviewed | double-reviewed | double-reviewed | manual-reviewed | Current dashboards captured; compact/failure permutations remain. |
| UI layout, interaction, accessibility, and performance | manual-reviewed | manual-reviewed | manual-reviewed | manual-reviewed | manual-reviewed | Screenshots/AX evidence exist; narrow, floating/status, keyboard, hover, VoiceOver, Windows remain. |
| Test quality, source-shape tests, and missing seams | double-reviewed | double-reviewed | manual-reviewed | manual-reviewed | closed-with-exception | Tool outputs triaged manually; coverage gaps documented without treating tools as human coverage. |
| Dead code, duplication, dependencies, and complexity | double-reviewed | double-reviewed | manual-reviewed | manual-reviewed | closed-with-exception | Manual tool triage identifies bounded cleanup candidates; no mass formatter/dead-code purge. |

No row may move from `pending` solely because an automated tool ran.
