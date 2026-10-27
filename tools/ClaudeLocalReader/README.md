# ClaudeLocalReader

This local Windows helper reuses AgentSpeed.Core's Codex and Claude Code/Desktop transcript monitors. Codex is opt-in: the app selects it only for `displaySurfaces.speedDisplayMode == "agentSpeed"`; standalone invocation remains Claude-only unless `--source codex` is explicit. The helper does not launch an agent, read credentials, edit agent configuration, or construct HTTP requests. It enables only the explicitly selected local sources in `MonitorConfiguration`.

The project targets .NET 10 because the referenced AgentSpeed.Core project currently targets only `net10.0`.

## Modes

- `ClaudeLocalReader.exe` or `--once`: write one compact runtime JSON snapshot to stdout.
- `--watch`: write the latest snapshot at most once per second. When stdin is redirected, EOF requests shutdown; Ctrl+C also stops it.
- `--root <local-path>`: use a local Claude projects directory. UNC/network paths are rejected.
- `--codex-root <local-path>`: use a local Codex sessions directory. The app passes the selected Codex Home's `sessions` directory; UNC/network paths are rejected.
- `--source codex`, `--source claudeCode`, and/or `--source claudeDesktop`: monitor only the selected local client(s). Omitting all `--source` options keeps the standalone helper's default of both Claude sources. The app always passes explicit source selections.
- `--capture-statusline`: read at most 64 KiB of raw Claude JSON from stdin (no app schema/timestamp required), assign the local capture clock, keep only the approved cache fields, atomically write the app-owned LocalApplicationData cache, and write a fixed success line to stdout.
- `--self-test`: validate cache filtering, normalization, bounds, and runtime redaction without opening Claude files or writing the cache.

## Runtime snapshot

Schema version 1 uses camelCase and retains the existing top-level `client: "claude"` protocol ID. It contains per-source `sourceAvailable`, live totals scoped to selected sources, per-source `modelRates` (missing models are retained as `unknown`), `mainAgents`, `subagents`, and `latestResponse`. `responseEvents` contains at most 32 response-completion records with numeric usage and timing only. Agent and event IDs are per-process salted HMACs; transcript paths, project names, cwd, prompts, assistant text, and message text are not emitted.

## Statusline cache

`--capture-statusline` writes `%LOCALAPPDATA%/CodexTokenBar/claude-local-statusline/latest.json` with the normalized snake_case schema used by the local statusline provider. If `session_id` is present, it also writes `session-<sha256(session_id)>.json` in that folder. The cache keeps at most 64 valid per-session files, pruning the oldest; a named local mutex serializes concurrent capture processes.

- `schema_version`, `captured_at_epoch`, optional `session_id`
- optional `model.id` and `model.display_name`
- optional `rate_limits.five_hour`, `rate_limits.seven_day`, and `rate_limits.spend_limit`, each with `used_percentage` and normalized integer-epoch `resets_at`
- optional `cost.total_api_duration_ms` and `cost.total_duration_ms`
- optional `context_window` totals and the four current-usage token counts

Unknown fields are discarded. Percentages must be finite and from 0 through 100; counters and durations must be nonnegative integers. The helper does not install a statusline producer or modify Claude settings.
