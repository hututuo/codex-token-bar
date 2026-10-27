# Agent Speed — Measurement Specification

This document is the single source of truth for how Agent Speed reads agent transcripts and turns them into
tokens-per-second. The macOS (Swift) and Windows (C#) implementations MUST follow it exactly and MUST pass the
shared fixtures in `spec/fixtures/`.

## 1. Vocabulary

| Term | Meaning |
| --- | --- |
| Source | `codex`, `claudeCode`, `claudeDesktop`, `deepseek` (display name **DSH**, DeepSeek Harness), `opencode`, `gemini` (Gemini CLI), `omp` (oh-my-pi), `antigravity` (Google Antigravity), `workbuddy` (Tencent WorkBuddy, China edition), `workbuddyAi` (WorkBuddy AI, international edition), `zcode` (ZCode), `kimi` (Kimi Code CLI), `grokBuild` (Grok Build). This is the append-only *source order*. |
| Agent | One transcript file. Agent id = absolute file path. Sub-agents have their own files and are separate agents. (OpenCode: one per session row, 4.5; Antigravity: one per conversation database, 4.8.) |
| Response | One model API call that produced a usage record. |
| Phase | `generating` (a request is in flight), `tools` (model finished, waiting for tool results), `idle` |

Parsers normally emit one record per response. A native Grok model batch is one record with `requestCount` underlying
responses (4.12); the speed engine still processes its normalized tokens and duration with the same equations.

## 2. Locations

| Source | Root | Override |
| --- | --- | --- |
| Codex | `$CODEX_HOME/sessions`, else `~/.codex/sessions` | user setting |
| Claude Code + Claude Desktop | `$CLAUDE_CONFIG_DIR/projects`, else `~/.claude/projects` | user setting |
| DeepSeek Harness (`dsh`, desktop app and CLI) | `$DSH_HOME/sessions`, else `~/.dsh/sessions` | user setting |
| OpenCode (CLI and desktop app) | `$XDG_DATA_HOME/opencode/opencode.db`, else `~/.local/share/opencode/opencode.db` (same form on Windows under `%USERPROFILE%`) | user setting (folder that contains `opencode.db`) |
| Gemini CLI (interactive, `-p`, ACP/IDE sessions) | `<home>/.gemini/tmp`; on macOS also `<home>/.cache/.gemini/tmp` (seatbelt sandbox, v0.63+). `<home>` = `$GEMINI_CLI_HOME`, else `~` | user setting (one `tmp` folder; replaces both defaults) |
| omp (oh-my-pi: TUI, `-p`, RPC, ACP) | The default root plus one root per named profile (4.7). Default: `$PI_CODING_AGENT_DIR/sessions`, else on macOS `$XDG_DATA_HOME/omp/sessions` when `$XDG_DATA_HOME/omp` exists, else `~/<cfg>/agent/sessions`, where `<cfg>` = `$PI_CONFIG_DIR`, else `.omp`. Profiles: `~/<cfg>/profiles/<name>/agent/sessions` for every folder `<name>` | user setting (one `sessions` folder; replaces every automatic root) |
| Antigravity (CLI `agy`, desktop app, IDE, IDE extensions) | three store folders: `~/.gemini/antigravity-cli`, `~/.gemini/antigravity`, `~/.gemini/antigravity-ide` (each contains `conversations`) | user setting (one store folder, or its `conversations` folder; replaces all three) |
| WorkBuddy (desktop app `WorkBuddy`, China edition) | `~/.workbuddy/projects` (4.9) | user setting (the data folder or its `projects` folder) |
| WorkBuddy AI (desktop app `WorkBuddy AI`, international edition) | `~/.workbuddy-ai/projects` (4.9) | user setting (the data folder or its `projects` folder) |
| ZCode | `~/.zcode/cli/db/db.sqlite`; `$ZCODE_DATA_BASE_DIR` replaces the home base, with `.zcode/cli/db` underneath | user setting (data directory, database folder, or `db.sqlite`) |
| Kimi Code CLI (TypeScript v2) | `$KIMI_CODE_HOME/sessions`, else `~/.kimi-code/sessions` | user setting (data directory or its `sessions` folder) |
| Grok Build | `$GROK_HOME/sessions`, else `~/.grok/sessions` | user setting (data directory or its `sessions` folder) |

`~` is `HOME` on macOS and `%USERPROFILE%` on Windows. Claude Code and Claude Desktop share one root; each file is
assigned to a source by its `entrypoint` field (section 4.1). Ordinary Claude Desktop chat conversations are not stored
locally and are out of scope.

Discovery: recursive enumeration of `*.jsonl` (Codex also `*.jsonl.zst`, 5.3; DeepSeek: `session.v<N>.jsonl.zstd` or `session.v<N>.jsonl`; Gemini CLI:
fixed depths, see 4.6; omp: see 4.7; Antigravity: conversation databases, see 4.8; WorkBuddy: fixed depths, see 4.9),
maximum depth 6, never follow symlinks, at most 20 000 files per root.
A source is *detected* when its root (Antigravity: any store; WorkBuddy: the data folder) exists or it has data today;
what an undetected source shows is DESIGN 2b (unavailable sources), 4 and 5.
The app never writes inside these folders.
For ZCode, Kimi Code CLI and Grok Build, the source's session count includes today's main sessions only;
subagents remain visible in the agent tree and ordinary forks remain separate sessions, as with WorkBuddy.

## 3. Common rules

### 3.1 Timestamps
RFC 3339 / ISO 8601 with optional fractional seconds and `Z` or offset. Convert to Unix milliseconds (Int64).
Lines without a parseable timestamp are ignored except where stated.

A timestamp string is exactly `YYYY-MM-DD`, then `T`, `t` or a space, then `hh:mm:ss`, then optionally `.` and one or
more digits, then `Z`, `z`, `±hh:mm` or `±hhmm`, with ASCII digits only, nothing before or after it (no whitespace) and
at most 64 characters (after JSON unescaping). Year 0000–9999 of the proleptic Gregorian calendar (0000 is a leap
year), month 01–12, a day that exists in that month, hour 00–23, minute and second 00–59 (no leap second), offset hours
00–23 and offset minutes 00–59. Anything else is not a timestamp (`2026-10-20T10:00:00` without a zone, `+08` without
minutes, `24:00:00`). Digits after the third fraction digit are dropped. The value is computed arithmetically —
`(days since 1970-01-01 × 86 400 + seconds of the day − offset) × 1000 + milliseconds` — so every valid string has a
value, also before 1970 (negative) and past 9999-12-31 UTC (`9999-12-31T23:59:59-23:59`). Fixture cases: the
WorkBuddy session `orbit-timestamps` (`spec/tools/workbuddy_fixtures.py`; WorkBuddy accepts string timestamps, and
every source shares this parser).

### 3.2 Normalized token usage
Every response carries:

| Field | Codex (`usage` / `last_token_usage`) | Claude (`message.usage`) |
| --- | --- | --- |
| `input` (total input) | `input_tokens` (already includes cached) | `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` |
| `cachedInput` | `cached_input_tokens` | `cache_read_input_tokens` |
| `cacheWriteInput` | `cache_write_input_tokens` (absent → 0) | `cache_creation_input_tokens` |
| `cacheWrite1hInput` (the part of `cacheWriteInput` written with a 1-hour lifetime) | 0 | `cache_creation.ephemeral_1h_input_tokens` (absent → 0), at most `cacheWriteInput` |
| `output` (includes reasoning) | `output_tokens` | `output_tokens` |
| `reasoning` | `reasoning_output_tokens` | `output_tokens_details.thinking_tokens` (absent → 0) |

Missing numeric fields are 0. Negative values are clamped to 0. `total = input + output`. Every other source has
`cacheWrite1hInput = 0` (their logs do not separate cache lifetimes; Claude Code writes about a third of its cache
with the 1-hour lifetime, which costs 2× input instead of 1.25×). On a repeated Claude line the field merges with
`max` like the others (4.1).

Token values and the cap: every token value read from a log is its number truncated toward zero and clamped to
0 … 10^12 (numbers: 3.6). So `12.9` counts 12; `-7`, `-1e999` and `0.5` count 0; `1e20`, `1e999` and an integer
literal too long for 64 bits count 10^12; any other value (string, boolean, null, object, array) counts 0. A
normalized field that adds values (the `input` of Claude, DeepSeek Harness, OpenCode, Gemini CLI and omp; the `output`
of OpenCode and Gemini CLI; the sums of WorkBuddy, 4.9) saturates at 10^12 too, so no field ever exceeds it. No real
response comes near; the cap keeps every total far from 64-bit overflow, and cost classes are clamped further (9.3).
Antigravity has its own, lower limit (4.8). Fixture cases: the WorkBuddy session `orbit-edge`
(`spec/tools/workbuddy_fixtures.py`).

Every response also carries `provider` (string or null): the API provider the agent says it used, only for pricing
(9.2). Codex: `payload.model_provider` of the file's first `session_meta` (`openai`, or the user's own key such as
`custom`). DeepSeek Harness: `data.message.source.provider`, else the latest `request/header` `config.provider`.
OpenCode: `data.model.providerID`. omp: `message.provider` (assistant) or the entry's `provider` (`model_usage`).
WorkBuddy: `custom` for a model of the user's own provider (`custom:` / `custom-local:` ids, 4.9). Every other
source: null. Empty strings count as null.

Every response also carries `fast` (boolean): the request ran in a provider's fast mode, which has its own prices
(9.3). Claude: `message.usage.speed == "fast"` on any of the message's lines (merged with `or`). Every other source:
false (Codex records only the user's speed setting, not the tier a request was billed at).

### 3.3 Response timing
- `endMs` = timestamp of the usage record (Claude: the latest line of that message).
- `startMs` = when the request was sent, tracked per file as `pendingStartMs` (rules per source below). May be null.
- Valid interval: `startMs != null`, `endMs >= startMs`, `endMs - startMs <= 15 min`. Otherwise the response counts in
  totals but never in speed.
- `final`: whether the usage is the final usage. Codex responses are always final. A Claude response is final once any
  of its lines has a non-null `stop_reason`. Recent Claude Desktop versions often write only the streaming snapshot of
  sub-agent messages (output ≈ 8 tokens) and never the final usage; such responses are *unfinalized*.
- A response is *measured* when it is final and has a valid interval, and *unmeasured* when it is unfinalized and has a
  valid interval. Unmeasured responses never contribute measured speed; their time is estimated instead (6.3).
- Minimum duration: if `endMs - startMs < 500 ms`, use `startMs' = endMs - 500`.
- `speed = output / ((endMs - startMs') / 1000)` — this is end-to-end output speed and includes time to first token.

### 3.4 Deduplication
A global, bounded (65 536 entries, FIFO eviction) set of response keys shared by all files of all sources.
A key first seen in file A and later seen in file B is ignored in B (forks and resumes copy history). Claude: repeated
lines of the same key in the same file are merged (4.1, 4.4). Codex: every repeat of a key is skipped (4.2).

### 3.5 Copied history
For Codex, once `session_meta` has been read, any later line whose timestamp is earlier than `fileCreatedMs - 2000`
is copied history (forks and sub-agents copy their parent's records): ignore it completely (no totals, no speed, no
state change). For Claude, copied history is removed by deduplication (3.4).

### 3.6 Numbers
JSON numbers mean what Python's `json` reads: an integer literal is exact (any length), every other literal is the
nearest double (`1e999` is infinite). `NaN`, `Infinity` and `-Infinity` are not JSON: a line that contains them anywhere
is malformed (section 4).

- *Finite*: a number whose nearest double is finite. `1e999`, `-1e999` and integer literals beyond the double range
  (about 1.8 × 10^308) are not. A rule that asks for a finite number (the numeric timestamps and durations of 4.7 and
  4.9, the first-value rule of 4.9 Tokens) treats any other number like a missing value.
- *Truncated* (to an integer): toward zero, then saturated to the signed 64-bit range, so a millisecond value of
  `1e19` gives 2^63 − 1. A sum of milliseconds (omp `startMs + duration`) saturates too.
- Token values are truncated and capped as in 3.2.

## 4. Parsers

Each parser is a per-file state machine fed complete lines in order. It produces:
- response upserts (`key`, `source`, `agentId`, `model`, `startMs`, `endMs`, normalized tokens)
- phase updates (`phase`, `phaseSinceMs`, `inFlightStartMs`; `inFlightStartMs` is null whenever the phase is not
  `generating`)
- metadata (`project` = last path component of `cwd`, `cwdPath` = the full working directory, used only by 10.6,
  `model`, `isSubagent`)
- `lastLineMs` = the latest timestamp seen in the file

Lines that are not valid JSON objects are skipped and counted as malformed. Lines longer than 32 MiB are skipped.

### 4.1 Claude (Claude Code and Claude Desktop)

Source: the first line that has `entrypoint` decides: a value starting with `claude-desktop` (`claude-desktop`,
`claude-desktop-3p` on Windows) → `claudeDesktop`, anything else →
`claudeCode`. Before that, the file is `claudeCode`.

`isSubagent` = path contains a `subagents` directory component, or any line has `"isSidechain": true`.
`project` = basename of the latest `cwd`.

State: `pendingStartMs` (nullable), `preciseStart` (bool), `phase`.

| Line | Action |
| --- | --- |
| `type == "api-request"` | `pendingStartMs = ts`, `preciseStart = true`, phase `generating` (`inFlightStartMs = ts`) |
| `type == "user"`, content contains a text block (or string content) starting with `[Request interrupted by user` | phase `idle`, `pendingStartMs = null`, `preciseStart = false` |
| other `type == "user"` | if not `preciseStart`: `pendingStartMs = ts`; phase `generating` (`inFlightStartMs = pendingStartMs`) |
| `type == "assistant"` | see below |
| anything else | only updates `lastLineMs` |

Assistant line:
1. `key = message.id`, else `requestId`, else `uuid`. Skip the line if `message.model == "<synthetic>"`.
2. If `key` was first seen in another file: ignore the line entirely.
3. If `key` is new: create the response with `startMs = pendingStartMs` (may be null), then
   `pendingStartMs = null`, `preciseStart = false`.
4. Merge: `endMs = max(endMs, ts)`, every token field = `max(previous, new)`, `model = message.model`.
5. `final = final || stop_reason != null`.
6. Phase from `message.stop_reason`: `"tool_use"` → `tools`; `null`/missing → `tools` when the line's
   `message.content` contains a block of type `tool_use`, otherwise `generating`; `"pause_turn"` → `generating`
   (`inFlightStartMs` = the response start, or `ts` if unknown); any other value → `idle`.

### 4.2 Codex

Every line is an envelope `{ "timestamp", "type", "payload" }`.

State: `fileCreatedMs`, `myAgentPath`, `pendingStartMs`, `streaming` (bool), `sawModernUsage` (bool),
`previousLegacyTotals` (nullable), `phase`.

| Line | Action |
| --- | --- |
| first `session_meta` of the file | `fileCreatedMs = ts`; `project` from `payload.cwd`; `myAgentPath = payload.agent_path ?? "/root"`; `isSubagent = payload.thread_source == "subagent"` or `payload.source.subagent` exists; `threadId = payload.id`. Later `session_meta` lines (sub-agents copy their parent's) are ignored entirely. |
| `turn_context` | `model = payload.model`; `project` from `payload.cwd` when present |
| input (see below) | if not `streaming`: `pendingStartMs = ts`; phase `generating` (`inFlightStartMs = pendingStartMs`) |
| mailbox input (see below) | if not `streaming`: `pendingStartMs = ts`; the phase does not change |
| output (see below) | `streaming = true`; phase `generating` (`inFlightStartMs = pendingStartMs ?? ts`) |
| `token_usage_record` | modern usage (below) |
| `event_msg` + `payload.type == "token_count"` | if `sawModernUsage` and `streaming`: the response ended without a usage record — `streaming = false`, `pendingStartMs = ts`, phase `tools`. Otherwise legacy usage (below). |
| `event_msg` + `payload.type` in `task_complete`, `turn_aborted` | phase `idle`, `pendingStartMs = null`, `streaming = false` |

Input lines:
- `event_msg` with `payload.type` in `task_started`, `user_message`
- `response_item` with `payload.type` ending in `_output`
- `response_item` with `payload.type == "message"` and `payload.role` in `user`, `developer`, `system`

Mailbox input (a message from another agent; an orchestrator may receive it while it is blocked, so it marks a
possible request start but is not proof that a request is in flight):
- `response_item` with `payload.type == "agent_message"` and `payload.recipient == myAgentPath`

Output lines:
- `response_item` with `payload.type == "reasoning"`, or ending in `_call`, or `message` with role `assistant`

Modern usage (`token_usage_record`):
1. Skip if copied history (3.5).
2. `sawModernUsage = true`. `key = payload.response_id`, else `"codex:" + threadId + ":" + ts`.
   (`threadId` = `payload.thread_id` ?? `session_meta.payload.id` ?? file path.) Skip if already seen anywhere.
3. Tokens from `payload.usage`. Ignore `turn_token_usage` and `thread_token_usage`.
4. Emit the response with `startMs = pendingStartMs`, `endMs = ts`.
5. `pendingStartMs = ts`, `streaming = false`, phase `tools`.

Legacy usage (`event_msg` / `token_count`):
1. Ignore when `sawModernUsage` is true, when `payload.info` is null, or when copied history (3.5).
2. `total = info.total_token_usage`, `last = info.last_token_usage`.
3. If `previousLegacyTotals` is null → tokens = `last` (fallback `total`).
   Else `delta = total - previous` per field. If `delta.total_tokens == 0` → duplicate event, ignore (do not change
   any state). If any delta field is negative → tokens = `last`. Otherwise tokens = `delta`.
4. `previousLegacyTotals = total`.
5. `key = "codex-legacy:" + threadId + ":" + total.total_tokens`. Skip if already seen.
6. Emit with `startMs = pendingStartMs`, `endMs = ts`. Then `pendingStartMs = ts`, `streaming = false`, phase `tools`.

### 4.3 DeepSeek Harness (dsh)

Files are a sequence of independent zstd frames (section 5.1); the decoded stream is JSONL. Every event line has
`type`, `seq` (number) and `time` (Unix milliseconds, a number). Wrappers are unwrapped first: a line
`{"type":"event","event":{...}}` is processed as its inner event; a line `{"type":"snapshot","header":{...},
"records":[...]}` is processed as its header followed by each record (itself possibly an `event` wrapper) in order.

State: `sessionId`, `createdMs`, `parentSession`, `model`, `pendingStartMs`, `phase`.

| Event | Action |
| --- | --- |
| first header (`type == "session"`, or a snapshot `header`) | `sessionId = id`; `createdMs = createdAt`; `project` from `cwd`; `isSubagent = origin == "subagent"` or `delegationDepth > 0` or `parentSession` is a non-empty string; `parentSession = parentSession`. Later headers are ignored. |
| any event whose `time` is earlier than `createdMs - 2000` | fork-inherited history: ignore completely |
| `request/header` | `model = data.header.config.model` when present |
| `step/start` | `pendingStartMs = time`; phase `generating` (`inFlightStartMs = time`) |
| `assistant/message` | response (below) |
| `turn/end` | phase `idle`, `pendingStartMs = null` |
| anything else | only updates `lastLineMs` |

`assistant/message`:
1. `key = data.message.id`, else `"dsh:" + sessionId + ":" + seq`. Skip the event entirely if the key was seen anywhere.
2. When `data.usage` is an object, emit a response with `startMs = pendingStartMs`, `endMs = time`, `final = true`,
   `model = data.message.source.model ?? model`, and tokens `input = inputTokens + cacheReadTokens + cacheWriteTokens`,
   `cachedInput = cacheReadTokens`, `cacheWriteInput = cacheWriteTokens`, `output = outputTokens`, `reasoning = 0`
   (dsh does not report reasoning separately; it is included in `outputTokens`).
3. `pendingStartMs = null`; phase `tools` when `data.message.content` has a block of type `tool-call`, else `idle`.

`lastLineMs` is the latest `time` seen (excluding ignored inherited events). Verified against dsh's own session
statistics: the sum of `step/start → assistant/message` intervals equals dsh's `llmMs`, and the token sums equal its
`tokenUsage` totals.

### 4.4 Response upserts
A response is identified by its key. The first emission is a *completion* (used for live events, 6.4). Later
emissions with the same key in the same file are *updates*: the engine replaces the stored response.

### 4.5 OpenCode

OpenCode (2.x) stores everything in one SQLite database in WAL mode. It is opened read-only (`mode=ro`, never
written), with a busy timeout of 2 s, and every read is a short transaction so OpenCode's checkpoints are never
blocked. When OpenCode is not running it closes the database cleanly and deletes `opencode.db-wal` and
`opencode.db-shm`; a `mode=ro` open then either fails (macOS) or creates those two files (Windows `winsqlite3`), which
the app must never do. So: when the database header says WAL (bytes 18 and 19 are both 2) and no `-wal` file exists,
open with `immutable=1` directly, which reads the database file alone and creates nothing; otherwise open `mode=ro`,
and if that fails while no `-wal` file exists, fall back to `immutable=1`. Drop an immutable connection on the next
change of `opencode.db` or as soon as a `-wal` file appears, and reopen with `mode=ro`. A database without the tables `session_v2` and `session_message` is reported as unsupported (warning
`unsupportedFormat`) and contributes nothing.

Agents: one per session row. Agent id `opencode:<session_v2.id>`; `project` = basename of `session_v2.directory`;
`isSubagent = session_v2.parent_id IS NOT NULL`; parent link `opencode:<parent_id>` when that session is tracked;
`model` = the latest assistant `data.model.id`; `lastLineMs` = the latest `session_message.time_updated` of the
session.

Rows of `session_message` are processed per session in `seq` order; `data` is JSON:

| `type` | Action |
| --- | --- |
| `assistant` | Fork copies are ignored: skip rows whose `data.time.created < session_v2.time_created - 2000`. If `data.time.streamed` is absent the request is in flight: phase `generating`, `inFlightStartMs = data.time.created`, no response yet. Otherwise emit a response (key = row `id`) when `data.tokens` is an object: `startMs = data.time.created`, `endMs = data.time.streamed` (the stream end; tool execution between `streamed` and `completed` is not generation), `final = true`, `model = data.model.id`, tokens `input = tokens.input + tokens.cache.read + tokens.cache.write`, `cachedInput = tokens.cache.read`, `cacheWriteInput = tokens.cache.write`, `output = tokens.output + tokens.reasoning` (OpenCode reports reasoning separately), `reasoning = tokens.reasoning`. Phase afterwards: `tools` when `data.finish == "tool-calls"`, else `idle`. A later update of the same row replaces the response (4.4). |
| `compaction` | When `data.tokens` is an object: a response with the same token mapping, `startMs = data.time.created ?? null`, `endMs = data.time.completed ?? time_updated`, `model = data.model.id`. No phase change. |
| `idle` | phase `idle` |
| anything else | no change |

Verified on real data: per-session sums of these responses equal OpenCode's own `session_v2.tokens_*` totals except
for small background calls (titles) that OpenCode never stores as messages.

### 4.6 Gemini CLI

#### Format eras

| Versions | Session file | What changes for us |
| --- | --- | --- |
| ≤ v0.38 | `session-*.json` (sub-agents `<id>.json`): one pretty-printed JSON object, rewritten in place | Legacy snapshot (below) |
| v0.39 – v0.63 | `*.jsonl`, append-only | Full-history checkpoints `{"$set":{"messages":[…]}}` (v0.44+); failed requests (v0.54+) and aborted requests (v0.57+) are rolled back with a checkpoint |
| ≥ v0.64 | `*.jsonl`, append-only | `$patch` deltas replace checkpoints; rollbacks write `$rewindTo` |

Other version boundaries used below: ≤ v0.31 a response without text is first written when its tool calls finish;
v0.44+ every tool-result submission writes a `user` record; v0.54+ usage and thoughts are written only for the
successful stream attempt; v0.37+ sub-agents live in a per-parent directory; v0.29+ project directories are slugs.

#### Layout and discovery

- `<root>/<projectDir>/chats/<file>` — main sessions. `<file>` = `session-<YYYY-MM-DDTHH-MM>-<sessionId[0:8]>.jsonl`
  (UTC minute; a same-minute collision inserts `-<n>` before the short id).
- `<root>/<projectDir>/chats/<parentSessionId>/<sessionId>.jsonl` — sub-agents (v0.37+). Both ids have every
  character outside `[A-Za-z0-9_-]` replaced by `_`. Nested sub-agents are stored flat under the *main* session id.
- v0.33 – v0.36 wrote sub-agents as `session-*.json` directly in `chats/` (identified only by `kind`).
- `<projectDir>` is a slug of the project folder name (`agent-speed`, `agent-speed-1`, …) containing a `.project_root`
  file with the absolute project root (v0.29+; lowercased on Windows), or, for older versions, the SHA-256 hex of
  the project root. `<root>/../projects.json` maps project roots to slugs.
- Discovery: regular files (never symlinks) ending in `.jsonl` or `.json` whose path relative to the root is exactly
  `<projectDir>/chats/<file>` or `<projectDir>/chats/<dir>/<file>`. Nothing else under `tmp` is a session
  (`checkpoint-*.json`, `logs.json`, tool outputs, plans). Temporary and backup files (`*.tmp-<pid>`,
  `*.unreadable-<ms>`) do not match.
- Docker/Podman sandbox sessions are written to an ephemeral host temp directory and are out of scope.

`.jsonl` files use the line reader of section 5. `.json` files are whole-document snapshots (Legacy, below).
The startup reading order (section 5) covers all Gemini roots together.

#### Record classification

Every line is one JSON object, classified in this order (Gemini's own loader uses the same order):

1. `$rewindTo` is a string → rewind
2. `$patch` is an object → patch
3. `id` is a string → message record (`type`: `user`, `gemini`, `info`, `warning`, `error`)
4. `$set` is an object → metadata update
5. `sessionId` and `projectHash` are strings → header (first line of every file)
6. anything else → ignored

A message record is the complete message. The same `id` is appended again whenever the message changes (tool calls
attached, rarely tokens attached late, tool results masked); a later record replaces the earlier one and keeps the
original `timestamp`. A message `timestamp` is its creation time, never its update time. A tool call `timestamp` is the
time its batch of tool calls finished (all calls of a batch share it).

#### Timing model

- A `user` record is written immediately before the API request is sent: after compression, tool-output masking, model
  routing and loop detection, before `BeforeModel` hooks and connection retries. From v0.44 tool results are submitted
  as a `user` record too; before v0.44 the next request starts right after the tool calls are recorded on the previous
  `gemini` message.
- A `gemini` record is created once, after the last stream chunk (and after `AfterModel` hooks), already carrying the
  final `tokens` (from v0.32; earlier only when the response had text). The stream start is never recorded.
- Therefore `startMs` = latest `user` record, or the tool-call completion time when no `user` record followed it;
  `endMs` = the `gemini` record `timestamp`. The duration includes time to first token, 429 back-off and mid-stream
  retries of the same request.

State: `sessionId`, `pendingStartMs`, `pendingMarker` (id of the record that set `pendingStartMs`),
`seenToolCallIds` (set), `phase`; all start empty / `idle`.

| Record | Action |
| --- | --- |
| header | `sessionId`; `isSubagent` when `kind == "subagent"`; `startTime`, `lastUpdated` count for `lastLineMs`. A header that carries a `messages` array (a legacy object written on one line) is replayed like a legacy file. |
| `$set` | `lastUpdated` counts for `lastLineMs`; `kind`, `sessionId` as in the header; a non-empty string `summary` → phase `idle`, `pendingStartMs = null` (a sub-agent writes it when it finished; a main session only receives it from a later process); a `messages` array → checkpoint (below). Other keys are ignored. |
| `$rewindTo` | phase `idle`, `pendingStartMs = null` (user `/rewind`, cancelled or failed request). Responses are never removed. |
| `$patch` | if phase is `generating` and `$patch.removeIds` contains `pendingMarker` → phase `idle`, `pendingStartMs = null`. Nothing else. |
| `user` | `pendingStartMs = ts`, `pendingMarker = id`, phase `generating` (`inFlightStartMs = ts`) |
| `error` | phase `idle`, `pendingStartMs = null` (the interactive CLI writes it when a request failed) |
| `info` whose `content` is exactly the string `Request cancelled.` | phase `idle`, `pendingStartMs = null` (the interactive CLI writes it when the user cancels, before any rollback record) |
| other `info`, `warning`, other types | only `lastLineMs` |
| `gemini` | see below |

Message records without a parseable `timestamp` are ignored.

`gemini` record:
1. `key = id`. If the key was first seen in another file, ignore the record entirely (including its tool calls).
2. If `tokens` is an object:
   - New key: emit a response with `startMs = pendingStartMs`, `endMs = ts`, `final = true`, `model = model`. Exception:
     when the record already carries tool calls with parseable timestamps and `ts >=` the earliest of them, the
     message was created when its tools finished (≤ v0.31), the stream end is unknown, and `startMs = null`. Then
     `pendingStartMs = null`, `pendingMarker = null`. Phase `tools` when `content` has no visible text (a string
     that is empty after trimming, or no non-thought `text` part) or contains a `functionCall` part; otherwise `idle`.
   - Known key (same file): replace the tokens, `model = model ?? previous`, `endMs = max(endMs, ts)`. Phase unchanged.
3. Tool calls: the entries of `toolCalls` that have a string `id` not yet in `seenToolCallIds` are new (add them).
   If there are new calls:
   - one of them is named `complete_task` with `status == "success"` → phase `idle`, `pendingStartMs = null`
     (a sub-agent finished);
   - else all new calls have `status == "cancelled"` → phase `idle`, `pendingStartMs = null` (nothing is submitted);
   - else phase `generating`, `pendingStartMs` = the latest `timestamp` of the new calls (else `ts`),
     `pendingMarker = id`, `inFlightStartMs = pendingStartMs`.
4. A `gemini` record without `tokens` and without new tool calls changes nothing (synthetic turns: compression
   acknowledgement, binary-content acknowledgement, interrupted-response placeholder).

Step 2 runs before step 3, so a record that both creates a response and reports finished tools ends in the phase of
step 3.

Checkpoint (`$set.messages`, v0.44 – v0.63): for every `gemini` message in it that has `tokens` and whose key is not
owned by another file: a known key is updated as in step 2; an unknown key (only possible when reading started
mid-file) is emitted with `startMs = null`. A checkpoint changes no other state, except: if phase is `generating` and
no message in it has `id == pendingMarker`, the in-flight request was rolled back → phase `idle`,
`pendingStartMs = null`.

Tokens (`tokens` is Gemini's `usageMetadata`; missing fields are 0, negatives clamp to 0):

| Field | Value |
| --- | --- |
| `input` | `tokens.input + tokens.tool` |
| `cachedInput` | `tokens.cached` |
| `cacheWriteInput` | 0 |
| `output` | `tokens.output + tokens.thoughts` |
| `reasoning` | `tokens.thoughts` |

`tokens.input` is `promptTokenCount` (already includes cached content); `tokens.output` is `candidatesTokenCount`
(excludes thoughts); `tokens.tool` is `toolUsePromptTokenCount`: results of server-side tools (search grounding, code
execution, URL context) fed back to the model as input and not part of `promptTokenCount`. `tokens.total` is the sum of
all four, so normalized `input + output == total`. `tokens.total` itself is not used.

Metadata:
- `lastLineMs` = the latest parseable timestamp among header/`$set` `startTime` and `lastUpdated`, message `timestamp`,
  `toolCalls[].timestamp` and `thoughts[].timestamp` of every record, including records ignored by deduplication.
  Messages inside checkpoints are not scanned.
- `model` = the model of the latest response created or updated in this file.
- `project` = basename of the trimmed contents of `<projectDir>/.project_root` (split on `/` and `\`); else the key of
  `<root>/../projects.json` `projects` whose value equals the `<projectDir>` name; else null. The session file itself
  never records the working directory. Read once per project directory and cache.
- `isSubagent` = `kind == "subagent"` (header or `$set`), or the file is inside `chats/<dir>/`.

#### Legacy `.json` (≤ v0.38)

The file is one JSON object `{sessionId, projectHash, startTime, lastUpdated, messages[], kind?, directories?,
summary?}`, rewritten in place (not atomically) on every change. Whenever its size or modification time changes, read
the whole file (files over 64 MiB are not read and carry the `partialHistory` warning) and parse it. On a parse failure
(caught mid-write) count one malformed line and keep the previous state. On success reset the file's parser state
(never the dedupe set) and replay: the object as a header, then each `messages` element in order as a message record
with the rules above. Responses of earlier snapshots missing from the new one (rewound) stay recorded; same-key
emissions are updates (4.4). The startup rules of section 5 apply (files modified before `todayStartMs - 15 min` are
not read).

#### Deduplication and copied history

- `key` = message `id` (random UUID), shared global dedupe set (3.4): the first file that emits a key owns it.
- Resuming a `.jsonl` session appends to the same file; nothing is copied.
- Resuming a legacy `.json` session (v0.39+) copies its header and every message, unchanged, into a new file with the
  same name plus `l` (`….json` → `….jsonl`); the `.json` stays. The copied responses are owned by the `.json` (older
  modification time, read first) and ignored. If the `.json` was not read, the copies count with their original
  timestamps, normally before today.
- When a `.jsonl` cannot be reloaded on resume, Gemini rewrites it atomically (rename): the identity change resets the
  file (section 5); the same keys merge as same-file updates.
- `$set.messages` checkpoints repeat messages already in the file; they merge by key.

#### Known approximations

- `tools` vs `idle` after a response: Gemini writes a response's tool calls only after they finish, so a response
  that has text *and* calls tools shows `idle` while its tools run (and while they await approval). A final answer
  with empty text after a tool result shows `tools` until the 300-second staleness rule.
- Before v0.44 the next request's start is the tool-completion time, which also includes compression, masking and
  routing that run before the request.
- Up to v0.53 Gemini writes a `gemini` record for an invalid stream attempt before retrying; the retry's response
  then has `startMs = null` (totals only). v0.54+ record only the successful attempt, so tokens of failed attempts are lost.
- LLM calls that Gemini does not record (chat compression, model-routing classifier, next-speaker check, loop
  detection, session summaries, helper tools) are not counted; totals are lower than Gemini's `/stats`.
- Before v0.54 failed requests are not rolled back and before v0.57 cancelled ones are not: the interactive CLI's
  `error` / `Request cancelled.` records end the phase; in `-p` and ACP sessions the phase stays `generating` until
  staleness. A quota fallback that adds tool results without sending them also leaves `generating` until staleness.
- If the previous `gemini` message has no tokens when a new response's usage arrives, Gemini attaches the new usage
  to that older message: the response is emitted under the older key with an invalid interval (totals only).
- Derived from the Gemini CLI source (v0.66, evidence in `spec/research/gemini-cli.md`); not yet verified against real
  session files.

### 4.7 omp (oh-my-pi)

omp (`can1357/oh-my-pi`, MIT) is a fork of pi (`badlogic/pi-mono`) with its own JSONL session files. Upstream pi
(`~/.pi/agent/sessions`, no request durations) is out of scope. Every model response is written once, complete, after
its stream ended, with omp's own request start (`message.timestamp`) and measured request duration
(`message.duration`); nothing is written while a request is in flight. Evidence: `spec/research/omp.md`.

#### Format eras

| Versions | Change | Effect on these rules |
| --- | --- | --- |
| ≤ 2.3 | binary `pi`, root `~/.pi/agent/sessions`, session version 2 | out of scope |
| 3.0 – 6.9.0 | root `~/.omp/agent/sessions`, session version 3; assistant messages have no `duration` | `endMs` = entry timestamp |
| 6.9.69+ | `duration` and `ttft` on assistant messages | `endMs = timestamp + duration` |
| 16.3+ | the first physical line is a fixed 256-byte `title` slot, rewritten in place | ignored |
| 17.2.5 – 17.2.8 | bucket folders named `<scope>-<basename>-<sha256>` (17.2.9 migrates them back) | none |
| 18.1+ | `model_usage` entries (side calls), `completedAt` on assistant messages, `runtime` on entries | side calls count in totals; second `endMs` fallback |

omp migrates older session files on load and rewrites them on its next write; files written today come almost
entirely from 18.x.

#### Roots and discovery

- Automatic roots (section 2): the default root, then one root per named profile. Profile names are the folders in
  `~/<cfg>/profiles` and, on macOS when `$XDG_DATA_HOME` is set, in `$XDG_DATA_HOME/omp/profiles`. A profile's root is
  `$XDG_DATA_HOME/omp/profiles/<name>/sessions` on macOS when `$XDG_DATA_HOME/omp/profiles/<name>` exists, else
  `~/<cfg>/profiles/<name>/agent/sessions`. Profiles ignore `$PI_CODING_AGENT_DIR`. `XDG_*` variables are never used on
  Windows. Roots that do not exist are skipped; a path listed twice is scanned once.
- Sessions written to custom folders (`--session-dir`, `--session`, `PI_CODING_AGENT_SESSION_DIR`; omp lists them in
  `<agent dir>/custom-session-files/`) are read only when the user setting points at their folder.
- Layout: `<root>/<bucket>/<YYYY-MM-DDTHH-MM-SS-mmmZ>_<sessionId>.jsonl` are main sessions (`<bucket>` encodes the
  working directory, `sessionId` is a UUIDv7); `<root>/<bucket>/<stem>/<name>.jsonl` belong to the session
  `<stem>.jsonl` (task sub-agents `<AgentId>.jsonl`, advisors `__advisor.jsonl` / `__advisor.<slug>.jsonl`, seance
  consults); a sub-agent's own children nest the same way under `<stem>/<AgentId>/`.
- Discovery: regular files (never symlinks) whose name ends in `.jsonl` and whose path relative to the root has at
  least two components, within the depth limit of section 2. Every file or folder whose name starts with `.` is
  skipped (`omp gc --compress` stages copies in `.omp-gc-compress-*`; rewrite temps are `.<name>.jsonl.<id>.tmp`).
  Windows move-aside backups (`*.jsonl.<id>.bak`), archives (`*.jsonl.gz` under `<agent dir>/archive`, outside the
  root) and artifacts (`*.log`, `*.md`, `*.patch`, `draft.txt`) do not match. Collab replicas (`~/.omp/collab`),
  `omp render` working copies and sub-agents of `--no-session` runs are outside every root.

Writes are single-line appends or full rewrites through a temp file renamed over the transcript (a new identity:
section 5 resets the file). The title slot is overwritten in place without changing the file size.

#### Record classification

Every line is one JSON object, classified by `type`:

1. `title` — the title slot. Ignored entirely.
2. `session` — the header. Only the first one counts; later headers are ignored entirely.
3. `message` — by `message.role`: `user`, `developer`, `assistant`, `toolResult`; any other role (`bashExecution`,
   `pythonExecution`, `fileMention`, `custom`, `hookMessage`) only updates `lastLineMs`.
4. `model_usage` — a side model call.
5. `custom` with `customType == "session_exit"` — the omp process ended.
6. anything else (`model_change`, `thinking_level_change`, `compaction`, `branch_summary`, `custom_message`, other
   `custom`, `label`, …) — only `lastLineMs`.

Lines before the header are ignored. Entries other than the header without a string `id` (version-1 files from before
2026) or without a parseable `timestamp` are ignored entirely. When reading a file starts at an offset greater than 0
(section 5), its header is read first: the first line of type `session` among the first two lines of the file (the
title slot precedes it since 16.3).

#### Timing model

- An assistant `message` entry is appended once, at the end of its stream and before its tools run. Partial streaming
  output is never persisted; there is no record while a request is in flight.
- `message.timestamp` (Unix ms) is taken when the provider call starts, immediately before the request is built and
  sent; it is never rewritten (not on in-provider retries, not on copies). `message.duration` (ms, monotonic) runs from
  that instant to the end of the stream. `message.completedAt` (18.1+) is the wall clock when the message ended.
- Therefore `startMs = message.timestamp`; `endMs = startMs + duration` (truncated to whole milliseconds; `duration`
  has sub-millisecond digits) when `startMs` is known and `duration` is a finite number ≥ 0, else `completedAt`
  (truncated) when it is a finite number > 0, else the entry `timestamp`. The interval includes request building, time
  to first token and in-provider retries with their back-off; it excludes agent-level work before the call.
- The input entry (`user`, `developer`), or the tool result that completes a batch, is written a few milliseconds
  before the next request starts; it starts the in-flight estimate.

State: `headerMs` (nullable), `pendingToolCalls` (set of ids), `phase` (starts `idle`).

| Record | Action |
| --- | --- |
| header | `headerMs` = its `timestamp`; `project` from `cwd`; the header `timestamp` counts for `lastLineMs` |
| any entry whose `timestamp` is earlier than `headerMs - 2000` | copied history (forks, branches, imports, moves): ignore completely |
| `message` / `user` or `developer` | phase `generating`, `inFlightStartMs = ts`; `pendingToolCalls` cleared |
| `message` / `assistant` | response (below) |
| `message` / `toolResult` | remove `message.toolCallId` from `pendingToolCalls`. If `message.toolName == "yield"` and `message.isError` is not `true` → phase `idle` (a sub-agent's final yield ends its run). Else if phase is `tools` and `pendingToolCalls` is empty → phase `generating`, `inFlightStartMs = ts`. |
| `model_usage` | side-call response (below); no phase change |
| `custom` / `session_exit` | phase `idle`, `pendingToolCalls` cleared |
| anything else | only `lastLineMs` |

`message` / `assistant` (`m` = `message`):
1. Skip the entry (only `lastLineMs`) unless `m.model`, `m.provider` and `m.api` are strings and `m.usage` is an
   object (omp's own statistics apply the same guard).
2. `stamp` = `m.timestamp` truncated to an integer when it is a finite number > 0, else the entry `timestamp` (ms).
   `key = "omp:" + id + ":" + stamp` (decimal). If the key was first seen in another file, ignore the entry: no
   response and no phase change (it still counts for `lastLineMs`). A repeat in the same file is an update (4.4).
3. `stopReason` = `m.stopReason`; a missing or non-string value counts as `aborted`.
4. When at least one of `usage.input`, `usage.output`, `usage.cacheRead`, `usage.cacheWrite` is > 0, emit a response:
   `startMs = m.timestamp` when it is a finite number > 0 (else null), `endMs` as in the timing model, `final = true`,
   `model = m.model`, tokens below. When `stopReason` is `error` or `aborted`, `startMs = null` (totals only: failed
   and interrupted requests carry partial or no output). Messages whose four fields are all 0 (abort placeholders, the
   synthetic message that closes a resumed interrupted turn) produce no response.
5. Phase, also when step 4 emitted nothing: `stopReason` `error` or `aborted` → `idle`, `pendingToolCalls` cleared.
   Else when `m.content` has blocks of type `toolCall` with a string `id` and `stopReason` is `toolUse`, `stop` or
   `length` → `tools`, `pendingToolCalls` = those ids (omp runs tool calls under `stop` too; under `length` it writes
   skipped results and continues). Else when `stopReason == "stop"` and `m.stopDetails.type == "pause_turn"` →
   `generating`, `inFlightStartMs = endMs` (omp samples again). Otherwise `idle`.

`model_usage` (18.1+) records side calls billed to the session (`purpose`: `auto-thinking`, `job-widget`, `ttsr`,
`memory`, `find`, `task-completion-probe`, `auto-prewalk`, `auto-graph`, `unexpected-stop`, …). Same guard as step 1
on the entry's own `model`, `provider`, `api` and `usage`; `key = "omp:" + id + ":" + <entry timestamp ms>`,
deduplicated like step 2. When one of the four token fields is > 0, emit `startMs = null`, `endMs = ts`,
`final = true`, `model = model`. These responses never set the agent's `model`.

Verification target (once real files are available): per file, the token sums equal what `omp stats` stores for it (it
reads exactly the assistant messages and `model_usage` entries), and each response's speed equals omp's own
`output * 1000 / duration`.

#### Tokens

`usage` is omp's normalized `Usage` (every provider maps into it). Missing or non-numeric fields are 0, negatives clamp
to 0.

| Field | Value |
| --- | --- |
| `input` | `usage.input + usage.cacheRead + usage.cacheWrite` |
| `cachedInput` | `usage.cacheRead` |
| `cacheWriteInput` | `usage.cacheWrite` |
| `output` | `usage.output` |
| `reasoning` | `usage.reasoningTokens` (absent → 0) |

`usage.input` is non-cached input only; `usage.output` already includes thinking and tool-call arguments, and
`reasoningTokens` is a subset of it (absent when the provider does not report it). `usage.totalTokens` and
`usage.orchestration` are not used (see approximations).

#### Metadata

- `project` = basename of the header `cwd` (split on `/` and `\`); null before the header is read.
- `model` = `message.model` of the latest assistant response created or updated in this file.
- `isSubagent` = the file's path relative to its root has three or more components (it lives inside a session's
  artifacts folder: task sub-agents, advisors, seance consults). The header's `parentSession` is not used (forks and
  branched main sessions carry it too).
- `lastLineMs` = the latest parseable `timestamp` of the header and of every entry that is not copied history,
  including entries ignored by deduplication and entries without usage.

#### Deduplication and copied history

- The key combines the entry `id` with the message's own `timestamp`; both survive every copy omp makes, and omp's
  statistics deduplicate on the same pair (first file wins). The shared dedupe set (3.4) applies.
- Copies with a fresh header: `/fork`, `/tree` branches, `--fork`, seance consults, the move to a sibling file when
  another process owns the session, `persistCopy`. Copied entries keep their `id` and `timestamp` while the new header
  gets the current time, so the copied-history rule removes them even when the source file is gone. A header
  timestamp is set only when a session identity is created, never by lazy materialization or rewrites.
- Imports: `/resume @claude` converts a Claude Code transcript into a new omp session, keeping each record's original
  timestamp and Claude's usage under new entry ids (`/resume @codex` imports no usage). Those API calls are already
  counted under `claudeCode` with other keys; the copied-history rule removes them.
- Copies without a fresh header: forks and moves also copy the source's artifacts folder in the background, which
  duplicates its sub-agent transcripts byte for byte. Only the dedupe set removes them; the copies are extra idle
  agents without responses of their own.
- Rewrites of the same file (migrations, `/rename` without a title slot, discarding a failed retry turn, recovery,
  `omp gc --compress` on macOS, which replaces the file): section 5 resets the file and the same keys merge as
  same-file updates. A response removed by a rewrite stays recorded.
- Resume appends to the same file.

#### Known approximations

- `usage.orchestration` (provider-side orchestration tokens: billed and part of `totalTokens`, but not part of the
  conversation) is not counted, so normalized `input + output` can be lower than `totalTokens`.
- Error and aborted responses count in totals only; their partial streams never contribute speed.
- In-flight state is inferred from neighbouring records. A brand-new session has no file until its first assistant
  message completes, so the first request of every new session is invisible while in flight (it appears with its full
  timing when it ends).
- Agent-level retries (overload, rate limit, network) start a new request without writing a record: the phase stays
  `idle` during the back-off and the retried request; its response still has exact timing.
- Interrupting while tools run writes aborted tool results and ends the turn without a final record: the phase shows
  `generating` until the 300-second staleness rule.
- In-provider retries keep the original `timestamp`, so their back-off lowers the measured speed. Providers that run
  tools inside one stream (Cursor exec channel, Devin, GitLab Duo workflows) include that tool time in `duration`.
- Calls omp does not record are not counted (compaction summaries, titles, branch summaries, unpersisted refusals and
  empty error turns, every side call before 18.1); totals match `omp stats`, not the provider bill.
- GitLab Duo writes no `duration`; before 18.1 its responses end at the entry timestamp (a few ms after the stream).
- Sub-agents nested deeper than the depth limit are not tracked.
- Derived from the omp source (v18.12.6, evidence in `spec/research/omp.md`); not yet verified against real session
  files.

### 4.8 Antigravity

Google Antigravity (the `agy` CLI, which replaced Gemini CLI for personal accounts on 2026-06-18; the 2.x desktop app;
the Antigravity IDE; IDE extensions) runs a local language server that keeps one SQLite database per conversation.
Every model call is a `PLANNER_RESPONSE` step row that carries its own usage and timestamps. Evidence:
`spec/research/antigravity.md`.

#### Format eras

| Era | Conversation store | Effect on these rules |
| --- | --- | --- |
| Antigravity IDE 1.x, agy before 1.0.7 | `conversations/<id>.pb`, `implicit/<id>.pb`: encrypted protobuf | out of scope (never decrypted) |
| agy 1.0.7 – 1.4.4, desktop app and IDE 2.x (since about June 2026) | `conversations/<id>.db`: SQLite (WAL) with protobuf blobs | read (below) |
| forks in agy 1.2.17 | both `<id>.pb` (at fork time) and `<id>.db` (once the fork continues) | only the `.db` |
| newer builds | also `brain/<id>/.system_generated/logs/transcript.jsonl` | out of scope (no usage) |

The database schema (`PRAGMA user_version = 1`, 7 tables) and the protobuf field numbers below are unchanged from agy
1.0.7 to 1.4.4; the IDE writes the same schema (verified at 2.2.1).

#### Stores and discovery

- Stores (section 2): `~/.gemini/antigravity-cli` (CLI), `~/.gemini/antigravity` (desktop app, IDE extensions, IDE
  1.x), `~/.gemini/antigravity-ide` (IDE 2.x). A store is the language server's `--app_data_dir`; no environment
  variable moves it. A store folder whose name ends in `-backup` (`antigravity-backup` holds a copy of `antigravity`)
  is never read, not even when the user setting names it. A user setting that names a folder called `conversations`
  is used as that folder directly.
- Discovery: regular files (never symlinks) directly inside `<store>/conversations/` whose name is a UUID (8-4-4-4-12
  hexadecimal digits, any case) followed by `.db`. Not sessions: `*.db-wal`, `*.db-shm`, `*.pb`, `implicit/`,
  `*.trajectory.json` (sidecars of third-party exporters), `conversation_summaries.db` (in the store folder), `brain/`,
  `annotations/`, `log/`.
- Each database is one agent: agent id = absolute path of the `.db`; conversation id = its file name without `.db`. It
  counts as one file for discovery statistics and the 20 000-file limit.
- Gemini CLI (4.6) never reads below these stores, so nothing is counted twice between the two sources.

#### Opening and querying

Each database is opened with the rules of 4.5: read-only (`mode=ro`, never written), busy timeout 2 s, short read
transactions; when the header says WAL (bytes 18 and 19 are both 2) and no `-wal` file exists (a closed
conversation), open with `immutable=1`; otherwise open `mode=ro`, falling back to `immutable=1` only when no `-wal`
file exists; an immutable connection is dropped on the next change of the `.db` or as soon as a `-wal` appears. Never
create a file. A database that cannot be opened or queried contributes nothing and is retried on its next change; one
without a `steps` table with the columns below carries the warning `unsupportedFormat` and contributes nothing (no agent).

Only these queries run (`?` = the cursors of 5.4, `-1` for a complete read). The size guards keep large blobs unread:
`gen_metadata` rows embed the whole prompt and reach hundreds of MB, so a row whose `size` column exceeds 1 MiB is
never read, even when its blob would be small.

```sql
SELECT idx, step_type, status, CASE WHEN length(metadata) <= 1048576 THEN metadata END FROM steps WHERE idx > ? ORDER BY idx, rowid
SELECT idx, CASE WHEN typeof(size) = 'integer' AND size <= 1048576 AND length(data) <= 1048576 THEN data END FROM gen_metadata WHERE idx > ? ORDER BY idx, rowid
SELECT idx, CASE WHEN length(data) <= 1048576 THEN data END FROM executor_metadata WHERE idx > ? ORDER BY idx, rowid
SELECT CASE WHEN length(data) <= 1048576 THEN data END FROM trajectory_metadata_blob ORDER BY rowid LIMIT 1
```

`step_payload` (prompts, responses, file contents) and the other blob columns are never read. NULL integers count as
0; a NULL blob (absent or too large) is skipped without counting as malformed. The tables have no primary key: rows
with the same `idx` are processed in `rowid` order, the later one replacing the earlier.

#### Protobuf wire format

Blobs are protobuf messages, decoded by a small hand-written walker (no protobuf library). A message is a sequence of
fields; each starts with a varint key, field number `key >> 3`, wire type `key & 7`:

| Wire type | Payload |
| --- | --- |
| 0 | varint: at most 10 bytes, 7 bits each, least significant group first |
| 1 | 8 bytes (fixed64, double) |
| 2 | a varint length, then that many bytes (string, bytes, nested message, packed repeated scalars) |
| 5 | 4 bytes (fixed32, float) |

Field number 0, wire types 3, 4 (groups), 6 and 7, a varint longer than 10 bytes, and a field that runs past the end of
its buffer make the blob malformed. Unknown fields of every valid wire type are skipped, and so is a known field
whose wire type differs from the one its type uses (except packed repeated scalars). proto3 omits default values:
a missing number is 0, a missing string is empty, a missing message is absent. A non-repeated field that occurs more
than once takes its last occurrence; where one value of a repeated message field is needed, its first occurrence is
used. Repeated scalars (`step_indices`) are accepted packed (wire type 2) and unpacked (wire type 0). Varints are
unsigned 64-bit; `int32` and `int64` fields reinterpret them as signed 64-bit (negative `int32` values are 10-byte
varints). Strings are UTF-8 (invalid sequences become U+FFFD). A `Timestamp` is `{1: seconds (int64), 2: nanos
(int32)}`; it is valid when `seconds > 0` and then equals `seconds * 1000 + nanos div 1 000 000` ms (nanos outside
0 … 999 999 999 count as 0). A blob that is malformed, including any nested message these rules read, counts as one
malformed line and is ignored.

Fields used (all others are ignored):

| Message (column) | Fields (number) |
| --- | --- |
| `CortexStepMetadata` (`steps.metadata`) | `created_at` 1, `viewable_at` 6, `finished_generating_at` 7, `completed_at` 8, `model_usage` 9, `last_completed_chunk_at` 22, `started_at` 32 (all `Timestamp` except 9) |
| `ModelUsageStats` | `input_tokens` 2, `output_tokens` 3, `cache_read_tokens` 5, `message_id` 7 (string), `thinking_output_tokens` 9, `response_output_tokens` 10, `response_id` 11 (string) |
| `CortexStepGeneratorMetadata` (`gen_metadata.data`) | `chat_model` 1, `step_indices` 2 (repeated uint32) |
| `ChatModelMetadata` | `response_model` 19 (string), `model_display_name` 21 (string) |
| `ExecutorMetadata` (`executor_metadata.data`) | `termination_reason` 1 (enum), `last_step_idx` 3 (int32), `cascade_config` 10 → `planner_config` 1 → `model_name` 28 (string) |
| `CortexTrajectoryMetadata` (`trajectory_metadata_blob.data`) | `workspaces` 1 (repeated) → `workspace_folder_absolute_uri` 1 (string); `created_at` 2; `parent_conversation_id` 5 (string); `workspace_uris` 7 (repeated string); `subagent_spec` 8; `nesting_depth` 17 (int32) |

Column enums: `step_type` 14 = `USER_INPUT`, 15 = `PLANNER_RESPONSE`; every other value is a tool or system step (for
example 8 `VIEW_FILE`, 21 `RUN_COMMAND`, 127 `INVOKE_SUBAGENT`). `status` 1 `PENDING`, 2 `RUNNING`, 3 `DONE`,
4 `INVALID`, 5 `CLEARED`, 6 `CANCELED`, 7 `ERROR`, 8 `GENERATING`, 9 `WAITING`, 11 `QUEUED`, 12 `INTERRUPTED`.
*Open* statuses are 1, 2, 8, 9 and 11; every other value is *terminal*. `ModelUsageStats.model` and
`CortexStepMetadata.generator_model` are enums whose current values are placeholders; they are not used.

#### Step rows

The trajectory metadata gives `createdMs` (= `created_at`), `project`, `isSubagent` and the parent link (6.7); while
it is missing, every read retries it.

Rows of `steps` are processed in `idx` order:
1. Skip a row whose `metadata` is NULL. Skip a row and count one malformed line when its `metadata` does not decode or
   a token field of its `model_usage` exceeds 10 000 000.
2. If `createdMs` is known, `created_at` is valid and `created_at < createdMs - 2000`, the row is copied history (a
   fork): ignore it completely.
3. Every valid timestamp of the row's metadata counts for `lastLineMs`. The row with the highest `idx` processed so far
   is the *latest row* (a re-read row replaces its earlier version).
4. When `step_type == 15`, the status is terminal, `model_usage` is present and one of its five token fields is > 0,
   the row is a response:
   - `key` = `model_usage.response_id` when non-empty, else `model_usage.message_id` when non-empty, else
     `"antigravity:" + conversation id + ":" + idx`. If the key was first seen in another database, no response.
   - `endMs` = `finished_generating_at`, else `last_completed_chunk_at`, else `completed_at`; `startMs` = `created_at`
     (null when invalid). When none of the three is valid, `endMs` = the latest valid timestamp of the row and
     `startMs = null`; a row without any valid timestamp gives no response.
   - Status 6, 7 or 12 (cancelled, error, interrupted) → `startMs = null` (totals only).
   - `final = true`, `model` as in Metadata, tokens below. A later version of the row is an update (4.4).

A `PLANNER_RESPONSE` row with an open status is in flight and produces no response yet, even when it already carries
usage.

#### Phase

After every read (the startup read included) the phase is a function of the rows read so far:
1. No latest row → `idle`.
2. An `executor_metadata` row with `termination_reason != 0` and `last_step_idx >=` the latest row's `idx` (the run that
   contains it has ended) → `idle`.
3. Otherwise by the latest row:

| Latest row | Phase |
| --- | --- |
| `PLANNER_RESPONSE`, open status | `generating`, `inFlightStartMs = created_at` |
| `PLANNER_RESPONSE`, terminal status | `idle` (a response with tool calls is followed by its tool rows at once) |
| `USER_INPUT`, status 6, 7 or 12 | `idle` |
| `USER_INPUT`, any other status | `generating`, `inFlightStartMs = created_at` (the model call follows at once) |
| other step, open status | `tools` |
| other step, `DONE` | `generating`, `inFlightStartMs = completed_at`, else `created_at` (the next model call) |
| other step, any other terminal status | `idle` |

An invalid timestamp makes `inFlightStartMs` null. The staleness rule (6.7) applies.

#### Timing model

- A `PLANNER_RESPONSE` step is created when the planner starts the model call and is filled while the stream arrives;
  `finished_generating_at` marks the end of generation. The duration therefore includes time to first token and the
  planner's retries of the same call (`retry_infos`), as with Gemini CLI.
- The matching `gen_metadata` row's `time_to_first_token + streaming_duration` should be close to `endMs - startMs`; it
  is not used (and agy ≤ 1.1.17's `chat_start_metadata.created_at` neither).

#### Tokens

`model_usage` of the planner row (`ModelUsageStats`); missing fields are 0.

| Field | Value |
| --- | --- |
| `input` | `input_tokens + cache_read_tokens` |
| `cachedInput` | `cache_read_tokens` |
| `cacheWriteInput` | 0 |
| `output` | `output_tokens`; when it is 0, `thinking_output_tokens + response_output_tokens` |
| `reasoning` | `thinking_output_tokens` |

Unlike Gemini CLI's `usageMetadata`, `input_tokens` excludes cached input, and `output_tokens` already includes
thinking (`output_tokens == thinking_output_tokens + response_output_tokens` on every audited real row).
`cache_write_tokens` (4) is deprecated and 0.

#### Metadata

- `model` of a response: `chat_model.response_model` of the `gen_metadata` row with the lowest `idx` whose
  `step_indices` contains the row's `idx`, else that row's `chat_model.model_display_name`; else the `model_name` of
  the `executor_metadata` row with the smallest `last_step_idx >=` the row's `idx` (ties: lowest `idx`); else null.
  Empty strings count as missing. The model is resolved from the rows read so far; when a later read changes it, the
  response is updated (4.4). Serving variants (`-exp-b`) and routing labels (`gemini-pro-default`) are shown as they
  are.
- Agent `model` = the model of the response with the highest `idx` that has one.
- `project` = basename of the first `workspace_uris` entry, else of the first `workspaces` entry's
  `workspace_folder_absolute_uri`, else null. A URI (a scheme of two or more characters, such as `file:` or
  `vscode-remote:`) loses its scheme and authority (`//host`) and is percent-decoded as UTF-8 (invalid escapes stay as
  they are) before splitting on `/` and `\`; `file:///c%3A/Users/dev/projects/orbit` gives `orbit`.
- `isSubagent` = `parent_conversation_id` non-empty, or `nesting_depth > 0`, or `subagent_spec` present.
- `lastLineMs` = the latest valid timestamp among the processed rows' metadata and `createdMs`.

#### Deduplication and copied history

- The shared dedupe set (3.4) applies to response keys: the first database that emits a key owns it. This removes the
  same conversation found in two stores (some machines hold byte copies in `antigravity` and `antigravity-ide`) and
  history copied by `/fork`.
- The copied-history rule (step 2) also drops forked rows that have no response id.
- `/rewind` and cleared steps never remove counted responses.

#### Known approximations

- Antigravity timing semantics are not yet verified against real data: the meaning of `created_at` and
  `finished_generating_at` for planner rows is inferred from field names, Windsurf-era semantics and one sanitized
  timing sample (1.65 s and 2.36 s for two short answers).
- Whether a planner row with status `GENERATING` is written before its stream ends is unknown; if it is not, the
  in-flight phase comes only from the user-input and finished-tool rules.
- Error, cancelled and interrupted planner responses count in totals only.
- Model calls that are not planner steps (context checkpoints, titles, summaries, side questions) exist only in
  `gen_metadata`, which is not scanned for responses, and usage of failed retry attempts (`retry_infos[].usage`) is
  not counted: totals are lower than Antigravity's own `/usage`.
- Usage written to a row after it reached a terminal status is seen only by the next complete read (startup, history).
- Legacy encrypted conversations, transcript-only conversations, the Gemini macOS app's Antigravity integration and
  the Python SDK runtime contribute nothing.
- Derived from public reverse-engineering projects and the protobuf descriptors of agy 1.0.10 – 1.4.4 (evidence in
  `spec/research/antigravity.md`); not yet verified against real conversation databases.

### 4.9 WorkBuddy

Tencent WorkBuddy is an Electron desktop agent in two editions built from one code base. They differ only in branding,
service and data folder, so they are two sources with one parser. Each conversation runs in an embedded CodeBuddy Code
CLI, which appends one plain-text JSONL transcript per session. No line records when a request started, so the start
is inferred from the line before it, as for Gemini CLI. Evidence: `spec/research/workbuddy.md`.

| Source | App (macOS bundle id) | Windows executable | Data folder | Service |
| --- | --- | --- | --- | --- |
| `workbuddy` | `WorkBuddy.app` (`com.tencent.workbuddy.mac`) | `WorkBuddy.exe` | `~/.workbuddy` | workbuddy.cn |
| `workbuddyAi` | `WorkBuddy AI.app` (`com.workbuddy.workbuddy-ai`) | `WorkBuddyAI.exe` | `~/.workbuddy-ai` | workbuddy.ai |

#### Format eras

Only one era is known: app 5.8.3 (China edition) and 5.8.4 (international edition), both embedding CodeBuddy Code
2.161.0 with byte-identical transcript code. Older and newer versions have not been inspected, so the parser is
tolerant: unknown line types and fields are ignored, and a timestamp may be a number or an ISO string.

#### Roots and discovery

- Root (section 2): `<data folder>/projects`. The user setting, per source, names the data folder or its `projects`
  folder and replaces that source's root. The app's own `WORKBUDDY_CONFIG_DIR` / `CODEBUDDY_CONFIG_DIR` are **not**
  honoured: both editions read the same names, `CODEBUDDY_CONFIG_DIR` also moves the standalone CodeBuddy Code CLI, and
  the app sets them only on itself and its children (a launched app sees no shell variables).
- The standalone CodeBuddy Code CLI (`~/.codebuddy`, same format) is not a WorkBuddy source. The Windows fallback
  folders of older releases (`C:\ProgramData\WorkBuddy\users\<hash>\.workbuddy` and others) are not read: 5.8 merges them
  into the data folder at launch.
- Layout: `<root>/<slug>/<session>.jsonl` is a main session (`<slug>` is the working directory with `/`, `\` and `:`
  replaced by `-`; `<session>` is a UUID); `<root>/<slug>/<session>/subagents/agent-<id>.jsonl` is a sub-agent, filed
  under its main session (the code files a sub-agent under its parent's runtime session id, which for a main session is
  the file name).
- Discovery: regular files (never symlinks) whose name ends in `.jsonl` and does not start with `.`, whose path
  relative to the root is exactly `<slug>/<file>` or `<slug>/<dir>/subagents/<file>`, where neither `<slug>` nor
  `<dir>` starts with `.` and `<slug>` is not `cloud`. Nothing else is a transcript: `<session>.meta.json` and legacy
  `agent-<id>.meta.json`, `<session>/tool-results/`, `<session>/subagents/workflows/**/journal.jsonl`, and everything
  outside `projects` (`traces/`, `logs/`, `sessions/`, `usage-data/`, `app/`, `models.json`, `settings.json`,
  `workbuddy.db`) is never opened.
- `cloud/` holds mirrors of conversations that ran on Tencent's servers, rebuilt from the service: every record of a
  request shares one timestamp, usage is per request and the files are rewritten when they are reconciled. They are not
  read; cloud conversations are out of scope like Claude Desktop chats (section 2), and DESIGN 5 says so.
- Writes are appends of one line at a time (a failed append is truncated back); forks write a new file. The CLI's own
  30-day cleanup is turned off by the app; its data-retention setting deletes whole files.

#### Line format and classification

Every line is one JSON object: `id`, `parentId`, `timestamp` (Unix ms, a number), `type`, `role`, then the item's own
fields, `providerData`, the session's working directory `cwd` (on every line except `summary`, `topic` and
`session-meta`) and `sessionId`. `timestamp` is valid when it is a finite number > 0, truncated (3.6: `0.5` gives 0,
`1e19` gives 2^63 − 1), or a timestamp string (3.1); lines without a valid timestamp are ignored entirely. Only `id`,
`type`, `role`, `status`, `timestamp`, `cwd`, `callId` and the `providerData` fields named below are read; content,
arguments and tool output never are.

Values of the wrong type count as absent: `id` and `providerData.messageId` only as non-empty strings, `callId` only
as a string (a `callId` that is an object or an array opens and closes no call), `providerData` only as an object, flags
only as `true`. A repeated member takes its last value, as with `json.loads`. *Blank* means empty or whitespace only,
with Python's `str.isspace()` as whitespace (U+0009–U+000D, U+001C–U+0020, U+0085, U+00A0, U+1680, U+2000–U+200A,
U+2028, U+2029, U+202F, U+205F, U+3000); *trimmed* removes that whitespace at both ends.

| Line | Meaning |
| --- | --- |
| `message`, `role == "user"` | input; written just before the request it starts. With `providerData.skipRun == true` it starts no request (a note the CLI adds). |
| `function_call_result` | the result of one tool call (`callId`); the results of a step are written together when every tool of the step finished |
| `reasoning`, `function_call`, `message` with `role == "assistant"` | output items of one model call, written one by one after the stream ended. An assistant `message` with `providerData.skipRun == true` is a notice written by the CLI (hook output, interruption, error, content-filter notice), never model output. |
| `model-usage` | usage of a model call whose last output item lacked raw usage, or that had no output item to carry it (reasoning only, empty); written when the run ends, with the earlier time the stream ended |
| anything else (`session-meta`, `credit-usage`, `summary`, `ai-title`, `custom-title`, `topic`, `file-history-snapshot`, `goal-progress`, `goal-result`, `resend-fork-notice`, `turn-metrics`, `acp-terminal-state`, `role == "system"`, unknown types) | only `lastLineMs` and `cwd` |

#### Timing model

- The transcript has no request start, time to first token or duration (they exist only in the CLI's memory and
  telemetry; `turn-metrics` is never written by the runtime WorkBuddy uses, and it measures turns, not calls).
- A user line is appended after the `UserPromptSubmit` hooks, while the request is being assembled; compaction that the
  new message needs runs before it and writes its own lines first. A model call's output items are created after the
  stream's final event and appended a few milliseconds apart; the last one carries the usage. Tool results are stamped
  when the CLI picks them up, which can be a few milliseconds after the next request was sent.
- Therefore `startMs` = the latest input line before the call (the user line, or the tool result that completed the
  step) and `endMs` = the line that carries the call's usage (the latest when several do). The interval includes time
  to first token and the assembly of the request; there is no record while a request is in flight, so the phase comes
  from the input lines.

State: `pendingStartMs`, `openCalls` (tool call id → response key), `phase`.

| Line | Action |
| --- | --- |
| any line | `lastLineMs`; a string `cwd` that is not blank sets `project` and `cwdPath` (the latest wins) |
| user `message`, not `skipRun` | `pendingStartMs = ts`, `openCalls` cleared, phase `generating` (`inFlightStartMs = ts`) |
| user `message` with `skipRun` | nothing else |
| `function_call_result` | remove its `callId` from `openCalls`. Not `skipRun`: `pendingStartMs = ts`, and when `openCalls` is empty phase `generating` (`inFlightStartMs = ts`). With `skipRun` (a rejected or cancelled tool; no request follows): when `openCalls` is empty, phase `idle`, `pendingStartMs = null`. A tool that failed (`status == "incomplete"` without `skipRun`) continues the turn. |
| assistant notice (`skipRun`) | `status == "incomplete"` or `providerData.error` is an object (interrupted or failed request) → phase `idle`, `pendingStartMs = null`, `openCalls` cleared; otherwise nothing (hook output while tools run) |
| output item with `providerData.isPartialAborted == true` | nothing else (a draft saved on interruption, without usage; the notice follows) |
| other output items, `model-usage` | below |

Output items and `model-usage`:
1. `key = providerData.messageId` (a non-empty string; one per model call, on every item of the call — the call's tool
   results repeat it, but they are not output items), else `"workbuddy:" + id` (a non-empty string). A line with
   neither has no key and is ignored entirely, like a line whose key was first seen in another file: no response, no
   phase change, `openCalls` and `pendingStartMs` unchanged (only the any-line row applies).
2. Usage: when `providerData.usage` or `providerData.rawUsage` is an object and the normalized `input` or `output` is
   > 0 — a new key emits a response with `startMs = pendingStartMs`, `endMs = ts`, `final = true`, `model` and
   `provider` below, then `pendingStartMs = null`; a known key (same file) is an update (4.4): `endMs = max`, every
   token field `= max(previous, new)`, `model = new ?? previous`, `provider = new ?? previous` (so a `custom` model
   keeps its provider when a later line of the call lacks the prefix).
3. Phase:
   - `model-usage`: the run has ended → phase `idle`, `pendingStartMs = null`, `openCalls` cleared.
   - First, drop the `openCalls` entries of other keys (calls left without a result).
   - `reasoning`: nothing.
   - `function_call`: `openCalls[callId] = key`; phase `tools`.
   - assistant `message`: when `openCalls` is empty — `providerData.agent == "compact"` (a compaction call) → phase
     `generating`, `pendingStartMs = ts`, `inFlightStartMs = ts` (the request it made room for follows); otherwise
     phase `idle`. When calls of the same key are open (text written after them), nothing.

A tool waiting for the user's permission keeps the phase `tools`. There is no end-of-turn line: the turn ends with the
final assistant message.

#### Tokens

`providerData.usage` is agents-core's `Usage` (`inputTokens`, `outputTokens`, `inputTokensDetails[]`,
`outputTokensDetails[]`); `providerData.rawUsage` is the service's OpenAI-style usage of the same call and is sometimes
missing. Values follow 3.2: missing or non-numeric values are 0, numbers are truncated and clamped to 0 … 10^12.

- *The first value > 0 of* a list of candidates: the first candidate, in the order listed, that is a finite number
  > 0 (3.6), truncated. Later candidates are not consulted, even when the chosen value truncates to 0 (`0.5`); 0 when
  no candidate qualifies (a `1e999` or a non-number is skipped like a missing one). A candidate inside an object that is
  missing or not an object is missing.
- `inputTokensDetails` and `outputTokensDetails` are arrays of objects; a single object counts as an array of that one
  object. Entries that are not objects, and any other value, count 0.
- Σ and `cachedInput + cacheWriteInput` saturate at 10^12 (3.2).

| Field | Value |
| --- | --- |
| `cachedInput` | max of Σ `usage.inputTokensDetails[].cached_tokens` and the first value > 0 of `rawUsage.cache_read_input_tokens`, `rawUsage.prompt_tokens_details.cached_tokens`, `rawUsage.prompt_cache_hit_tokens` (in this order) |
| `cacheWriteInput` | the first value > 0 of `rawUsage.cache_creation_input_tokens`, `rawUsage.prompt_cache_write_tokens` (in this order; else 0) |
| `input` | max of `usage.inputTokens`, `rawUsage.prompt_tokens` and `cachedInput + cacheWriteInput` |
| `output` | max of `usage.outputTokens` and `rawUsage.completion_tokens` |
| `reasoning` | max of Σ `usage.outputTokensDetails[].reasoning_tokens` and `rawUsage.completion_tokens_details.reasoning_tokens` |

Input follows the OpenAI convention: `inputTokens` (= `prompt_tokens`) already includes cache reads and writes (the
CLI's own cost code subtracts both from it). DeepSeek's `prompt_cache_miss_tokens` are uncached input, never cache
writes, although the CLI counts them as writes. The `max` keeps a value that one of the two objects lacks (DeepSeek's
hits are often only in `rawUsage`). `totalTokens`, `requests`, `credit` and the line's top-level `message.usage`
(derived by the CLI, with DeepSeek misses as writes) are not used.

#### Models and cost

- `model` = `providerData.model` (the model the stream reported; the CLI falls back to the requested id), else
  `providerData.requestModelId`: the first of the two that is a string and not blank, trimmed; neither → null. A
  `model` that is only whitespace therefore falls back to `requestModelId`. `requestModelName` (a display name) is not
  used.
- A `custom:` or `custom-local:` prefix (a model of the user's own provider, from `models.json`; the prefix is never
  sent to the provider), matched without regard to ASCII case (`Custom:`, `CUSTOM-LOCAL:`), is removed and the
  response's `provider` is `custom` (9.2 then prices the remaining id). The rest is trimmed; when it is empty
  (`custom:`), `model` is null — `requestModelId` is not consulted — and `provider` is still `custom`.
- Built-in ids are mostly the provider's own (`glm-5.3`, `kimi-k3`, `deepseek-v4-pro`, `gpt-5.5`, `hy3`) and resolve
  with 9.2. Hosting suffixes of DeepSeek ids (`-sg`, `-volc`, `-lkeap`, `-taiji`: the same model served from another
  region or cloud) are `modifierSuffixes` of `deepseek-` in the price table and price as DeepSeek's own model, the
  way Bedrock regions do. Suffixes whose meaning is unknown (`-pay`, `-x`, `-1`, `-2`) stay unpriced.
- Routing slots — `auto`, `auto-chat`, `default`, `default-model…`, `fast-model`, `balanced-model`, `primary-model`,
  `deep-model`, and the legacy `default-1.1` / `default-1.2` (labelled Claude 3.7 / 4.0 Sonnet in the China catalog) —
  are chosen by Tencent's service; they are `unknown` entries of the price table. When the stream names the model it
  chose, `providerData.model` carries that name and the call is priced normally.
- WorkBuddy bills its users in credits (`credit-usage` lines); they are not used. Cost is API-equivalent (9).

#### Metadata

- `project` = basename of the latest `cwd` (split on `/` and `\`); `cwdPath` = that `cwd`. A chat without a chosen
  folder runs in the app's default workspace folder, whose name then shows as the project.
- `model` = the model of the latest response created or updated in this file.
- `isSubagent` = the file's path relative to the root is `<slug>/<dir>/subagents/<file>` (the folder structure only;
  a `subagents` folder above the root does not count). Parent: 6.7.
- `lastLineMs` = the latest valid timestamp of any line, including lines ignored by deduplication.

#### Deduplication and copied history

- `key` = `messageId`, in the shared dedupe set (3.4): the first file that emits a key owns it.
- A fork (`/fork`, editing and resending a message) writes a new file whose copied lines have new `id`s but keep
  `timestamp`, `providerData` (with `messageId` and usage) and `cwd`. The source file is older, is read first and owns
  every copied call; if it no longer exists, the copies count with their original timestamps. A fork's `session-meta`
  follows the copy and carries no creation time, so there is no timestamp rule as in 4.7: deduplication alone removes
  copies. Copied input lines change the fork's phase like any line until its first new line.
- A call whose usage appears twice in the same file (its last output item, then the end-of-run `model-usage` that adds
  the raw usage) merges as an update. A retried call gets a new `messageId`; usage of failed attempts is not written.
- Resuming a session appends to the same file.

#### Known approximations (to verify with real data)

- Derived from the code of WorkBuddy 5.8.3 / 5.8.4 (CLI 2.161.0, evidence in `spec/research/workbuddy.md`); no real
  session file has been read. Verify with `python3 spec/tools/reference.py --dump-today --workbuddy <data folder>`
  (or `--workbuddy-ai`).
- The start is inferred: work done between the user line and the request (memory context, other interceptors) counts as
  generation time, and a tool result picked up late moves the start a few milliseconds past the real request start.
  Calls after a pre-message compaction start at the user line written after it.
- Whether the service reports the chosen model for routing slots (otherwise those calls stay unpriced), and what the
  catalog suffixes mean.
- Whether `prompt_tokens` includes cache writes for Anthropic models behind Tencent's OpenAI-style service (`input` is at
  least `cachedInput + cacheWriteInput` either way).
- Whether a sub-agent's folder always has its main session's file name, also for nested sub-agents (otherwise they are
  still found, but show without a parent).
- A compaction call is measured only when its prompt line precedes it; after a compaction the user started by hand, the
  phase stays `generating` until the staleness rule (6.7). A turn that ends with a content-filter notice or a silent
  abort (no final message, no error notice) does the same.
- Calls without transcript lines are not counted: prompt enhancement, titles and replays run in a runtime without
  session persistence. Cloud conversations are not counted.

### 4.10 ZCode

Read the native SQLite store with short, read-only transactions using the same WAL/immutable safeguards as OpenCode.
The `session` table supplies identity, directory and parent links. Every session is one agent whose id is
`<database path>#<session id>`. `model_usage` is the sole token source; `message`, `part`, `turn_usage` and the app's
task index must not be added to its totals. A source with unsupported tables or columns is not parsed as another harness.

A terminal `model_usage` row with `completed_at` emits `key = "zcode:" + id`, `startMs = started_at`,
`endMs = completed_at`, `model = model_id`, `provider = provider_id`, `final = true`. Rows still running do not emit
responses. Input is `input_tokens` (already includes cache); cache read/write and reasoning are separate details,
not extra input/output. All numeric normalization follows 3.2. Startup includes calls that started before midnight
but completed today. The latest native user/assistant message and pending tool parts supply in-flight phase when
usage is not written until completion. Reading never creates or migrates the upstream database.

### 4.11 Kimi Code CLI

Discover only `sessions/<workDirKey>/<sessionId>/agents/<agentId>/wire.jsonl`, without following symlinks. `main`
is the main agent; other agent folders are children. Each file is its own agent. Metadata comes from native
`state.json` and `config.update.environmentDisclosure.cwd`; no credential file or conversation body is retained.
This adapter targets the TypeScript v2 wire journal; the old Python `kimi-cli` layout is not assumed compatible.

Wire records are flat objects with millisecond `time`. The adapter accepts `context.append_message`,
`agent.message.appended`, `human.agent.message.appended`, and `context.append_loop_event` / `step.end`.
Assistant usage may be on the message, its nested history entry's `meta.usage`, or the step-end event.
Identity is the provider/message id (or step uuid); `key = "kimi:" + identity`. A mirror of the same response
updates that key instead of counting another request. The shared deduper also excludes copied fork history.
`usage.record`, context token counters and parent `subagent.completed.usage` are not additional responses.

`input = inputOther + inputCacheRead + inputCacheCreation`, `cachedInput = inputCacheRead`,
`cacheWriteInput = inputCacheCreation`, `output = output`; absent details use the existing 3.2 rules.
`llm.request.time` is the pending start. Where it is absent, first-token latency plus stream duration can reconstruct
the interval; it includes time to first token. Streaming partial messages do not count as completed responses.
Turn, tool and request events drive the existing phase state machine; all speed calculations remain sections 3 and 6.

### 4.12 Grok Build

Discover only `sessions/<encoded-cwd>/<sessionId>/updates.jsonl`. Native `summary.json` supplies the working directory,
current model, session kind and parent relationship. The persisted JSONL envelope is
`{timestamp: <Unix seconds>, method, params: {sessionId, update, _meta}}`; prefer
`params._meta.agentTimestampMs` over the second-resolution envelope time.
When the native summary is not readable yet, activity can be tracked but numeric batches wait for metadata so a
late child relationship cannot cause double-counting. The live parser keeps at most 256 pending numeric batches;
the history reader can replay the full journal once metadata becomes available.

The canonical token record is the persisted `turn_completed` update's `usage`. Prefer its `modelUsage` buckets;
when there are none, use the flat usage (or its compatible `totals` object) with the current model. Do not also add
the companion cumulative `usage.json`, `signals.json`, turn-level totals or context-window counters. Buffered
`response_started` / `response_completed` messages are not assumed to be persisted.

For each model bucket:

- `key = "grok:" + prompt_id + ":" + model`, with native event id as the fallback identity.
- `input = inputTokens`, already including `cachedReadTokens` and `cacheCreationTokens`;
  `output = outputTokens` includes `reasoningTokens`. Provider remains null because the native record does not name one.
- `endMs` is the completion event time. A positive `apiDurationMs` within the existing 15-minute interval limit gives
  `startMs = endMs - apiDurationMs`; otherwise `startMs = null`, as for any other response without a valid interval.
- `requestCount` is native `modelCalls`, clamped to 1–100000. Other sources default to 1. Totals, model breakdowns,
  history, unpriced-request counts and reporting use this multiplicity; no per-call token values are fabricated.
- A later version of the same key is an upsert, including changes to its request count.

Grok folds child usage into its parent ledger. A session explicitly marked `subagent` or `subagent_fork` with a
parent id therefore contributes activity/parent links, while the parent's native batch is the single accounting
source. Ordinary forks remain independent, with copied prompt/model keys deduplicated. This avoids counting the
same child twice or retracting usage already sent by the append-only report ledger. Background usage missing from
an upstream incomplete parent batch cannot be reconstructed from that batch.

Batch normalization changes neither the existing speed formula, rolling window, interval validation, estimator,
missing-number rules nor pricing formula. The upstream file does not preserve each call's separate timeline: a
batch's API duration is represented as one interval ending at its completion. Intra-batch concurrency cannot be
reconstructed; independent sessions still add through the normal engine. API-equivalent cost is calculated by the
existing price book on the native model batch, so tier selection and rounding can differ from individual-call bills.
Evidence and executable checks: `spec/research/harnesses.md`, `spec/tools/harness_reference.py`, and
`spec/fixtures/harness-expected.json`.

## 5. Reading files

- Startup reading order (it decides which file owns a duplicated key): files sorted by modification time ascending,
  ties broken by ordinal path comparison. Each file is read to its end before the next one starts.
- Startup: every file whose modification time is within `todayStartMs - 15 min` or later is read from offset 0.
  Older files start at their current size (nothing is read). Files larger than 256 MiB are read from
  `size - 64 MiB`, aligned to the next newline, and the snapshot carries a `partialHistory` warning.
- While running: read appended bytes. Changes are detected with the OS file watcher (FSEvents on macOS,
  `FileSystemWatcher` on Windows) plus a 1-second fallback that stats files modified in the last 2 minutes, plus a full
  rediscovery every 10 seconds. Newly discovered files are read from offset 0.
- Incomplete trailing lines are buffered until their newline arrives. A file that starts being read at its end
  skips the bytes before the first newline it reads only when the byte just before its start offset is not a newline
  (so a complete line appended later is never dropped). The 256 MiB tail rule always skips to the next newline.
- If a file shrinks or its identity changes, reset its offset and its parser state (keep the global dedupe set).
- Reading never blocks the UI thread. Steady-state CPU target: < 1% on an idle machine.

Responses produced while reading the startup backlog are *seeded*: they count toward totals, peaks and agent speed
history but never produce live events.

### 5.1 zstd frame streams (DeepSeek Harness)
`.zstd` files are read frame by frame: from the current offset, determine the compressed size of the next frame
(zstd `findFrameCompressedSize`); if the frame is not complete yet, stop and wait for more bytes. Decode each complete
frame (at most 64 MiB of output per frame, else the frame counts as malformed and is skipped), feed the decoded bytes
to the line reader, and advance the offset past the frame. A frame that fails to decode is skipped and counted as one
malformed line. Skippable frames are skipped. When the bytes at the offset are not a frame at all (unknown magic or
an invalid block header), count one malformed line and resynchronize at the next zstd frame or skippable-frame magic
after the offset; if none is present yet, keep the offset and retry when the file grows. Files that start at their
end (older files) start at the current size; files over 256 MiB are not seeded at all (they start at their end with the `partialHistory` warning), because a frame
stream cannot be entered in the middle.

### 5.2 SQLite sources (OpenCode)
Change detection watches `opencode.db` and `opencode.db-wal` (file watcher plus the 1 s fallback). On a change, read
new rows with `time_created > cursor` (indexed) plus the current versions of rows that are still in flight or were
updated recently (`id IN (...)`), and sessions whose `time_updated` advanced. Startup reads sessions with
`time_updated >= todayStartMs - 15 min` completely. The source counts as one "file" for discovery statistics.

### 5.3 Compressed Codex sessions (`.jsonl.zst`)
Codex compresses finished rollouts in place (`rollout-….jsonl` becomes `rollout-….jsonl.zst`, written once). Such a
file is one zstd stream (usually one frame; its decompressed size can exceed 1 GB). Read it with streaming
decompression from offset 0 with bounded buffers: any number of frames, skippable frames skipped, no per-frame output
limit, the decoded bytes fed to the line reader (section 5 line rules). A decoding error stops the file there and
counts one malformed line; what was parsed before stays. The file is never tailed: when its size, modification time
or identity changes, reset it (parser state, never the dedupe set) and read it again from the start. Startup follows
the same modification-time rule as other files; the 256 MiB tail rule does not apply. A session compressed while it
is tracked shows up as a new file whose response keys are already owned by the `.jsonl` (3.4), so nothing counts
twice. Reading or re-reading a whole compressed file (or a legacy Gemini `.json`) while running happens off the
live loop, so live updates never pause; its results are applied in one step when the read completes.

### 5.4 Antigravity conversation databases
Real users have hundreds of small conversation databases (one audit: 381); only recently changed ones are opened.

- Startup: a database's modification time is the newer of `<id>.db` and `<id>.db-wal`; with that time it takes part
  in the startup reading order of section 5 (and of section 8). Databases modified within `todayStartMs - 15 min` or
  later are read completely (seeded). Older databases are not opened; the first time one changes while running, it is
  read completely off the live loop (like a whole compressed file, 5.3) and its results are applied in one step.
- Change detection: the file watcher on every `conversations` folder, plus the 1-second fallback, which stats the
  `.db` and `.db-wal` of databases modified in the last 2 minutes, plus rediscovery every 10 seconds (new databases are
  read completely). A change of either file marks the database dirty. The language server writes the WAL continuously
  while a conversation is open, so a dirty database is read at most once every 500 ms.
- Incremental read, one short transaction: `steps` rows with `idx` above the highest `idx` read so far, plus the current
  versions of the rows last seen with an open status (`idx IN (…)`); `gen_metadata` and `executor_metadata` rows above
  their own `idx` cursors; the trajectory metadata until it is found. Then the phase (4.8) is evaluated. A new identity
  of the `.db` file resets the database (parser state, never the dedupe set) and reads it completely.
- Connections: a connection idle for 60 seconds is closed, and at most 16 stay open (the least recently changed is
  closed first). Reopening follows the open rules of 4.8. Windows closes each connection right after its read instead:
  there a file another process holds open cannot be deleted or replaced, so a kept connection would stop Antigravity
  from deleting or rewriting the conversation.

## 6. Engine

All engine functions take an explicit `nowMs` so they are deterministic and testable. Production calls them every
500 ms and after each batch of file changes.

### 6.1 Retention
Keep responses with `endMs >= nowMs - 30 min` for speed computation (the fallbacks in 6.2 look back 30 minutes).
Today totals are aggregated incrementally.

### 6.2 Agent recent speed
For agent `a`: the up to 3 most recent measured responses ending within the last 10 minutes.
`recentSpeed(a) = Σ output / Σ duration_seconds` (and `recentTotalSpeed(a)` with `input + output`).
Fallbacks for estimation when the agent has none: the same formula over the up to 10 most recent measured
responses with the same model within 30 minutes (any agent), else with the same source within 30 minutes, else none.
Only measured responses are ever used as a speed reference.

### 6.3 Live rate
Window `W = 3000 ms`, interval `[nowMs - W, nowMs]`.

- Measured: for every measured response, `output * overlap(interval, [start', end]) / (end - start')`.
- Unmeasured: for every unmeasured response, `estimatedSpeed * overlap(interval, [start', end]) / 1000`, counted as
  estimated (`estimatedSpeed` as below, for that response's agent).
- Estimated (in-flight): for every agent in phase `generating` with `inFlightStartMs != null` and
  `nowMs - lastLineMs <= 300 000`, add `estimatedSpeed * overlap(interval, [estimateStart, nowMs]) / 1000`,
  where `estimateStart = max(inFlightStartMs, latest endMs of any response of that agent)` (so a response that is
  still being written, such as a streaming Claude message, is never counted twice) and `estimatedSpeed` is the
  agent's recent speed or its fallback (6.2). No estimate if none exists.
- `live.output = (measured + estimated) / (W / 1000)`. `live.total` uses `input + output` and total speeds.
- `liveEstimatedShare = estimated / (measured + estimated)` (0 when both are 0).

A completed response replaces its own in-flight estimate automatically, because a response ending moves the agent
out of `generating` or starts a new in-flight interval at the response end.

Per-source and per-agent live rates use the same formula restricted to that source or agent. The live cost rate
(9.5) uses the same window, intervals, estimates and reference responses.

### 6.4 Events (live only, never during seeding)
- `responseCompleted` — the first emission of a key (4.4) whose `endMs >= nowMs - 120 000`, carrying source,
  project, model, output, total, duration and speed. Older responses that appear later (a whole-file source such as a
  legacy Gemini `.json`, a `.jsonl.zst` read for the first time while running, or an older Antigravity database read
  on its first change, 5.4) update totals silently.
- `newPeak` — when the measured+estimated live output exceeds the previous peak of today by at least 1 tok/s, is at
  least 20 tok/s, and no `newPeak` was emitted in the last 60 seconds. This is the all-sources event; floating orbs that
  track a subset of sources use their own `newPeak_A` (6.8).

### 6.5 History
One-second buckets for the last 300 seconds, oldest first. Bucket `k` covers `[k*1000, (k+1)*1000)`.
`measured` = tokens of measured responses distributed uniformly over their intervals (the bucket value is tok/s for
that second). `estimated` = unmeasured-response and in-flight estimates for the same buckets (up to `nowMs`). Both for
output and total.

### 6.6 Today
`todayStartMs` = local midnight, supplied by the caller. A response belongs to today when `endMs >= todayStartMs`.
- `today`: sums of `requests`, `input`, `cachedInput`, `cacheWriteInput`, `output`, `reasoning` of all responses as
  recorded (unfinalized ones included, so output is a lower bound when any exist); per source as well.
- `unfinalizedToday`: number of today's unfinalized responses; when > 0 the snapshot carries the warning
  `unfinalizedUsage(count)`.
- `averageToday = Σ output / Σ duration` over today's measured responses (null when none).
- `peakToday`: maximum over today of the 3-bucket trailing average of *measured* one-second buckets, combined with the
  maximum live value observed while running. Keep a per-second measured array for the current day **per source**
  (`measured_s[k]`; the all-sources array is their sum), allocated only for sources with data today (86 400 Float32,
  ≈ 0.34 MB each), so subsets can be evaluated (6.8).
- `todayCost`: today's cost and unpriced responses, per source as well (9.6).
- On day change everything for "today" restarts at zero.

### 6.7 Agents list

Parent links (`parentId`, an agent id or null):
- Claude: a file at `<dir>/<session>/subagents/<name>.jsonl` has the parent `<dir>/<session>.jsonl` when that file is
  a tracked agent.
- DeepSeek: the tracked dsh file whose first header `id` equals this file's `parentSession` (the earliest created
  one if several).
- Codex: from the first `session_meta`, `parentThreadId = payload.parent_thread_id ??
  payload.source.subagent.thread_spawn.parent_thread_id`. The parent is the tracked file whose first `session_meta`
  has `payload.id == parentThreadId` (the earliest created one if several). `forked_from_id` alone is not a parent.
- Gemini CLI: a file at `<chats>/<dir>/<name>` (where `<chats>` is the directory named `chats`) has as parent the
  tracked Gemini file directly inside `<chats>` whose header `sessionId`, with every character outside
  `[A-Za-z0-9_-]` replaced by `_`, equals `<dir>`; several candidates → prefer `.jsonl` over `.json`, then the
  earliest header `startTime`, then ordinal path. Nested sub-agents therefore attach to the main session; v0.33 – v0.36
  sub-agents (directly in `chats/`) have no parent.
- omp: a file `<dir>/<name>.jsonl` whose path relative to its root has three or more components has the parent
  `<dir>.jsonl` when that file is a tracked agent (a nested sub-agent attaches to the sub-agent that started it).
- Antigravity: the tracked Antigravity database whose conversation id equals this database's
  `parent_conversation_id` (compared case-insensitively); several (copies in two stores) → prefer the one in the same
  `conversations` folder, then the ordinally smallest path. Sub-agents (browser, `invoke_subagent`, image generation)
  are separate conversations; parallel conversations of the agent manager and battle-mode forks are independent agents.
- WorkBuddy (both sources): as Claude — a file at `<slug>/<session>/subagents/<name>.jsonl` has the parent
  `<slug>/<session>.jsonl` when that file is a tracked agent of the same source. Nested sub-agents are stored flat
  under the main session, so they attach to it.
- Self references and cycles resolve to null.

List:
1. Staleness first: a phase older than 300 seconds without a new line is reported as `idle`.
2. Base set: agents whose `lastLineMs` is within the last 10 minutes, or whose phase is `generating`. An agent whose
   file no longer exists (deleted, or replaced by its `.jsonl.zst`) leaves the list as soon as that is noticed; its
   responses stay in every total.
3. Closure: add every ancestor (following `parentId`) of an agent in the set, even if it is inactive.
4. Tree: an agent's tree parent is its `parentId` when that agent is in the list; otherwise it is a root, and the
   reported `parentId` is null.
5. Order groups (roots with all their descendants) by: any member `generating` first; then the sum of the members'
   live output, descending; then the latest member activity, descending; then root id (ordinal). Inside a group, list
   depth-first with every agent immediately followed by its children; siblings ordered by `generating` first, live
   output descending, latest activity descending, id (ordinal).

UIs indent an agent by its depth in this tree and draw connectors from parent to children. To avoid jitter a UI may
keep its previous order between groups or between siblings whose live values are nearly equal, but it never splits a
group or shows a child without its parent.

### 6.8 Orb subsets

A floating orb (DESIGN 2b) tracks a source set `A`: `all` (every enabled source) or an explicit set. Everything below
is evaluated per orb on every engine tick (500 ms) from per-source values the engine already has; an orb with
`A = all` gets exactly the all-sources values. Only enabled sources count; a disabled or undetected source in `A`
contributes nothing (the orb shows it as unavailable).

- **Live value**: `live_A = Σ_{s ∈ A} live_s` (6.3 per source, `output` or `total` per the selected metric), which equals
  6.3 restricted to the responses and agents of `A` because the formula is additive. `liveEstimatedShare_A =
  Σ estimated_s / Σ (measured_s + estimated_s)` over `A` (0 when both are 0).
- **Agents**: the agents list (6.7) filtered to sources in `A`; an orb's dots are its agents in phase `generating`
  (order and cap as DESIGN 2). The hover line counts the filtered agents and `Σ_{s ∈ A} today.output_s` (6.6).
- **Events**: `responseCompleted` is delivered to every orb whose `A` contains the response's source.
- **`peakToday_A`**: the maximum over today of the 3-bucket trailing average of `Σ_{s ∈ A} measured_s[k]` (6.6),
  combined with the maximum `live_A` observed while running. It is kept in memory per orb, rebuilt from the per-source
  arrays after a relaunch (as `peakToday`) and reset at the day change. When an orb is created or its set `A` changes,
  `peakToday_A` is recomputed from the arrays (the live component restarts at that value).
- **`newPeak_A`**: the 6.4 rule applied to `live_A` against `peakToday_A` — exceeds it by at least 1 tok/s, is at least
  20 tok/s, and this orb emitted no `newPeak_A` in the last 60 seconds (live output, like 6.4, whatever the selected
  metric). After a create or a set change no `newPeak_A` is emitted for 60 seconds, so editing an orb never
  celebrates. For `A = all`, `newPeak_A` is `newPeak`.
- **Heat, tiers, titles**: computed by the UI from `live_A` with the orb's redline (DESIGN 1 and 2b), each orb with its
  own trackers.
- **Cost**: an orb showing the money unit (DESIGN 9) shows `liveCost_A = Σ_{s ∈ A, s billable} liveCost_s` and the
  known share over the same sources (9.5); its hover line uses `Σ todayCost_s` (9.6). Heat, titles and `newPeak_A`
  still use `live_A`.
- The history store (8) is unaffected: its `peak` stays the all-sources `peakToday`.

## 7. Number formatting (both platforms)

| Value | Display |
| --- | --- |
| `< 10` | one decimal (`4.2`); exactly 0 → `0` |
| `< 1000` | integer (`128`) |
| `< 10 000` | `1.28k` (two decimals) |
| `< 1 000 000` | `12.8k` / `128k` |
| `< 1 000 000 000` | `1.28M` / `12.8M` / `128M` |
| else | `1.28B` / `12.8B` / `128B` (three significant digits, more digits only above 999B) |

A value that rounds up to the next unit uses that unit (`999 700` → `1.00M`, `999 700 000` → `1.00B`). Token counts in
summaries use the same compact form (`1.2M`, `384k`, `2.49B`).
## 8. Daily history

Daily statistics are computed from the complete logs and kept permanently, so they survive tools deleting their own
logs (Claude Code removes transcripts after 30 days by default). Only aggregates are stored — never requests, keys in
plain text, prompts or content.

Scope: every discovered file of every enabled source with no date filter and no file-count limit (Codex `.jsonl.zst`,
all Gemini roots with legacy `.json`, every omp root including profiles, every Antigravity conversation database
of every store and both WorkBuddy roots included), plus Codex `archived_sessions` (the sibling of the sessions root) and the whole OpenCode
database. Parsing uses exactly the rules of section 4 (same state machines, dedupe, copied-history rules) over whole
files and complete database reads, in startup order (5; an Antigravity database's time is the newer of its `.db` and
`-wal`, 5.4).

Per local calendar day (date of `endMs`, `YYYY-MM-DD` in the computer's time zone at computation time) and source:
`requests`, `input`, `cachedInput`, `cacheWriteInput`, `output`, `reasoning`, `measuredOutput` and `measuredMs`
(sum of output and widened duration of measured responses, 3.3), `unfinalized` (count), `agents` (distinct agent ids
with at least one response), and per model `requests`, `output`, `measuredOutput` and `measuredMs` (so a model's average speed can be shown). The day's average speed is
`measuredOutput / (measuredMs / 1000)`. `peak` is stored only for days observed live: it is the day's overall
`peakToday` (all sources together), repeated on every source row of that day; a UI shows it only for all sources and
combines rows with max, never sum.

A response whose `endMs` is before `0001-01-03T00:00:00Z` or after `9999-12-29T23:59:59.999Z` (only broken timestamps
get there, 3.1, 3.6) has no date, since in some time zone it would fall outside the years 0001–9999: it is left out of
daily history and has no cost (it counts as unpriced, 9.3, 9.6), while it still counts in the live totals.

Incremental cache: for each file keep its identity (path, size, modification time; for an Antigravity database also
the size and modification time of its `-wal`), the 64-bit FNV-1a hashes of the
response keys it owns, and its per-day contributions. On launch and periodically (every 10 minutes and at midnight),
unchanged files reuse their contributions; new or changed files are re-parsed completely, skipping keys owned by any
other file (ownership follows startup order); files that no longer exist keep their contributions. Daily totals are
the sums over files. The history store is versioned: a parser change bumps the version and triggers a full
recomputation that keeps previously stored days for which no logs exist any more. "Clear history" (settings) deletes
the store and recomputes from the current logs.

Cost (9.7): every row also has `costMicroUsd` and `unpricedRequests`, every model `costMicroUsd` and
`unpricedRequests`, and every date a `priceVersion`. The cost feature bumps the store version; days kept from an
older store whose logs no longer exist have no cost data (`costMicroUsd` null, `unpricedRequests` null): UIs show
them as unavailable (DESIGN 9), never as 0.

Network traffic (10.9) is stored in its own table of the same database. It is observed, not derived from logs:
version bumps and recomputations never touch it, and "Clear history" deletes it too.

## 9. Cost

Agent Speed estimates what the counted responses would cost at the providers' official API list prices — the
*API-equivalent* cost (DESIGN 9). Costs are exact integers in US dollars; conversion to the display currency happens
only when a value is shown (9.8). `spec/tools/prices.py` implements 9.1–9.3 and 9.7; `reference.py` uses it for 9.5–9.7
and `--dump-history` / `--dump-today` (`--prices PATH` selects another table).

### 9.1 Price table

`spec/assets/prices.json` is bundled with every build and synced daily from this repository (NETWORK 3). The
*current* table is the higher `version` of the bundled table and the synced copy. `python3 spec/tools/prices.py`
validates it (the same rules apps apply to a download) and runs its `tests`.

| Field | Meaning |
| --- | --- |
| `schema` | `1`. A table with another schema is never used by a build that does not know it. |
| `version` | Positive integer, increased by one with every published change, never reused. |
| `updated` | `YYYY-MM-DD` of the change. |
| `currency`, `unit` | `"USD"`, `"perMillionTokens"`. |
| `providers` | key → `{name, url}`, `url` = the provider's official pricing page. |
| `normalize` | The lists used by 9.2. |
| `models[]` | `id` (lowercase, the provider's API id), `provider`, `name`, `status` (`current` · `preview` · `legacy` · `deprecated` · `retired`; retired models stay so that old days keep a price), either `prices` (with optional `tiers`, `offPeak`, `periods` and `fast`) or `"free": true`, optional `aliases`, `source` (https URL of the page the prices come from, or an archived copy of it for past prices), `checked` (date it was verified, ≤ `updated`), optional `note`. |
| `unknown[]` | `{match: "exact" \| "prefix", value, reason}`: ids known to have no public price (internal or opaque ids). |
| `tests[]` | `{model, provider?, expect}`: `expect` is a model id, `free` or `unknown` (9.2). |

**Price set**: `input` (uncached input), `cachedInput` (cache read; absent → `input`), `cacheWrite` (cache write with
the default lifetime, e.g. Anthropic's 5 minutes; absent → `input`), `cacheWrite1h` (1-hour cache write; absent →
`cacheWrite`), `output` (includes reasoning). Values are USD per million tokens, 0 – 10 000, with at most 6 decimals.
Implementations convert every price to the integer `p = price × 1 000 000` — micro-USD per million tokens, which is
pico-USD per token — by parsing the JSON number as a decimal, or by rounding `price × 1e6` to the nearest integer
(exact for at most 6 decimals).

**Tiers**: `tiers` = `[{above, …the same fields as prices}]`, `above` strictly ascending. The tier with the highest
`above` that is less than the response's `input` (3.2: all input, cached and cache writes included) replaces the
prices for the *whole* response. Thresholds are exclusive: "more than 200 000 tokens" is `above: 200000`, "200 000 or
more" is `above: 199999`.

**Periods**: `periods` = `[{from?, to?, prices, tiers?, offPeak?, note?}]`, at least one bound, never overlapping.
Bounds are UTC instants, `YYYY-MM-DD` (00:00 UTC) or `YYYY-MM-DDTHH:MMZ`; a period covers `from ≤ endMs < to`. A
response whose `endMs` lies in a period uses that period's `prices`, `tiers` and `offPeak` (absent = none) instead of
the model's. Periods carry announced future price changes, earlier prices for old days, promotions, and retired ids
that the provider bills at another model's price. Instants, not local dates, so every computer prices alike.

**Off-peak**: `offPeak` = `{peakUtc, peakWeekdays, offPeakDates?, prices, tiers?}` (DeepSeek bills half price outside
its peak hours). A response is at peak when the UTC date of its `endMs` is not in `offPeakDates`, its ISO weekday (1 =
Monday) is in `peakWeekdays`, and its UTC time of day lies in one of the `peakUtc` windows (`HH:MM-HH:MM`, start
inclusive, end exclusive). Otherwise it uses the `offPeak` prices and tiers.

**Fast mode**: `fast` = `{prices, tiers?}`, used instead of everything above (periods and off-peak included) for a
response with `fast` (3.2) or an id that selects fast mode (9.2). A fast response of a model without `fast` prices
has an unknown cost: never the cheaper standard price.

**Free**: `"free": true` — every response of the model costs 0, a known value.

### 9.2 Model resolution

Input: a response's `model` and `provider` (3.2). Result: a priced entry, `free` or `unknown`. No fuzzy matching:
everything these rules do not reach needs an explicit alias.

1. `provider`, trimmed and lowercased, is in `normalize.freeProviders` (local runtimes: `ollama`, `lmstudio`,
   `llama.cpp`, …) and the lowercased model does not end with an entry of `cloudSuffixes` (Ollama Cloud models run
   remotely) → **free**. A base URL is never used: local proxies to paid APIs exist.
2. Missing or empty model → **unknown**.
3. Candidate keys, formed in this order, each one looked up as soon as it is formed; the first hit wins. A key equal to
   an `id` or alias resolves to that entry (`free` when the entry is free); otherwise a key that equals an `exact`
   `unknown` value or starts with a `prefix` one is **unknown** with its reason.

   | Step | Key | Example |
   | --- | --- | --- |
   | exact | remove every `[…]` group, collapse whitespace, trim, lowercase | `claude-opus-5-5[1m]`, `Claude-Opus-5-5` → `claude-opus-5-5` |
   | route | the part after the last `/` | `anthropic/claude-sonnet-4.5` → `claude-sonnet-4.5`; `models/gemini-2.5-pro` |
   | cloud | `<region>.` (from `bedrockRegions`) is removed when a `<vendor>.` (from `bedrockVendors`) follows; a leading `<vendor>.` is removed and then a trailing `-v<N>` or `-v<N>:<M>`; a trailing `@YYYYMMDD` becomes `-YYYYMMDD`, any other trailing `@…` is removed | `us.anthropic.claude-sonnet-4-5-20250929-v1:0` → `claude-sonnet-4-5-20250929`; `claude-opus-5-5@default` → `claude-opus-5-5` |
   | free | the key ends with an entry of `freeSuffixes` (and is longer) → **free**, no lookup | `deepseek-v4.1-flash-free`, `…:free` |
   | variant | remove entries of `variantSuffixes` at the end, repeatedly | `gpt-5.5:nitro:exacto` → `gpt-5.5` |
   | rewrite | the first `rewrites` entry whose `prefix` starts the key replaces that prefix with `to` | `duo-chat-sonnet-5-5` → `claude-sonnet-5-5` |
   | fast | a key ending with an entry of `fastSuffixes` loses it and selects fast mode for this and every later step: a hit on an entry with `fast` prices is priced in fast mode, a hit on an entry without them is **unknown** | `claude-opus-5-5-fast` → `claude-opus-5-5` (fast); `claude-sonnet-5-5-fast` → unknown |
   | date | for keys starting with an entry of `dateSuffixPrefixes`, remove a trailing `-` and 8 digits | `claude-sonnet-4-5-20250929` → `claude-sonnet-4-5` |
   | modifier | for the first `modifierSuffixes` entry whose `prefix` starts the key, remove its suffixes at the end repeatedly, as long as more than the prefix remains | `claude-opus-5-thinking-max` → `claude-opus-5`; `gemini-3.1-pro-high` → `gemini-3.1-pro` |
   | dotHyphen | for keys starting with an entry of `dotHyphenPrefixes`, replace every `.` by `-` | `claude-opus-4.8` → `claude-opus-4-8` |

4. No hit → **unknown**.

The lists are data, so a synced table can extend them. The rules are scoped on purpose: elsewhere a date or suffix is
a different model at a different price (`gpt-4o-2024-05-13` $5/$15 vs `gpt-4o` $2.5/$10, `mistral-large-2411` vs
`-2512`, `qwen3-max`, `gpt-5.5-pro`), so none of those is stripped; `-fast` is tried only after the full id (so
`grok-4-fast`, a model of its own, matches first) and never falls back to the standard price.
`-latest` and display names (`Gemini 3.1 Pro (High)`) resolve only through aliases. The validator checks that every
id and alias resolves to its own entry, so a rule can never shadow an alias. Examples: `spec/fixtures/price-cases.json`
`resolve` and the table's `tests`.

### 9.3 Response cost

Billed token classes of a response (3.2):

- `uncached = max(0, input − cachedInput − cacheWriteInput)`
- `cacheRead = cachedInput`
- `write1h = min(cacheWrite1hInput, cacheWriteInput)`, `write = cacheWriteInput − write1h`
- `output` (reasoning included; every source counts reasoning inside `output`)

Each class is clamped to 100 000 000 tokens (no real response comes near; it keeps the sum below 2^63 with prices up
to 10 000 USD per million tokens).

With the price set of 9.1 — fast prices for a fast response, else the period covering `endMs`, then its off-peak
prices when `endMs` is off-peak, then the tier chosen by `input` — in 64-bit integers:

```
costPicoUsd  = uncached·p_input + cacheRead·p_cachedInput + write·p_cacheWrite + write1h·p_cacheWrite1h + output·p_output
costMicroUsd = (costPicoUsd + 500 000) div 1 000 000          (half up)
```

`costMicroUsd` is *the* cost of the response everywhere — live rate, today, history, CSV — so every total is a sum of
integers and any grouping (per file, day, source, model) gives the same number. Free → 0. Unknown → no cost (null),
never 0: it is counted in `unpricedRequests` instead. A response without a date (8) has no cost either. The cost is
computed when a response is emitted and again when an update replaces it (4.4), with the table of its date (9.7);
periods and off-peak hours follow its `endMs`. Cases: `spec/fixtures/price-cases.json` `cost`.

### 9.4 Subscriptions

Settings can mark sources as used through a subscription (DESIGN 9). Costs of every source are always computed and
stored; marks apply only when values are shown: with `includeSubscriptions` off (the default) every displayed cost
(live, today, orb, history totals) sums only the *billable* sources, the ones not marked; with it on, all sources. A
mark is a current setting, not data: changing it rewrites nothing.

### 9.5 Live cost rate

The money unit of the orb, menu bar and dashboard (DESIGN 9). Window, intervals and estimates are those of 6.3.

- Measured: for every measured response with a known cost, `costMicroUsd * overlap(interval, [start', end]) /
  (end - start')`.
- Estimated: for every unmeasured response and every in-flight agent that 6.3 estimates, with the same `secs`
  (`overlap / 1000`), add `costRate(a) * secs`. `costRate(a)` = Σ `costMicroUsd` / Σ widened duration (seconds) over
  the responses of `a`'s *reference set* that have a known cost; the reference set is the set 6.2 used for
  `estimatedSpeed(a)` (the agent's up to 3 most recent measured responses within 10 minutes, else the model's up to 10
  within 30 minutes, else the source's). No cost estimate when none of them has a known cost.
- `liveCost = (measured + estimated) / (W / 1000)` micro-USD per second.
- `liveCostKnownShare` = the output tokens of 6.3 (measured and estimated) that carry a known cost ÷ all of them (1
  when there are none): a measured response counts when its cost is known, an estimate when `costRate` exists.
- Per source and per agent: the same formula restricted to them. Both values are additive over sources, so an orb or
  the billable sum (9.4) adds per-source values: `knownShare = Σ known tokens / Σ tokens`.
- The money value never drives heat, tiers, titles, peaks or `newPeak`; those follow the token metric.

Engine cases with `liveCost` in `spec/fixtures/engine-cases.json` give responses their `costMicroUsd` directly.

### 9.6 Today

- `today.costMicroUsd`: Σ `costMicroUsd` of today's responses with a known cost, as recorded (unfinalized ones
  included, so it is a lower bound like `output`).
- `today.unpricedRequests`: today's responses without a known price.
- Both per source, and per model for breakdowns. The dashboard's today cost equals the history's row for today.

### 9.7 Day binding and history

Each day reads like a bill: it keeps the prices that applied to it.

- **Binding**: the history store keeps `date → table version` for every local date that has been priced. The first
  time a response of a date is priced (by the engine or by the history analysis), the date is bound to the current
  table version. A binding never changes afterwards — not when a newer table arrives, not when a changed file is
  re-analysed, not on a full recomputation after a store version bump.
- **Pricing a response of date `d`**: with the table bound to `d` (its periods and off-peak hours apply by `endMs`). If that table
  cannot price it (`unknown`), the current table is used instead (*late pricing*): a new model added to the table later
  fills in the days before, while a price that was known never changes. Still unknown → unpriced.
- A price change in a new table therefore shows from the next day on (today stays bound); a change announced in
  advance takes effect on time when the bound table already carries it as a period.
- **Re-analysis**: per-day contributions of a re-analysed file are recomputed with these rules, so they are a pure
  function of the file's responses, the bindings and the stored tables. When the current table version changes, every
  file whose stored contribution has `unpricedRequests > 0` is re-analysed (as if it had changed), and the engine
  re-prices today's unpriced responses; it keeps the normalized usage of today's unpriced responses (at most 10 000)
  for that.
- **Storage**: the store keeps a copy of every table version that a binding references (deleted when no binding
  references it). A binding whose table is missing or invalid is replaced by the current version (logged). "Clear
  history" deletes bindings and tables with everything else.
- **Rows** (section 8): per date and source `costMicroUsd` (Σ known costs) and `unpricedRequests`; per model the same
  two; `priceVersion` = the date's binding (repeated on each row of the date). Subscription marks are not stored.
- Fixtures: `spec/fixtures/history-expected.json` `prices` (the fixture tables, the highest version current, and the
  bindings to load before the analysis) and `spec/fixtures/price-cases.json` `days`.

### 9.8 Display currency

Costs are stored and summed in micro-USD. A shown amount is `costMicroUsd / 1 000 000 × rate(currency)`, with the
latest accepted daily rate (NETWORK 4; USD = 1). History days are converted with that same latest rate, not the rate
of their own day: a range total then always equals the sum of its days, switching currencies changes no stored data,
and no historical rates are needed. The UI states the rate date (DESIGN 9). Rounding and formatting are DESIGN 9.

### 9.9 Known approximations

- List prices only: subscriptions, free tiers and credits, enterprise discounts, batch, flex and priority tiers,
  regional or data-residency surcharges (for example Bedrock regional endpoints and Vertex regions, +10 % on newer
  Claude models) and taxes are not modeled.
- Charges that are not tokens of a recorded response are not counted: web search and fetch requests, code execution,
  grounding, cache storage per hour, image and audio inputs priced differently from text.
- Calls an agent does not record (titles, compaction summaries, classifiers; 4.x approximations) are missing, so costs
  are lower bounds, like tokens. Unfinalized Claude Desktop responses count with their recorded usage (complete input,
  partial output).
- Only Claude Code separates 1-hour cache writes; every other source prices all cache writes at `cacheWrite`
  (OpenAI's 12-hour writes, 2.5× input, are priced as its 30-minute writes, 1.25×).
- Fast mode is known only for Claude Code (`usage.speed`) and for ids that name it (`-fast`); OpenAI's fast and
  ultrafast tiers in Codex are priced at standard rates. US-only inference (`usage.inference_geo == "us"`, 1.1× on
  newer Claude models) is not applied.
- DeepSeek's off-peak rule needs the list of Chinese public holidays in `offPeakDates`; weekend make-up workdays are
  treated as off-peak. Qwen's implicit-cache price (20 % of input) is used for every cache read, explicit caching
  (10 %) is not distinguished.
- A tier is chosen by the normalized `input`; for Gemini CLI that includes tool-use prompt tokens.
- OpenCode and omp record their own cost; it is not used, so every source follows one rule (resellers such as
  OpenCode Zen sometimes charge other prices than the original provider).
- Models behind a user's own proxy or router are priced by the model name the agent logged; opaque names stay unknown.
- WorkBuddy bills in credits, which are not used; calls through its routing slots stay unpriced unless the stream names
  the model it chose (4.9).

## 10. Network traffic

Agent Speed also measures network traffic: the whole computer's live upload and download speed, and how many bytes
each source (and, where it can be told apart, each agent) sends and receives. Only byte counts are read — never
content, addresses, ports or host names — and nothing leaves the computer. Display rules are DESIGN 10; the Windows
helper service is `spec/WINDOWS-SERVICE.md`. `spec/tools/traffic.py` implements 10.4–10.9 and 10.11 (10.5 and 10.6
from recorded process tables and agent activity) and checks `spec/fixtures/traffic-cases.json`; both apps run the same
cases through their own sampler-independent core.

### 10.1 Vocabulary

| Term | Meaning |
| --- | --- |
| `rx` / `tx` | Bytes received (download, ↓) / sent (upload, ↑). Unsigned 64-bit counters, deltas and totals in bytes. |
| Machine traffic | Bytes on the computer's physical network interfaces (10.2), all programs together. Includes protocol headers and VPN encryption overhead. |
| Process traffic | Bytes of one process's TCP and UDP sockets on non-loopback interfaces (10.3): transport payload, including TLS and QUIC framing, excluding IP/TCP headers. |
| Agent process | A process that runs a source (10.5). Its *tool processes* are all its descendants that are not agent processes themselves. |
| Self / tools | A source's traffic is split into `self` (its agent processes) and `tools` (their tool processes). |
| Agent traffic | Traffic attributed to one agent tree (6.7) by 10.6; best effort. |

### 10.2 Machine counters

Read on every sampling tick (10.4), cumulative 64-bit counters per interface.

- **macOS**: `sysctl {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0}`, `RTM_IFINFO2` messages, `if_msghdr2.ifm_data`
  (`struct if_data64`: `ifi_ibytes`, `ifi_obytes`). Not `getifaddrs`, whose `if_data` counters are 32-bit and wrap
  every 4 GiB (34 s at 1 Gbit/s). One call costs ≈ 0.14 ms (measured, 40 interfaces). Since at least macOS 26 the
  values an unprivileged process sees move in steps of 1 KiB (observed on macOS 27.0.1: every counter is a multiple of
  1024), which is below display precision. Counted interfaces: the BSD names of `SCNetworkInterfaceCopyAll()` (the
  hardware ports of System Settings → Network: Wi-Fi, Ethernet, Thunderbolt, USB and iPhone tethering, …) except
  interfaces of type Bridge, Bond and VLAN (their member or parent interfaces already carry the bytes), and only while
  `IFF_UP` and `IFF_RUNNING`. The list is refreshed on a SystemConfiguration network-change notification and every
  60 s. Not counted: `lo0`, `utun*`/`ipsec*`/`ppp*` (VPN tunnels: the tunnelled bytes are counted once, encrypted, on
  the physical interface), `awdl0`/`llw0` (AirDrop and other peer-to-peer links), `bridge*`, `vmenet*`/`feth*` (virtual
  machines, whose internet traffic leaves through a physical interface), `anpi*`, `gif0`, `stf0`.
- **Windows**: `GetIfTable2Ex(MibIfTableNormal)` rows with `InterfaceAndOperStatusFlags.HardwareInterface` set and
  `FilterInterface` and `EndPointInterface` clear, `Type` not `IF_TYPE_SOFTWARE_LOOPBACK` or `IF_TYPE_TUNNEL`,
  `TunnelType == TUNNEL_TYPE_NONE`, `OperStatus == IfOperStatusUp`; `InOctets` / `OutOctets`. This excludes NDIS
  filter-module duplicates of the same adapter, Hyper-V/WSL/VMware virtual adapters, WAN miniports (VPN), Bluetooth
  PAN and Teredo/6to4/IP-HTTPS tunnels (verified against `Get-NetAdapter -IncludeHidden` on the test machine). The
  table decides the counted set; between table reads each tick reads only the counted rows, one `GetIfEntry2` per
  `InterfaceLuid` (10.10). The table is read again every 10 s and as soon as a counted row fails or is no longer up.
- An interface is identified by its BSD name (macOS) or `InterfaceLuid` (Windows).

Machine counters need no permission and work whether or not process traffic is available.

### 10.3 Process counters

- **macOS**: one long-running child process
  `/usr/bin/nettop -P -L 0 -s <interval> -x -n -t external -J bytes_in,bytes_out` (interval 10.10). `nettop` ships
  with every macOS since 10.7 and carries Apple's private `com.apple.private.network.statistics` entitlement, which a
  third-party app cannot obtain; it is the only supported way for an unprivileged app to read every process's
  counters. Requirements, all verified on macOS 27.0.1 (M5 Pro):
  - **stdin** must be an open pipe that is never written (or a terminal). With `/dev/null` nettop busy-loops at
    ≈ 120 % of a core.
  - **stdout and stderr** must be a pseudo-terminal (`openpty`), and it must be the child's **controlling terminal**
    (new session, `TIOCSCTTY`). On a pipe, nettop buffers its output until it exits, so no sample arrives while it
    runs; without a controlling terminal, a crashed parent leaves nettop spinning at ≈ 126 % of a core instead of
    receiving SIGHUP.
  - Environment `LC_ALL=C`; the child is in its own process group and is killed with the app.
  - Output: each sample starts with a header line beginning with `,` (`,bytes_in,bytes_out,`); every following line
    until the next header is `<name>.<pid>,<bytes_in>,<bytes_out>,`. The pid is the digits after the last `.` of the
    first field (names are the 15-character kernel name and may contain `.` and spaces; they are never used). Columns
    are located by header name; a line that does not parse is skipped. Values are plain integers (`-x`).
  - Semantics: per-process totals since the process started, including connections that already closed (a process
    that opened three connections one after another showed one growing total), TCP and UDP; `-t external` excludes
    loopback (a 20 MB transfer over `127.0.0.1` appeared only without it). An exited process stays in the output for
    2–3 samples with its final totals, so its last bytes are not lost at 1 Hz.
  - `-d` (delta mode) is not used: its first sample is neither a delta nor a total, and deltas are computed by the app
    anyway (10.4). One-shot runs (`-L 1` every second, as some monitors do) cost ≈ 50 ms of CPU each (5 % of a core at
    1 Hz) versus ≈ 16 ms per sample when streaming.
  - Health: no complete sample for 10 s, an exit, or 10 consecutive unparseable samples → restart after 1, 2, 4 … 60 s;
    5 restarts within 10 minutes → `processTraffic = unavailable(sampler)` until the next app launch or a manual retry.
    `/usr/bin/nettop` missing or not executable → `unavailable(sampler)`.
  - The private `NetworkStatistics.framework` (what nettop and Activity Monitor use) is not used directly: private
    API, private entitlement, unversioned kernel structures.
- **Windows**: the traffic helper service (`spec/WINDOWS-SERVICE.md`): per (pid, create time) cumulative `rx`/`tx`
  since the service first saw the process, for the processes of the user's session, plus the service `epoch`.
  Unavailable states: `helperNotInstalled`, `helperStopped` (could not be started), `helperOutdated`, `helperDenied`,
  `helperError`.
- **Process identity** everywhere is (pid, start time): macOS `proc_pidinfo(PROC_PIDTBSDINFO)` `pbi_start_tvsec/usec`;
  Windows `GetProcessTimes` creation time, which equals the helper's `createTime` (both are the kernel's process
  create time). A counter row whose identity does not
  match the app's process table entry for that pid is ignored for that sample.

### 10.4 Sampling and deltas

Sampling runs while `trafficEnabled` is on (DESIGN 10, default on). All times below are monotonic except where a local
date is needed.

1. **Tick**: every 1000 ms the app reads the machine counters (10.2), refreshes its process table (10.5) when 10.10
   says so and applies the newest process-counter sample (nettop's latest complete sample, or a helper snapshot when one
   is due). Sample time = the tick's time.
2. **Delta** of one counter key (interface, or process identity) between consecutive values `prev` → `cur`:
   - `cur ≥ prev` → `d = cur − prev`;
   - `cur < prev` (counter reset: interface re-created, helper restarted, nettop restarted) → `d = 0` and the new value
     becomes the baseline;
   - `d` greater than `12.5 GB/s × Δt` (100 Gbit/s) → treated as a reset (`d = 0`).
3. **First sight** of a key. Interfaces: always a baseline (`d = 0`; an interface that comes up may carry older
   counts). Processes: in the **first sample of a stream** every process is a baseline, so processes that were running
   before sampling started never add a burst. A stream starts at launch, when sampling is turned on, when nettop is
   started again after a failure, and on every new connection to the helper (WINDOWS-SERVICE 4); restarting nettop
   for an interval change (10.10) continues the stream. A process that first appears later in a running stream has
   `d = cur`: nettop lists a process only once it has used the network and the helper only after its first counted
   event, so all of it is new (a short tool run is not lost).
4. **Disappearance**: a key absent from three consecutive samples is forgotten (its last delta was already counted).
5. **Gaps**: when `Δt > 15 s` (sleep, a stalled sampler) the deltas are still added to totals — the bytes are real —
   but not to the live-rate series, and the rate window (10.7) restarts.
6. **Day**: a delta belongs to the local date of its sample time; deltas after local midnight start the new day.
7. **Continuing a stream** across a nettop restart keeps the process baselines: nettop reports totals since process
   start, so the first sample of the new child continues the same counters.

### 10.5 Attribution: processes → sources

The app keeps a **process table** of the current user's processes (on Windows: of the app's session), refreshed on the
ticks 10.10 gives: pid, parent pid, start time,
executable path and, only for script hosts (`node`, `bun`, `deno`, with or without `.exe`) and WorkBuddy's
executables (below), the argument list; on macOS, for WorkBuddy, also the bundle id of the app whose `Contents/MacOS`
holds the executable (`CFBundleIdentifier` of its `Contents/Info.plist`, read once per app path).
macOS: `proc_listallpids`, `proc_pidinfo(PROC_PIDTBSDINFO)`, `proc_pidpath`, `sysctl(KERN_PROCARGS2)`. Windows: one
`NtQuerySystemInformation(SystemSessionProcessInformation)` listing of the session (pid, parent pid, create time; no
handles opened; `SystemProcessInformation` filtered by session where the session listing fails), then, once per new
identity, `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)` with `GetProcessTimes` (the handle's create time must match
the listing), `QueryFullProcessImageNameW` and `NtQueryInformationProcess(ProcessCommandLineInformation)` (Windows
8.1+). Path
and arguments are read once per process identity; an exited process stays in the table for 10 s, so the counter rows
that still list it (10.3) can be matched. Paths compare with `/` and `\` equivalent, case-insensitively on Windows;
`~` is the home folder. File **names** compare case-sensitively on both platforms, without the `.exe` extension: the
command-line tools are lower-case (`claude`, `codex`, `opencode`), while the desktop apps' own executables are
capitalized (`Claude.exe`, `Codex.exe`, `OpenCode.exe`) and are never agent processes (below). WorkBuddy is the one
desktop app that runs its agent on its own executable, so its row needs the argument list.

**Agent processes** (first matching row; `name` = executable file name without `.exe`):

| Source | Agent process |
| --- | --- |
| `claudeDesktop` | `name == claude` and the executable lies under Claude Desktop's bundled Claude Code folder (macOS `~/Library/Application Support/Claude/claude-code/`; Windows `%LOCALAPPDATA%\Claude\claude-code\`, `%LOCALAPPDATA%\Claude-3p\claude-code\`, `%APPDATA%\Claude\claude-code\`), or `name == claude` with an ancestor that is the Claude Desktop app (`/Applications/Claude.app/Contents/MacOS/Claude`, bundle id `com.anthropic.claudefordesktop`; Windows `Claude.exe` of the `Claude_*` package or `%LOCALAPPDATA%\AnthropicClaude`). Observed: macOS `Claude → disclaimer → …/claude-code/2.1.308/<hash>/claude.app/Contents/MacOS/claude`, one per Code session; Windows `Claude.exe → %LOCALAPPDATA%\Claude-3p\claude-code\2.1.299\<hash>\claude.exe`. |
| `claudeCode` | `name == claude` (native installer `~/.local/bin/claude` → `~/.local/share/claude/versions/<version>` — matched by that folder, since the file name is the version —, Homebrew, IDE extensions' `native-binary/claude`), or a script host whose first script argument contains `@anthropic-ai/claude-code/`. Not a process whose arguments contain `--chrome-native-host` (the Claude in Chrome bridge, a child of the browser). |
| `codex` | `name == codex` or `name` starts with `codex-` followed by a target triple or `x86_64`/`aarch64` (npm-vendored binaries), or a script host running `@openai/codex/bin/codex.js`. Covers the CLI, `codex app-server` started by the Codex app (macOS `…/codex-cli/CodexCLI.app/Contents/MacOS/codex`, Windows `%LOCALAPPDATA%\OpenAI\Codex\bin\<hash>\codex.exe`) and IDE extensions, and the app-server daemon (`~/.codex/packages/app-server-daemon/…/codex`). |
| `deepseek` | `name == dsh`; the DeepSeek Harness desktop app's main process (macOS bundle id `com.deepseek.dsh`, `DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness`; Windows `DeepSeek Harness.exe`). Not verified with a running session: which process makes the model calls is unknown, so the whole app tree counts. |
| `opencode` | `name` in `opencode`, `opencode-cli` (desktop sidecar `opencode-cli serve`), or starting with `opencode-` followed by an OS and architecture (npm-vendored); or a script host running `opencode-ai/bin/opencode`. |
| `gemini` | A script host whose arguments contain `/@google/gemini-cli/` (npm, Homebrew `…/libexec/lib/node_modules/@google/gemini-cli/…`), or `name == gemini` for a native build. Gemini CLI relaunches itself as a child; the child is a descendant either way. |
| `omp` | `name == omp`, or a script host whose arguments contain `/@oh-my-pi/` or `/oh-my-pi/`. |
| `antigravity` | `name == agy`, or `name` starts with `language_server_` (the Antigravity language server, started by the CLI, the desktop app and the IDE with `--app_data_dir`). |
| `workbuddy`, `workbuddyAi` | The embedded CodeBuddy Code CLI, which makes the model calls itself: an executable of the edition — macOS: in the app with bundle id `com.tencent.workbuddy.mac` (WorkBuddy) or `com.workbuddy.workbuddy-ai` (WorkBuddy AI), whose main executable is named `Electron`; Windows: `name` `WorkBuddy` or `WorkBuddyAI` — whose arguments after the first contain a path with `/app.asar.unpacked/cli/` (the CLI entry `…/app.asar.unpacked/cli/bin/codebuddy`, run with `ELECTRON_RUN_AS_NODE`). Observed in the 5.8 code: pooled `--prewarm` processes that later serve one conversation each (`--serve --session-id <id>`; the command line does not change when one is taken from the pool), cold `--serve` starts, and the fallback `--acp` with first argument `wb-acp:<id>`. Not verified with a running app; the Windows install folder is unknown, so only the name is used. |

The desktop apps' own processes are **not** agent processes, nor are their Electron or Tauri helpers: macOS
`/Applications/{Claude,ChatGPT,Codex,OpenCode,Antigravity}.app/Contents/MacOS/<name>`; Windows executables in the
`WindowsApps\Claude_*`, `WindowsApps\OpenAI.Codex_*` and `WindowsApps\OpenAI.ChatGPT*` package folders and in
`%LOCALAPPDATA%\AnthropicClaude\`. Their own traffic (chat UI, updates, telemetry) is outside the sources' scope, like
Claude Desktop chats are in section 2; only the agent processes they start count. DeepSeek Harness is the exception
above. WorkBuddy's main process, its helpers, renderers and its daemon (the same executable running
`app.asar/main/daemon-app-server-entry.js`, which starts the CLI processes) are app processes like these, so the
CLI processes are roots and their children are their tools.

**Ancestry**: a process's parent is the table entry with its parent pid whose start time is not later than its own
(otherwise the link is broken: the pid was reused). The **nearest** ancestor-or-self that is an agent process decides:

- the process itself matches a row and has no agent ancestor of the same source → it is an agent process (a root);
- it matches a row but its nearest agent ancestor is of the same source → it is part of that agent process (a
  wrapper's native child, Gemini's relaunch): counted as `self` of the ancestor's root;
- it matches a row of a different source → it is an agent process of its own source (an agent run as another agent's
  tool counts for itself);
- otherwise, if it has an agent ancestor → a tool process of the nearest one (`tools`);
- otherwise → not attributed (it is still part of machine traffic).

Attribution is decided when a process is first seen and kept for its lifetime: a tool whose parent exits (reparented
to launchd or orphaned) stays with its agent. A process that detaches before the first tick that sees it cannot be
linked (known approximation, 10.12).

`includeTools` (DESIGN 10, default on) chooses whether displayed source and agent values include `tools`; totals and
history always keep `self` and `tools` separately, so the setting changes no stored data.

**Disabled sources** (Settings → Data Sources, DESIGN 5) are attributed, counted and stored like the others: bytes,
unlike transcripts, cannot be read again later, so a source turned back on shows its traffic for the days it was off,
as it shows its tokens. Every view leaves a disabled source out (DESIGN 10) — its live rates, today's bytes, its
sparkline and its history rows, and every sum shown over sources (orbs, menu bar and taskbar, dashboard, history
chart, table and CSV) — so it shows no traffic anywhere, as it shows no tokens. This computer's traffic (10.2) is
unaffected.

### 10.6 Attribution: agent processes → agents (best effort)

Per-agent traffic attaches to **agent trees** (the roots of 6.7 with their sub-agents: sub-agents run inside their
parent's process). Each tick, for every root agent process `P` of source `s` with a non-zero delta (self or tools):

1. **Candidates**: the agent trees of source `s` that are *active* during the tick interval: some member is in phase
   `generating` or `tools` (after the 6.7 staleness rule), or has `lastLineMs ≥ intervalStart − 2000`.
2. **Open-file evidence** (macOS only: `proc_pidinfo(PROC_PIDLISTFDS)` and `PROC_PIDFDVNODEPATHINFO`, refreshed every
   10 s for agent processes): if `P` or a process counted as part of it (10.5, `self`) has the transcript (or
   database) of a member of one or more candidates open, keep only those. Codex app servers keep their rollout files
   open (observed: two `rollout-….jsonl` held by one app server); Claude Code, Gemini CLI and omp do not.
3. **Working-directory evidence**: if `P`'s working directory is known and some candidates' root `cwdPath` (below)
   equals it, keep only those. macOS: `proc_pidinfo(PROC_PIDVNODEPATHINFO)` `pvi_cdir`, read once per process
   (observed: Claude Code and Claude Desktop's Code-session CLIs run in the project folder; Codex app servers in `/`).
   Windows: optional — `NtQueryInformationProcess(ProcessBasicInformation)` and `ReadProcessMemory` of
   `RTL_USER_PROCESS_PARAMETERS.CurrentDirectory` (same-user processes only; an undocumented but long-stable layout);
   when not implemented or not readable the directory is unknown and this step is skipped.
4. Each step applies only if it leaves at least one candidate. If exactly **one** candidate remains, the interval's
   deltas of `P` and its tools belong to that agent tree; otherwise they stay with the source only (counted in the
   source's `unassigned` share).

`cwdPath` is new parser metadata (section 4): the full working directory the transcript names — Claude: the latest
`cwd`; Codex: `session_meta`/`turn_context` `cwd`; dsh: header `cwd`; OpenCode: `session_v2.directory`; Gemini CLI: the
`.project_root` content; omp: header `cwd`; Antigravity: the decoded path of the first workspace URI; WorkBuddy: the
latest `cwd`. Null when absent.
It is metadata only (no effect on tokens or history).

Typical outcomes: one Claude Code session per terminal → exact; several Claude Desktop Code sessions (one CLI process
each, own project folder) → exact; two sessions of one tool in the same folder working at the same time → source
only; a Codex app server, OpenCode server or Antigravity language server serving several conversations → exact while
one conversation is active, else source only; WorkBuddy (one CLI process per conversation, but a pooled process starts
before its conversation, so its working directory need not match) → exact while one conversation is active, else
source only.

### 10.7 Live rates

- For a series of deltas (machine; each source with self and tools; each agent tree), the live rate is
  `Σ deltas of the samples in (t − 3000 ms, t] ÷ ((t − t₀) / 1000)`, where `t` is the latest sample time and `t₀` the
  latest sample time ≤ `t − 3000` (or the first sample of the series when none). With 1 Hz sampling this is the mean of
  the last three intervals — the same 3-second window as the token live rate (6.3). Before two samples exist the rate
  is unknown (null). Separate for `rx` and `tx`.
- Values update once per sample (1 Hz); UIs never interpolate between samples.
- **History buffer**: one-second buckets for the last 300 s (as 6.5), per direction, for the machine and per source
  (self + tools), for sparklines. A bucket holds the bytes of the sample whose interval ends in it ÷ interval seconds.

### 10.8 Today

`todayStartMs` as 6.6. Sums of deltas whose sample time is today:

- `machine`: `rx`, `tx`, `sampledMs` (sum of intervals ≤ 15 s between consecutive machine samples).
- per source: `rxSelf`, `txSelf`, `rxTools`, `txTools`, `unassignedRx`, `unassignedTx` (the part, self and tools,
  not attributed to an agent tree), and `processSampledMs` (sum of intervals ≤ 15 s between consecutive process
  samples of one stream; the first sample of a stream adds nothing).
- per agent tree (memory only, not stored): `rxSelf`, `txSelf`, `rxTools`, `txTools` attributed today while running.
- On day change everything restarts at zero; a relaunch restores machine and source values from the history store
  (10.9), agent values start at zero.
- Kept for every source, enabled or not; views show and sum only the enabled ones (10.5).

### 10.9 Daily history

Traffic is observed, not read from logs: there is no history before sampling started, and it cannot be recomputed.

- **Store**: a new table in the history database (section 8), created if missing every time the database is opened (the schema
  version does **not** change, so older builds can still open the file; the analysis version does not change either,
  so nothing is re-analysed):
  `day_traffic(day TEXT, key TEXT, rx INTEGER, tx INTEGER, rx_tools INTEGER, tx_tools INTEGER, sampled_ms INTEGER,
  PRIMARY KEY (day, key)) WITHOUT ROWID`. `key` is a source (section 1), whose `rx`/`tx` are `self` and
  `rx_tools`/`tx_tools` are `tools`, or `machine` (`rx_tools` and `tx_tools` are 0). `sampled_ms` is the machine
  `sampledMs` on the `machine` row and `processSampledMs` on source rows. The meta key `trafficSince` holds the first
  local date with a stored sample.
- **Writes**: today's in-memory totals are written (upsert) every 60 s, at the day change, before sleep and at quit;
  a crash loses at most 60 s. Readers merge the unsaved part, so today's dashboard values equal today's history row.
- **Recomputation and clearing**: section 8's version bumps and full recomputations never touch `day_traffic` (like
  `day_peaks`). "Clear history" deletes it with everything else (DESIGN 10 says so in the confirmation). Older builds
  ignore the table.
- **Rows shown**: a date before `trafficSince` has no traffic data (UIs show it as not recorded, never 0); a date with
  `sampled_ms` below its elapsed time is partial (UIs say how long it was recorded).
- CSV export columns: DESIGN 10.

### 10.10 Sampling intervals and CPU budget

- Machine counters: every tick (1 Hz) while traffic sampling is on. Cost: ≤ 0.02 % of one core. macOS reads every
  interface in one `sysctl` (10.2). Windows reads each counted interface by its `InterfaceLuid` (`GetIfEntry2`: ≈ 0.2 ms
  wall, no measurable CPU) and reads the whole table (`GetIfTable2Ex`) only every 10 s and when a counted row fails or
  goes down: the table call asks every adapter and NDIS filter driver for its statistics, ≈ 0.8 ms of CPU and ≈ 100 ms
  wall per call (measured on the test machine, 47 rows), so reading it every second alone would cost 0.08 % of one
  core, four times the budget; every 10 s it costs 0.008 %. A new interface (Wi-Fi joined, tethering) is counted within
  10 s.
- Process counters (macOS nettop child), measured on the M5 Pro with ≈ 760 open sockets: ≈ 1.6 % of one core at
  `-s 1` (≈ 15 ms per sample plus ≈ 0.25 % fixed), ≈ 0.5 % at `-s 5`, 1.0 % at `-s 2`; memory 5 MB. To stay near the
  app's budget the interval adapts:
  - no agent process in the process table → nettop is not running (0 %);
  - agent processes exist, but no agent is active (10.6) for 60 s and no visible surface shows per-source or per-agent
    traffic → `-s 5`;
  - otherwise → `-s 1`.
  An interval change restarts nettop (≈ 50 ms of CPU) and happens at most once per 30 s; bytes are never lost by it
  (10.4.7), only the rate resolution changes.
- Windows helper: ≈ 0.1 % of one core at normal desktop traffic, < 1 % at 1 Gbit/s (WINDOWS-SERVICE 3). It counts every
  event and has no interval; the same three states decide how often the app asks it for a snapshot: never (the
  connection closes and the service stops itself after 120 s), every 5 s, or every second. Its counters are cumulative,
  so a slower poll loses no bytes, only rate resolution.
- App side (process table, parsing, attribution): ≤ 0.2 % of one core at 1 Hz with 800 processes; path and argument
  reads only for new processes. macOS lists every tick, and every 2 s while nettop is not running (only to notice agent
  processes).
- Windows process table: one listing of the session costs ≈ 1.6 ms of CPU for 143 processes (≈ 4.7 ms for all 273
  processes of the machine; measured on the test machine), so listing every second would take most of the app-side
  budget by itself. The table therefore matters only while per-process counters can arrive, and is listed:
  - never while the helper is not installed, outdated or refused (its state is checked again every 30 s): nothing
    could be attributed, and the first sample of the next stream is a baseline (10.4.3), so nothing is lost;
  - every 2 s while no agent process exists (the helper is not asked), only to notice agent processes;
  - every tick while an agent is active (10.6) or was within the last 60 s: its tool processes come and go then;
  - otherwise every 5 s, and in the same tick whenever a counter row names a process the table does not know yet. A
    process's first row arrives in the tick it first uses the network, so it is listed while it still runs, as a 1 Hz
    listing would find it; rows of processes that had already exited when listed do not ask again.
  With a typical session this keeps the listing at ≈ 0.16 % of one core while an agent is active and ≤ 0.08 %
  otherwise, within the app-side budget; it is not needed at all for the machine counters.
- Benchmark harness (both platforms): 10 minutes idle with agents running, 10 minutes with a 100 MB download in a tool
  process; report average CPU of the app plus nettop or the helper.

### 10.11 Byte formatting (both platforms)

Decimal units (1 KB = 1000 B), as macOS and network speeds use. Rates: `B/s`, `KB/s`, `MB/s`, `GB/s`; totals: `B`,
`KB`, `MB`, `GB`, `TB`. With the bits unit (DESIGN 10) rates are `× 8` with `b/s`, `Kb/s`, `Mb/s`, `Gb/s`.

| Value `x` in the unit | Display |
| --- | --- |
| bytes `< 1000` | integer (`0 B/s`, `512 B`) |
| `< 10` | two decimals (`1.28 KB/s`) |
| `< 100` | one decimal (`12.8 MB`) |
| `< 1000` | integer (`128 KB/s`) |

A value that rounds to 1000 in its unit moves to the next unit (`999.6 KB/s` → `1.00 MB/s`; `999.5 B` → `1.00 KB`);
the largest unit keeps larger integers (`5000 TB`).
Rounding is half-up on the decimal value. Number and unit are separated by a no-break space; units are never
translated. Cases: `spec/fixtures/traffic-cases.json` `format`.

### 10.12 Known approximations

- Machine traffic counts link-layer bytes (headers, retransmissions, VPN overhead, other programs, other users);
  process traffic counts socket payload, so the same transfer adds slightly less to its source than to the machine.
  The two are sampled at slightly different moments, so per-second values may briefly disagree.
- Child processes that detach before the first 1 Hz process-table refresh, or that are started on the agent's behalf
  by another process (a system service, Codex's Windows sandbox service `codex-windows-sandbox-service.exe`, an IDE's
  integrated terminal for Antigravity IDE commands, a browser opened by URL), are not attributed to the agent.
- Traffic of a remote machine an agent works on (SSH sessions are counted; the remote's own downloads are not).
- Per-agent attribution falls back to the source whenever more than one candidate is active (10.6).
- Windows counts start when the helper first sees a process; traffic of an agent process before the helper started is
  not counted (it is a baseline, 10.4.3).
- macOS unprivileged interface counters move in 1 KiB steps.
- Loopback traffic (local model servers such as Ollama or LM Studio, MCP servers on localhost, OpenCode's own client and
  server) is excluded everywhere.
- WorkBuddy's app processes (chat UI, cloud conversations, sync) are not counted; its CLI processes are recognized by
  rules derived from the 5.8 code, not yet from a running app.

## 11. Live reporting

Execution modes are additive metadata specified in [EXECUTION-MODES.md](EXECUTION-MODES.md); they do not change
any token, request, speed, duration or price formula. Optional per-model Harness/mode breakdowns and separate
profile APIs are defined in [REPORTING-EXTENSIONS.md](REPORTING-EXTENSIONS.md).

When the user turns on live reporting (DESIGN 11), the app sends the values below to a service of the user's choice
with the protocol of `spec/REPORTING.md`. This section defines how every reported value comes from the engine, the
*report ledger* that makes deltas exact, and the report scheduler. `spec/tools/report_reference.py` implements 11.5 as
a simulator and checks `spec/fixtures/report-vectors.json` → `scheduler`; both apps run the same cases through their
own scheduler core with a fake clock and instant sends. Only realtime values are reported: nothing of sections 6.6
(today), 8 (daily history), 9.6–9.7 or 10.8–10.9 is ever sent.

### 11.1 Scope and clock

- **Sources**: the enabled sources, all together. Never an orb's subset (6.8) and never filtered by subscription marks
  (9.4): cost is reported for every source.
- **Sections**: an optional section is built only when the service lists it and the user's switch is on (REPORTING
  6.1). Default switches (DESIGN 11): `sources`, `models`, `cost`, `traffic`, all on. A section that
  is off is left out of the report.
- **Build time** `t` is an engine tick (6: every 500 ms) with `nowMs = t`. Durations (`windowMs`, holds, retries) use
  the monotonic clock. `sentAt` is the wall clock at `t` plus the session's clock correction (11.6), formatted
  `YYYY-MM-DDTHH:MM:SS.sssZ` in UTC.
- **Order within a tick**: first the gap rule (11.5 step 2) may discard the ledger; then the engine applies the tick's
  file changes and traffic sample and the ledger (11.4) receives that tick's increments; then the rest of the
  scheduler (11.5) runs. Increments of the tick that ends a gap therefore belong to the new window.

### 11.2 Instantaneous values (at `t`)

| Report field | Computation |
| --- | --- |
| `live.outputTokS`, `live.totalTokS` | 6.3 `live.output`, `live.total` at `nowMs = t` |
| `live.estimatedShare` | 6.3 `liveEstimatedShare` |
| `live.agents.generating`, `.tools` | agents of the 6.7 base set (steps 1–2: staleness applied, no ancestor closure) in phase `generating` / `tools` |
| `live.agents.active` | the size of that base set |
| `peak.outputTokS`, `peak.totalTokS` | the maximum of 6.3 `live.output` / `live.total` over the ticks in `(windowStart, t]` (so never below the values at `t`) |
| `title.metric`, `title.redline` | the General speed metric and its redline `R` (DESIGN 1), never an orb's |
| `title.level` | the *report title tracker*: the DESIGN 1 title tracker (levels 0–13, entered at the threshold, left at 90 % of it, 0.8 s hold) fed with the live value of `title.metric` and `R` on every tick while a run is active; it starts at 0 when the run starts. An implementation may reuse the dashboard hero's tracker only when that tracker runs on every tick with the same inputs. |
| `title.heat` | `min(1, (v / R)^0.6)` with `v` the unrounded live value of `title.metric`; not smoothed (no spring) |
| `cost.liveMicroUsdPerSecond`, `cost.knownShare` | 9.5 `liveCost` and `liveCostKnownShare` over all enabled sources |
| `cost.peakMicroUsdPerSecond` | the maximum of 9.5 `liveCost` over the ticks in `(windowStart, t]` |
| `cost.priceVersion` | the table version bound to the local date of `t` (9.7), or the current version when that date is not bound yet |
| `traffic.*BytesPerSecond` | 10.7 live rates of the latest sample at or before `t`: Σ over sources of `self + tools` (`self` only when `includeTools` is off); `null` while that series has fewer than two samples |
| `traffic.peak*BytesPerSecond` | the maximum of those rates over the samples in `(windowStart, t]`; `null` when there is none |
| `traffic.status` | `off` when `trafficEnabled` is off (DESIGN 10); `unavailable` when process traffic is unavailable (10.3 states); else `ok` |
| `traffic.includesTools` | the `includeTools` setting |

Per source (`sources[]`) every value is the same computation restricted to the source (6.3 and 9.5 per source; 10.7
per source series). Per model (`models[].generating`): agents counted in `live.agents.generating` grouped by the
resolved id (11.3) of the agent's current model (the model the agents list shows for it).

### 11.3 Model ids

`models[].id` is the 9.2 resolution of a response's (or agent's) `model` and `provider`: a hit on a price table entry
(priced or free) → that entry's `id`; free by `freeProviders` (step 1) → `local`; everything else (missing model,
`unknown`, a free suffix without an entry) → `unknown`. The raw model string never leaves the app. Entries are grouped
by id and sorted by `output` descending, then `id`. With more than `maxModels` (discovery, ≤ 16) entries the first
`maxModels − 1` are kept and the rest are merged into `other` (fields summed, `sources` united, placed last).
`maxModels = 0` means the section is not sent.

### 11.4 Report ledger

The ledger holds the increments since the last build (or discard) of a report, in total, per source and per model.

**Counting a response.** A response key (3.4, 4.4) becomes *counted* at its first emission when all hold: the engine
is running live (not seeding, 6.4), `endMs ≥ nowMs − 120 000` (the `responseCompleted` rule of 6.4), and its source is
enabled. Counting adds to the ledger: `requests` + 1; `output`, `input`, `cachedInput`, `cacheWriteInput`,
`reasoning`; `measuredOutput` = `output` and `measuredMs` = `endMs − startMs'` (3.3) when the response is measured,
else 0; `costMicroUsd` (9.3) when known, else `unpricedRequests` + 1. A key that was not counted at its first emission
is never counted later (it is history).

**Growth of a counted response.** For every counted key the ledger keeps the values it already added (`reported_k`,
field by field: the token fields, `measuredOutput`, `measuredMs`, `costMicroUsd`). When an upsert (4.4) or a
re-pricing (9.7) changes the response, each field adds `max(0, new − reported_k)` and `reported_k` becomes
`max(reported_k, new)`. So a streaming Claude message adds its growth where it is seen, a response that becomes
measured (its `stop_reason` arrives) adds its measured output and duration then, and a response priced later adds its
cost then; `unpricedRequests` never decreases (REPORTING 6.6.1). Counted keys are kept while their response is in the
engine's retention (6.1, by its latest `endMs`), at most 65 536 (FIFO); a change after that is not reported.

**Attribution.** Each increment also goes to the response's source and to the resolved model id (11.3) of the
response's model at that moment.

**Traffic.** Every sample delta of 10.4 adds to the ledger at its sample time — per source `self` and `tools`; the
machine series (10.2) is never reported — except deltas of a sample whose interval is longer than 15 s (10.4.5 gap: those bytes are older than the
window) and the baseline of a stream's first sample (which adds nothing anyway). Agent traffic = Σ over sources of
`self + tools` (`self` only when `includeTools` is off). A source the user disabled (Settings → Data Sources) reports
no traffic — no rate and no delta — like every view of it (10.5); its bytes keep counting underneath, so the deltas
after it is enabled again start from the latest report, never from before it was disabled.

**Exactly once.** Every increment is applied once, at the tick where the engine produces it. *Build* (11.5) takes the
whole ledger into a report and empties it in one step; *discard* empties it without a report. Every increment
therefore ends up in exactly one built report or is discarded — never in two reports. The deltas of a report that is
built but not delivered are **lost**: they are never resent and never added to a later report (REPORTING 6.2). Tests
check: Σ deltas of built reports + Σ discarded = Σ increments, and the windows of built reports are disjoint.

### 11.5 Report scheduler

Limits come from the discovery document (REPORTING 3.2, clamped to its ranges): `I` = `intervalSeconds` (or the
`intervalSeconds` of the latest success, 5–300), `H` = `heartbeatSeconds` (≥ `I`), `A` = `maxAgeSeconds`. Fixed:
`HOLD` = 15 s, `QUIET` = 10 min, `GAP` = 15 s, `RETRY` = 2 s.

**Activity.** A tick is *active* when an agent of an enabled source is in phase `generating` or `tools` (after the 6.7
staleness rule), or `live.output > 0`, or the ledger received a token increment at that tick. `lastActive` = the
latest active tick of the run (none at its start).

**Mode** at tick `t`: `active` when `t − lastActive < HOLD`; `idle` when `t − lastActive < QUIET`; otherwise (and
before any activity in the run) `quiet`.

**Ready** = reporting on, the service confirmed (REPORTING 3.3) and registered (REPORTING 4.1), the network master
switch on (NETWORK 1), not paused, not inside a backoff or `Retry-After` wait, and no error that needs the user
(REPORTING 8.3).

**Run.** A run starts when reporting becomes ready for the first time after a launch (after seeding has finished), after
turning reporting on, after switching services, and after `seq_conflict`: a new random `run.id`, `seq = 0`, an empty
ledger, `windowStart = t`, no `lastActive`, the report title tracker at 0. Pausing, the network switch and backoff do
not start a new run.

**Each tick `t`**, in this order:

1. User events of this tick: pause, resume, network switch, turning reporting off, quitting.
2. **Gap**: when `t − previous tick > GAP` (sleep, a stalled engine), discard (empty the ledger, `windowStart = t`)
   before this tick's increments are added (11.1).
3. Update `lastActive` and the mode.
4. **Leaving on a user action**: when this tick pauses or turns off reporting or quits the app, the previous mode was
   not `quiet`, and nothing but a backoff kept the scheduler from being ready before this tick's event (the network
   switch is on, no `Retry-After` wait is in effect, the service is confirmed and registered, no error needs the
   user), build a `leaving` report and make one attempt (no retry; at quit wait at most 1 s). A waiting report and an
   in-flight report waiting for its retry are lost. During a `Retry-After` wait nothing is built or sent, not even
   this report (REPORTING 7.2); a backoff does not stop it.
5. **Not ready** → discard; stop here.
6. **Quiet**: on the tick the mode becomes `quiet` (the previous mode was `active` or `idle`), build a `leaving`
   report; on later quiet ticks discard.
7. **Due**: otherwise, when `t − windowStart ≥ I` (mode `active`) or `≥ H` (mode `idle`), build a report with
   `activity` = the mode.
8. **Deliver** (below).

**Build**: `seq + 1`; the report takes the ledger and the instantaneous values at `t`; `windowMs = t − windowStart`;
then the ledger is empty and `windowStart = t`. A built report goes to the one-slot outbox; a report already waiting
there is lost (the newer one replaces it), and an in-flight report that is waiting for its retry is lost too (newest
wins).

**Deliver**: at most one request in flight. When nothing is in flight the outbox report is sent at once. An attempt
signs with a fresh timestamp and nonce and sends the report's fixed body. A report whose `t − builtAt > A` is lost
instead of sent. Outcomes:

| Outcome | Effect |
| --- | --- |
| `2xx` | delivered; `failures = 0`; adopt `intervalSeconds` when present |
| network error, timeout, `3xx`, `5xx` without `Retry-After` | retry once at `t + RETRY` if `t + RETRY − builtAt ≤ A`; otherwise (or when the retry fails too) lost |
| `429`, or `503` with `Retry-After` | lost; not ready until `t + Retry-After` (5 s – 1 h; 60 s when a `429` has none) |
| `401 timestamp_out_of_window` | correct the clock (11.6); the report is lost (its `sentAt` is on the old clock) |
| `401 nonce_replayed` | attempt again at once with a new nonce (once) |
| `401 signature_invalid` with a pending rotated key (REPORTING 4.5) | attempt again at once signed with the pending key (once) |
| any other error | lost; the reaction of REPORTING 8.3 (re-register, start a new run, or not ready until the user acts) |

**Backoff**: every lost report increments `failures`; when `failures ≥ 2` the scheduler is not ready for
`min(300 s, 5 s × 2^(failures − 2))` × a random factor in `[0.8, 1.2]` (the fixtures use 1). A delivered report resets
`failures` to 0.

**Rate guarantees** (what services can rely on): at most one request in flight; two consecutive built reports of a run
are at least `I` apart (at least `H` while idle), except that a `leaving` report may follow at any time; at most one
transient retry per report; never a report older than `A`; no queue on disk and nothing replayed after a relaunch.
(`windowStart` only moves forward from the last build or discard, so every path back to *ready* — resume, network on,
end of a backoff — waits at least `I` after the previous report.)

### 11.6 Time, midnight, restarts and sleep

- **Clock correction**: on `401 timestamp_out_of_window` with `serverTime`, `correction = serverTime − local Unix
  seconds` when `|correction| ≤ 24 h`; it applies to `X-AgentSpeed-Timestamp` and `sentAt` of every later report of
  the session and is discarded at quit. The rejected report itself is lost (11.5).
- **Local midnight** has no effect: deltas belong to windows, not to days, and today's totals (6.6) are never sent. A
  window that contains midnight is reported like any other; services assign days themselves (REPORTING 6.10).
- **Relaunch**: a new run (11.5). Responses read during seeding are never counted (11.4), so nothing that happened
  before the run is reported; the ledger is never persisted.
- **Sleep**: the gap rule (11.5 step 2) discards the window that contains the sleep; traffic gap deltas are excluded
  (11.4).
- **Wall-clock changes** do not affect windows (monotonic); `sentAt` may jump with the clock. Services order by
  `run.seq` and their own receive time.

### 11.7 Rounding and size

- Rounding is half away from zero (all values are ≥ 0): tok/s to 0.1, shares and heat to 0.001, bytes per second and
  micro-USD per second to integers. Token, byte and micro-USD deltas are exact integers. Every value is rounded on its
  own, so rounded per-source values may differ from the rounded total by the rounding.
- `sources[]` lists, in the source order of section 1, every source with activity (REPORTING 6.6.3): some number of
  its entry as sent — rounded, `null` as 0 — other than `agents.active`, `live.estimatedShare` and `cost.knownShare`
  is above 0. A source whose only increment in the window is cost (a counted response priced only now, 11.4) is
  listed, so the per-source cost sums add up. `models[]` lists every resolved id (11.3) that received a ledger
  increment in the window, a cost increment included, or that an agent is generating with at `t`.
- The body stays within `min(16384, maxBodyBytes)` bytes: when it would not, drop `models`, then `sources`, for that
  report only.

### 11.8 Fixtures

`spec/fixtures/report-vectors.json` → `scheduler`: each case gives tick ranges in 500 ms steps (a jump between two
ranges is a sleep), activity ranges, output increments (`from`, `to`, `step`, `output`), user events
(`pause`, `resume`, `networkOff`, `networkOn`) and per-`seq` attempt outcomes (`ok`, `fail`, `rateLimited:<s>`;
default `ok`). `expect.delivered` lists `[seq, endMs, windowMs, activity, output]` of every delivered report and
`expect.lost` the lost `seq`s. The expected values were written by hand from 11.5 and the simulator must reproduce
them.
