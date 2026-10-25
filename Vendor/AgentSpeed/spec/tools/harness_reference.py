#!/usr/bin/env python3
"""Independent native-record normalization for ZCode, Kimi Code CLI and Grok Build.

Speed, history and pricing are deliberately left to reference.py's existing calculations.
"""
import json
import math
import sqlite3
from collections import OrderedDict
from pathlib import Path

FIELDS = ("input", "cachedInput", "cacheWriteInput", "cacheWrite1hInput", "output", "reasoning")
CAP = 10 ** 12
MAX_LINE = 32 * 1024 * 1024


def count(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return 0
    if isinstance(value, float) and not math.isfinite(value):
        return CAP if value > 0 else 0
    return max(0, min(CAP, int(value)))


def millis(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    try:
        if not math.isfinite(float(value)):
            return None
        return max(-(2 ** 63), min(2 ** 63 - 1, int(value)))
    except (OverflowError, ValueError):
        return None


def object_value(value):
    return value if isinstance(value, dict) else {}


def text(value):
    return value if isinstance(value, str) and value else None


def record(key, start, end, usage, model=None, provider=None, requests=1):
    return dict(key=key, startMs=start, endMs=end, **{field: count(usage.get(field)) for field in FIELDS},
                model=text(model), provider=text(provider), final=True, fast=False,
                requestCount=max(1, min(100000, count(requests))))


def json_file(path, limit=1024 * 1024):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size > limit:
        return None
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else None
    except (OSError, UnicodeError, ValueError, RecursionError):
        return None


def lines(path):
    with Path(path).open("rb") as handle:
        while True:
            raw = handle.readline(MAX_LINE + 1)
            if not raw:
                return
            if len(raw) > MAX_LINE:
                while raw and not raw.endswith(b"\n"):
                    raw = handle.readline(MAX_LINE + 1)
                continue
            try:
                row = json.loads(raw, parse_constant=lambda x: (_ for _ in ()).throw(ValueError(x)))
                if isinstance(row, dict):
                    yield row
            except (ValueError, UnicodeError, RecursionError):
                continue


def zcode_database(root):
    root = Path(root)
    for suffix in ("", "db.sqlite", "db/db.sqlite", "cli/db/db.sqlite", ".zcode/cli/db/db.sqlite"):
        candidate = root / suffix
        if candidate.is_file() and not candidate.is_symlink():
            return candidate
    return None


def read_zcode(root, seen=None):
    seen = seen if seen is not None else set()
    path = zcode_database(root)
    if path is None:
        return []
    uri = path.resolve().as_uri() + "?mode=ro"
    if not Path(str(path) + "-wal").exists():
        uri += "&immutable=1"
    with sqlite3.connect(uri, uri=True) as database:
        database.row_factory = sqlite3.Row
        states = OrderedDict()
        for session in database.execute("SELECT id,parent_id,directory FROM session ORDER BY time_created,id"):
            states[session["id"]] = dict(id=session["id"], agentId=str(path) + "#" + session["id"],
                source="zcode", project=Path(session["directory"]).name,
                parentId=session["parent_id"], isSubagent=bool(session["parent_id"]), responses=[])
        for row in database.execute("SELECT * FROM model_usage ORDER BY started_at,id"):
            if row["status"] == "running" or row["completed_at"] is None or row["session_id"] not in states:
                continue
            key = "zcode:" + row["id"]
            if key in seen:
                continue
            seen.add(key)
            states[row["session_id"]]["responses"].append(record(key, row["started_at"], row["completed_at"],
                dict(input=row["input_tokens"], output=row["output_tokens"], reasoning=row["reasoning_tokens"],
                     cachedInput=row["cache_read_input_tokens"], cacheWriteInput=row["cache_creation_input_tokens"]),
                row["model_id"], row["provider_id"]))
    return list(states.values())


def read_kimi(path, seen=None):
    path = Path(path)
    seen = seen if seen is not None else set()
    agent = path.parent.name
    session = path.parent.parent.parent.name
    output = OrderedDict()
    start, model, provider, project, latest_id = None, None, None, None, None
    for row in lines(path):
        kind, at = row.get("type"), millis(row.get("time"))
        cwd = object_value(row.get("environmentDisclosure")).get("cwd") or row.get("cwd")
        if text(cwd):
            project = Path(cwd).name
        if text(row.get("model")):
            model = row["model"]
        if text(row.get("provider")):
            provider = row["provider"]
        if at is None:
            continue
        if kind == "llm.request":
            start, latest_id = at, None
            continue
        message, meta, timing, identity, usage = {}, {}, {}, None, None
        if kind == "context.append_loop_event":
            event = object_value(row.get("event"))
            if event.get("type") != "step.end":
                continue
            message, timing = event, event
            identity = text(event.get("messageId")) or text(event.get("uuid"))
            usage = event.get("usage")
        elif kind in ("context.append_message", "agent.message.appended", "human.agent.message.appended"):
            outer = object_value(row.get("message"))
            message = object_value(outer.get("message")) if "message" in outer else outer
            meta = object_value(outer.get("meta"))
            if message.get("role") != "assistant" or message.get("partial") is True:
                continue
            identity = text(message.get("providerMessageId")) or text(message.get("id")) or text(meta.get("messageId"))
            usage = message.get("usage") if isinstance(message.get("usage"), dict) else meta.get("usage")
            timing = object_value(message.get("llmTiming") or meta.get("llmTiming"))
        if not isinstance(usage, dict):
            continue
        identity = identity or latest_id or "%s:%s:%d" % (session, agent, at)
        latest_id = identity
        key = "kimi:" + identity
        if key in seen and key not in output:
            continue
        read, write = count(usage.get("inputCacheRead")), count(usage.get("inputCacheCreation"))
        normalized = dict(input=min(CAP, count(usage.get("inputOther")) + read + write), cachedInput=read,
                          cacheWriteInput=write, output=count(usage.get("output")))
        raw = object_value(usage.get("raw"))
        reasoning = count(raw.get("reasoning_tokens")) or count(object_value(raw.get("completion_tokens_details")).get("reasoning_tokens"))
        normalized["reasoning"] = min(normalized["output"], reasoning)
        metadata_model = object_value(meta.get("model"))
        row_model, row_provider = metadata_model.get("model") or model, metadata_model.get("provider") or provider
        first, stream = millis(timing.get("llmFirstTokenLatencyMs")), millis(timing.get("llmStreamDurationMs"))
        duration = first + stream if first is not None and stream is not None and first >= 0 and stream >= 0 else None
        prior = output.get(key)
        effective_start = prior["startMs"] if prior else start
        if effective_start is None and duration is not None and 0 <= duration <= 900000:
            effective_start = at - duration
        output[key] = record(key, effective_start, prior["endMs"] if prior else at, normalized, row_model, row_provider)
        seen.add(key)
        start = None
    parent = str(path.parent.parent / "main" / "wire.jsonl") if agent != "main" else None
    return dict(agentId=str(path), source="kimi", project=project, isSubagent=agent != "main",
                parentFile=parent, responses=list(output.values()))


def read_grok(path, seen=None):
    path = Path(path)
    seen = seen if seen is not None else set()
    metadata = json_file(path.parent / "summary.json")
    summary = metadata or {}
    info = object_value(summary.get("info"))
    parent = text(summary.get("parent_session_id"))
    child = summary.get("session_kind") in ("subagent", "subagent_fork") and parent is not None
    model = text(summary.get("current_model_id"))
    output = OrderedDict()
    metadata_ready = metadata is not None
    for row in lines(path):
        params = object_value(row.get("params"))
        meta, update = object_value(params.get("_meta")), object_value(params.get("update"))
        if not metadata_ready or child or update.get("sessionUpdate") != "turn_completed":
            continue
        at = millis(meta.get("agentTimestampMs"))
        if at is None:
            seconds = millis(row.get("timestamp"))
            at = seconds * 1000 if seconds is not None else None
        usage = update.get("usage")
        if at is None or not isinstance(usage, dict):
            continue
        identity = text(update.get("prompt_id")) or text(meta.get("eventId")) or "%s:%s" % (path.parent.name, at)
        buckets = object_value(usage.get("modelUsage"))
        if not buckets:
            totals = usage.get("totals")
            buckets = {model: totals if isinstance(totals, dict) else usage}
        for name, raw in buckets.items():
            if not isinstance(raw, dict):
                continue
            key = "grok:%s:%s" % (identity, name or "unknown")
            if key in seen and key not in output:
                continue
            seen.add(key)
            duration = millis(raw.get("apiDurationMs"))
            start = at - duration if duration is not None and 0 < duration <= 900000 else None
            inp, out = count(raw.get("inputTokens")), count(raw.get("outputTokens"))
            output[key] = record(key, start, at,
                dict(input=inp, output=out, reasoning=min(out, count(raw.get("reasoningTokens"))),
                     cachedInput=min(inp, count(raw.get("cachedReadTokens"))),
                     cacheWriteInput=min(inp, count(raw.get("cacheCreationTokens")))),
                name, requests=raw.get("modelCalls", 1))
    return dict(agentId=str(path), source="grokBuild", project=Path(info["cwd"]).name if text(info.get("cwd")) else None,
                isSubagent=child, parentFile=str(path.parent.parent / parent / "updates.jsonl") if parent else None,
                responses=list(output.values()))


def discover(root, name, depth):
    root = Path(root).resolve()
    if not root.is_dir():
        return []
    result = []
    for path in root.glob("*/" * depth + name):
        if name == "wire.jsonl" and path.parent.parent.name != "agents":
            continue
        if path.is_file() and not any(p.is_symlink() for p in (path, *path.parents) if p != root.parent):
            result.append(path)
    return sorted(result, key=lambda path: (path.stat().st_mtime_ns // 100, str(path)))[-20000:]


def collect(zcode=None, kimi=None, grok=None):
    seen, states = set(), []
    if zcode:
        states.extend(read_zcode(zcode, seen))
    for root, name, depth, reader in [(kimi, "wire.jsonl", 4, read_kimi), (grok, "updates.jsonl", 2, read_grok)]:
        if root:
            states.extend(reader(path, seen) for path in discover(root, name, depth))
    return [(state["source"], state["agentId"], row) for state in states for row in state["responses"]]


def check_fixtures(root):
    root = Path(root)
    expected = json_file(root / "harness-expected.json", 8 * 1024 * 1024)
    failures, seen = [], set()
    actual = {state["id"]: state for state in read_zcode(root / expected["zcode"]["database"], seen)}
    for wanted in expected["zcode"]["sessions"]:
        got = actual.get(wanted["id"], {})
        for field in ("project", "parentId", "responses"):
            if got.get(field) != wanted[field]:
                failures.append("zcode %s %s: expected %r got %r" % (wanted["id"], field, wanted[field], got.get(field)))
    for source, reader in [("kimi", read_kimi), ("grok", read_grok)]:
        for wanted in expected[source]["files"]:
            got = reader(root / wanted["path"], seen)
            for field in ("project", "isSubagent", "responses"):
                if got[field] != wanted[field]:
                    failures.append("%s %s: expected %r got %r" % (wanted["path"], field, wanted[field], got[field]))
    return failures
