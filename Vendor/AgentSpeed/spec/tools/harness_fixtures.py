#!/usr/bin/env python3
"""Synthetic native-format harness fixtures; expected values are independent of the readers."""
import json
import sqlite3
import sys
import tempfile
from pathlib import Path

BASE = 1792497600000  # 2026-10-20T12:00:00Z


def response(key, start, end, inp, out, cached=0, write=0, reasoning=0, model="glm-5.3", provider="zai"):
    return dict(key=key, startMs=BASE + start, endMs=BASE + end, input=inp, cachedInput=cached,
                cacheWriteInput=write, cacheWrite1hInput=0, output=out, reasoning=reasoning,
                model=model, provider=provider, final=True, fast=False, requestCount=1)


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def write_lines(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n" for row in rows),
                    encoding="utf-8")


def zcode(root):
    relative = "zcode/cli/db/db.sqlite"
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    database = sqlite3.connect(":memory:")
    database.executescript("""
        DROP TABLE IF EXISTS model_usage;
        DROP TABLE IF EXISTS message;
        DROP TABLE IF EXISTS part;
        DROP TABLE IF EXISTS session;
        CREATE TABLE session (
            id TEXT PRIMARY KEY, project_id TEXT NOT NULL, parent_id TEXT, slug TEXT NOT NULL,
            directory TEXT NOT NULL, title TEXT NOT NULL, version TEXT NOT NULL,
            time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL,
            task_type TEXT NOT NULL DEFAULT 'interactive', time_deleted INTEGER, last_outcome TEXT);
        CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL, data TEXT NOT NULL, sequence INTEGER);
        CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL,
            time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL, sequence INTEGER);
        CREATE TABLE model_usage (
            id TEXT PRIMARY KEY, logical_request_id TEXT NOT NULL, attempt_index INTEGER NOT NULL DEFAULT 0,
            session_id TEXT NOT NULL, turn_id TEXT, query_source TEXT NOT NULL, provider_id TEXT NOT NULL,
            model_id TEXT NOT NULL, status TEXT NOT NULL, started_at INTEGER NOT NULL, completed_at INTEGER,
            duration_ms INTEGER, input_tokens INTEGER NOT NULL DEFAULT 0, output_tokens INTEGER NOT NULL DEFAULT 0,
            reasoning_tokens INTEGER NOT NULL DEFAULT 0, cache_creation_input_tokens INTEGER NOT NULL DEFAULT 0,
            cache_read_input_tokens INTEGER NOT NULL DEFAULT 0, raw_usage_json TEXT);
    """)
    for sid, parent, updated in [("sess-z-main", None, 21000), ("sess-z-sub", "sess-z-main", 15000),
                                  ("sess-z-running", None, 22000)]:
        database.execute("INSERT INTO session (id,project_id,parent_id,slug,directory,title,version,time_created,time_updated) "
                         "VALUES (?,?,?,?,?,?,?,?,?)", (sid, "project-quasar", parent, sid, "/projects/quasar",
                                                         "Synthetic fixture", "3.16.2", BASE, BASE + updated))
    calls = [
        ("z-r1", "sess-z-main", 10000, 14000, 1200, 200, 500, 100, 50, "main_turn"),
        ("z-title", "sess-z-main", 15000, 16000, 80, 30, 0, 0, 0, "session_title"),
        ("z-r2", "sess-z-main", 17000, 18500, 2000, 150, 1000, 0, 0, "main_turn"),
        ("z-r3", "sess-z-sub", 12000, 15000, 400, 90, 100, 20, 10, "main_turn"),
    ]
    expected = {}
    for rid, sid, start, end, inp, out, cached, write, reasoning, source in calls:
        database.execute("INSERT INTO model_usage (id,logical_request_id,session_id,query_source,provider_id,model_id,"
                         "status,started_at,completed_at,duration_ms,input_tokens,output_tokens,reasoning_tokens,"
                         "cache_creation_input_tokens,cache_read_input_tokens) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                         (rid, rid, sid, source, "zai", "glm-5.3", "completed", BASE + start, BASE + end,
                          end - start, inp, out, reasoning, write, cached))
        expected.setdefault(sid, []).append(response("zcode:" + rid, start, end, inp, out, cached, write, reasoning))
    database.execute("INSERT INTO model_usage (id,logical_request_id,session_id,query_source,provider_id,model_id,"
                     "status,started_at) VALUES ('z-running','z-running','sess-z-running','main_turn','zai','glm-5.3',"
                     "'running',?)", (BASE + 22000,))
    database.commit()
    database.execute("VACUUM")
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix="fixture-", suffix=".sqlite", delete=False) as handle:
        temporary = Path(handle.name)
    with sqlite3.connect(str(temporary)) as target:
        database.backup(target)
    temporary.replace(path)
    database.close()
    return dict(database=relative, sessions=[
        dict(id=sid, project="quasar", parentId=parent, responses=expected.get(sid, []))
        for sid, parent in [("sess-z-main", None), ("sess-z-sub", "sess-z-main"), ("sess-z-running", None)]])


def kimi(root):
    folder = "kimi/sessions/wd_nova_0123456789ab/sess-kimi"
    main = folder + "/agents/main/wire.jsonl"
    child = folder + "/agents/agent-0/wire.jsonl"
    def event(record_type, at, agent="main", **fields):
        return dict(type=record_type, time=BASE + at, agentId=agent, **fields)
    def usage(other, out, read=0, write=0):
        return dict(inputOther=other, output=out, inputCacheRead=read, inputCacheCreation=write)
    first, second, third = usage(100, 80, 20, 10), usage(200, 120, 80, 20), usage(50, 60, 10, 0)
    rows = [dict(type="metadata", protocol_version="1.5", created_at=BASE),
            event("config.update", 1, environmentDisclosure=dict(cwd="/projects/nova")),
            event("turn.prompt", 29000, turnId=1),
            event("llm.request", 30000, provider="moonshot", model="kimi-k2.5", kind="loop"),
            event("usage.record", 34000, model="kimi-k2.5", usage=first),
            event("context.append_message", 34000, message=dict(role="assistant", id="k-m1", content=[], toolCalls=[],
                  usage=first, llmTiming=dict(llmFirstTokenLatencyMs=500, llmStreamDurationMs=3500))),
            event("context.append_loop_event", 34000, event=dict(type="step.end", uuid="step-k1", messageId="k-m1",
                  turnId="1", step=1, finishReason="completed", usage=first,
                  llmFirstTokenLatencyMs=500, llmStreamDurationMs=3500)),
            event("llm.request", 40000, provider="moonshot", model="kimi-k2.5", kind="loop"),
            event("context.append_loop_event", 40000, event=dict(type="step.begin", uuid="step-k2", turnId="1", step=2)),
            event("context.append_loop_event", 43200, event=dict(type="step.end", uuid="step-k2", messageId="k-m2",
                  turnId="1", step=2, finishReason="tool_calls", usage=second,
                  llmFirstTokenLatencyMs=700, llmStreamDurationMs=2500)),
            event("context.append_message", 43200, message=dict(role="assistant", id="k-m2", content=[],
                  toolCalls=[dict(id="tool-k", name="Read", type="function", arguments="{}")], usage=second)),
            event("llm.request", 50000, provider="moonshot", model="kimi-k2.5", kind="loop"),
            event("human.agent.message.appended", 52000, message=dict(message=dict(role="assistant", content=[], toolCalls=[]),
                  meta=dict(messageId="k-m3", usage=third, model=dict(provider="moonshot", model="kimi-k2.5")))),
            event("subagent.completed", 52500, subagentId="agent-0", resultSummary="Synthetic result", usage=usage(5000, 5000)),
            event("turn.ended", 53000, turnId=1, reason="completed")]
    write_lines(root / main, rows)
    child_usage = usage(70, 45)
    write_lines(root / child, [dict(type="metadata", protocol_version="1.5", created_at=BASE + 31000),
        event("config.update", 31001, "agent-0", environmentDisclosure=dict(cwd="/projects/nova")),
        event("llm.request", 32000, "agent-0", provider="moonshot", model="kimi-k2.5", kind="loop"),
        event("context.append_loop_event", 35000, "agent-0", event=dict(type="step.end", uuid="step-child",
              messageId="k-child", turnId="1", step=1, finishReason="completed", usage=child_usage,
              llmFirstTokenLatencyMs=400, llmStreamDurationMs=2600)),
        event("turn.ended", 35001, "agent-0", turnId=1, reason="completed")])
    copy = "kimi/sessions/wd_nova_0123456789ab/sess-kimi-copy/agents/main/wire.jsonl"
    write_lines(root / copy, rows)
    common = dict(model="kimi-k2.5", provider="moonshot")
    return dict(root="kimi/sessions", files=[
        dict(path=main, project="nova", isSubagent=False, parentFile=None, responses=[
            response("kimi:k-m1", 30000, 34000, 130, 80, 20, 10, **common),
            response("kimi:k-m2", 40000, 43200, 300, 120, 80, 20, **common),
            response("kimi:k-m3", 50000, 52000, 60, 60, 10, **common)]),
        dict(path=child, project="nova", isSubagent=True, parentFile=main, responses=[
            response("kimi:k-child", 32000, 35000, 70, 45, **common)]),
        dict(path=copy, project="nova", isSubagent=False, parentFile=None, responses=[])])


def grok(root):
    folder = "grok/sessions/%2Fprojects%2Fcomet"
    main = folder + "/g-main/updates.jsonl"
    child = folder + "/g-child/updates.jsonl"
    copy = folder + "/g-copy/updates.jsonl"
    def update(kind, at, sid="g-main", method="_x.ai/session/update", **fields):
        return dict(timestamp=(BASE + at) // 1000, method=method, params=dict(sessionId=sid,
                    update=dict(sessionUpdate=kind, **fields), _meta=dict(eventId=sid + ":" + str(at),
                                                                       agentTimestampMs=BASE + at)))
    def bucket(inp, out, cached, reasoning, calls, duration):
        return dict(inputTokens=inp, outputTokens=out, cachedReadTokens=cached, cacheCreationTokens=0,
                    reasoningTokens=reasoning, totalTokens=inp + out, modelCalls=calls, apiDurationMs=duration)
    first = bucket(1500, 300, 400, 30, 2, 6000)
    a, b = bucket(1200, 250, 300, 25, 1, 3000), bucket(800, 150, 0, 15, 1, 2000)
    second = bucket(2000, 400, 300, 40, 2, 5000)
    rows = [update("user_message_chunk", 60000, method="session/update", content=dict(type="text", text="Synthetic prompt")),
        update("subagent_spawned", 60500, subagent_id="g-child", child_session_id="g-child",
               parent_session_id="g-main", parent_prompt_id="g-p1", subagent_type="general-purpose", description="Synthetic task"),
        update("subagent_finished", 63500, subagent_id="g-child", child_session_id="g-child", status="completed",
               tool_calls=0, turns=1, duration_ms=2500, tokens_used=600, will_wake=False),
        update("turn_completed", 65000, prompt_id="g-p1", stop_reason="end_turn", elapsed_ms=5000,
               usage=dict(first, modelUsage={"grok-4.5": first}, numTurns=1)),
        update("user_message_chunk", 70000, method="session/update", content=dict(type="text", text="Synthetic continuation")),
        update("turn_completed", 75000, prompt_id="g-p2", stop_reason="end_turn", elapsed_ms=5000,
               usage=dict(second, modelUsage={"grok-4.5": a, "grok-4.6": b}, numTurns=2))]
    write_lines(root / main, rows)
    sub = bucket(500, 100, 100, 10, 1, 2000)
    write_lines(root / child, [update("user_message_chunk", 61000, "g-child", method="session/update",
                                     content=dict(type="text", text="Synthetic child task")),
        update("turn_completed", 63000, "g-child", prompt_id="g-c1", stop_reason="end_turn", elapsed_ms=2000,
               usage=dict(sub, modelUsage={"grok-4.5": sub}, numTurns=1))])
    write_lines(root / copy, rows)
    for sid, parent, kind, end in [("g-main", None, "headless", 75000), ("g-child", "g-main", "subagent", 63000),
                                    ("g-copy", "g-main", "fork", 75000)]:
        write_json(root / folder / sid / "summary.json", dict(info=dict(id=sid, cwd="/projects/comet"),
                   current_model_id="grok-4.5", parent_session_id=parent, session_kind=kind,
                   created_at="2026-10-20T12:00:00Z", updated_at="2026-10-20T12:01:15Z"))
        # The companion cumulative store must never be added to the turn records.
        write_json(root / folder / sid / "usage.json", dict(sessionId=sid, session=dict(inputTokens=999999,
                   outputTokens=999999, modelCalls=999), turns=[]))
    expected_first = response("grok:g-p1:grok-4.5", 59000, 65000, 1500, 300, 400, reasoning=30,
                              model="grok-4.5", provider=None)
    expected_first["requestCount"] = 2
    return dict(root="grok/sessions", files=[
        dict(path=main, project="comet", isSubagent=False, parentFile=None, responses=[expected_first,
             response("grok:g-p2:grok-4.5", 72000, 75000, 1200, 250, 300, reasoning=25, model="grok-4.5", provider=None),
             response("grok:g-p2:grok-4.6", 73000, 75000, 800, 150, reasoning=15, model="grok-4.6", provider=None)]),
        dict(path=child, project="comet", isSubagent=True, parentFile=main, responses=[]),
        dict(path=copy, project="comet", isSubagent=False, parentFile=main, responses=[])])


def generate(root):
    root = Path(root)
    expected = dict(version=1, zcode=zcode(root), kimi=kimi(root), grok=grok(root))
    write_json(root / "harness-expected.json", expected)
    return expected


if __name__ == "__main__":
    generate(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "fixtures")
