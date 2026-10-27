# Execution mode metadata

This contract adds metadata and grouping to the existing measurement engine. Token normalization, request identity,
timing validation, speed windows, estimates and pricing equations remain unchanged. A missing mode is never Standard.

## Common facts

Both platform cores expose `ExecutionModes` containing at most 20 `ExecutionModeFact` values. A fact has:

| Field | Values |
| --- | --- |
| `kind` | `serviceTier`, `accelerator`, `modelVariant`, `routing`, `workflow` |
| `value` | Canonical lower-case mode token; known examples are `standard`, `fast`, `ultrafast`, `highspeed`, `balanced`, `deep`, `planning`, `auto`. New valid tokens remain distinct. |
| `rawValue` | Native token, retained locally; never a configuration document or a path. |
| `evidence` | `configured`, `selected`, `recorded`, `served` |
| `provider` | Optional safe provider identifier; never a URL or credential. |
| `scope` | `configuration`, `session`, `turn`, `request`, `response` |

All strings are bounded safe ASCII identifiers: value/rawValue at most 64 characters, provider at most 32,
matching `[A-Za-z0-9][A-Za-z0-9._:-]*`. Reject other values rather than displaying or reporting arbitrary source text.
An absent/null field does not manufacture a fact. Unmapped `auto`, `inherit`, `inherited`, `unknown` and `none`
remain unresolved selections; an adapter may map a native explicit off value only when its semantics are verified.
An explicit clear must clear the corresponding selected context; absence must not clear or override it.
Configured facts are source information only and never become a response's selected/served fact implicitly.
Facts are provider-aware: OpenAI `default` -> `standard`, `priority` -> `fast`; Anthropic Fast comes from
`usage.speed`, not `usage.service_tier`. Do not infer modes from throughput, reasoning effort or arbitrary model names.

`ResponseRecord.modes` / `ParsedResponse.Modes`, `AgentStatus.modes` and source-level configured modes use this type.
Empty is the backwards-compatible default. Display configured, selected/recorded, and served evidence separately.
Only explicit native inheritance may propagate selections to child agents; served evidence never propagates.
Mode changes affect their native scope and time, not earlier responses. Upserts keep the original request identity.

## Native adapters

- Codex: read an explicit supported transcript mode field if present. Read the declared user `config.toml`
  `service_tier` as configured information only, with model-catalog labels where available. Do not launch/resume a
  thread, attach to an unverified control interface, reconstruct all config layers, or promote recent-composer values.
  Only an unambiguous root string literal is accepted; multiline strings, duplicate declarations and unsupported
  syntax stay unknown. A declared default is not a claim about a running task's effective configuration.
- Claude Code/Desktop: retain explicit `message.usage.speed` `fast` and `standard` as served service-tier facts.
  Missing speed is not Standard. Preserve the existing pricing fast flag's compatibility behavior.
- OpenCode: `session_message.data.native.serviceTier` is served OpenAI tier metadata for supported versions.
  Native provider IDs `openai` and `azure` use the `openai` semantic namespace. Other provider IDs require their
  own mapping; custom names and variant names alone are not speed evidence.
- omp: `service_tier_change.serviceTier` is a provider-family map on the native journal branch; selections are
  branch/time scoped. Assistant `message.serviceTier` is recorded evidence because the harness may substitute the
  requested tier when a response echo is absent. Respect explicit rejection/fallback and child overrides.
- ZCode: user-message `metadata.highspeed` is selected `accelerator:highspeed` for that turn. Actual provider/model
  routing on an attempt is recorded evidence, not a provider response echo; a served fact requires explicit response
  metadata. Do not treat the full turn as accelerated after
  fallback, propagate an overlay to forks/subagents, or count `hsc_mock_*` metadata as served acceleration.
- Kimi: exact official IDs `k3.1-pro-highspeed` and `kimi-for-coding-highspeed` are selected `modelVariant:highspeed`.
  The recorded model is requested metadata, not proof of the provider's served model. No substring matching.
- WorkBuddy/WorkBuddy AI: `providerData.requestModelId` `fast-model`, `balanced-model`, `deep-model` are selected
  routing facts. A synthetic compatibility `service_tier:"standard"` is not served evidence.
- Antigravity: Planning/Fast is a workflow dimension only when its actual native field is known. Turbo permissions,
  animation speed and effort are excluded. Unknown protobuf tier semantics remain unclassified.
- Gemini CLI, DSH, Grok Build: expose the common unknown state until an explicit supported native field is present;
  a provider API's capability alone is not evidence that its harness selected it.

## Local aggregates and history

Mode classification is independent of the original model ID. For each kind, choose served evidence first, then
recorded, then selected. Configured-only or unresolved automatic selections become `unknown` / evidence `unknown`.
Preserve evidence categories as separate groups; selected Fast is not served Fast.

Every response contributes once within a mode kind. A response may independently have service, routing or workflow
facts, so rows of different kinds must not be added together. For any displayed kind, include missing records in an
unknown bucket; its group totals equal the ordinary model totals. Keep source/provider, model, kind, value and
evidence separate in grouping keys. Requests, output, measured output and measured milliseconds use existing rules.

Local upserts may replace a response's classification without incrementing its request count again. Existing
persisted aggregates remain available and unknown, never backfilled as Standard. Prefer an additive aggregate table
and parser-version reanalysis over rewriting old model IDs or deleting history.

The existing CSV format stays unchanged. A separate mode CSV uses these fixed columns, in order:
`date,source,model,kind,mode,evidence,provider,requests,output_tokens,measured_output_tokens,measured_ms,avg_speed_tok_s`.
Each kind is an independent breakdown with unknown totals filled from the ordinary aggregates. Average speed uses
the existing measured-output/measured-time formula; it is not an average of group averages.

## Optional report extension version 1

Discovery advertises `extensions.executionModes: 1`. A client sends the optional `models[].modeUsage` field only
when this exact integer is advertised and the user's existing models sharing section is enabled. Boolean true,
unknown versions, absent capability and disabled models sharing all retain the old report shape. The receiver
and leaderboard must implement this contract before advertising it. No conversation, paths or raw config is sent.

Each modeUsage row contains `source`, optional `provider`, `kind`, `mode`, `evidence`, `requests`, `output`,
`measuredOutput`, `measuredMs`. Evidence is `served`, `recorded`, `selected`, or `unknown`; `configured` is forbidden.
Mode and evidence are both `unknown` for an unattributable row. Native rawValue and native scope stay local.
Use the same bounded identifiers and integer bounds as the existing protocol. At most 64 rows per model.

For every kind present, rows have unique `(source,provider,kind,mode,evidence)` keys and their requests/output/
measuredOutput/measuredMs sums exactly equal the parent model entry. Row sources belong to the parent's sources.
Kinds are independent breakdowns, never extra model totals. If a complete bounded breakdown does not fit, omit the
optional field for that model rather than transmitting a partial/misleading breakdown or exceeding body limits.
Keep model IDs unique and unchanged. Existing signatures, run/seq deduplication and retry rules apply unchanged.

The report ledger freezes a response's mode attribution when that response first enters its live counters. Later
numeric growth uses that same attribution, so a late mode observation cannot replay a previously reported request
or transfer old tokens into a later window. Local UI/history can still retain richer later evidence. A late or
ambiguous fact may therefore remain unknown in already-reported data; no unnegotiated correction is sent.

## Acceptance

Shared fixtures must cover explicit Standard, missing/null/auto, OpenAI aliases, unknown future tiers, Anthropic
capacity-vs-speed, recorded-vs-served omp evidence, Kimi exact IDs, routing/workflow separation and unsafe strings.
Native adapter tests cover turn changes, parallel sessions, parent/child scope, fallback, streaming upserts and
restart/history migration. Both platforms must agree with the independent reference. Report checks cover exact
capability negotiation, complete per-kind conservation, body bounds, zero-request growth, late metadata, disabled
sharing, legacy payloads and receiver run/seq deduplication. Runtime UI checks use isolated settings and history.
