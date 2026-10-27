#!/usr/bin/env python3
"""Generates the shared parser and engine fixtures in spec/fixtures.

Usage: python3 spec/tools/generate_fixtures.py
"""
import json
import math
import os
import subprocess
import sys
from datetime import datetime, timezone

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import antigravity_fixtures  # noqa: E402
import gemini_fixtures  # noqa: E402
import omp_fixtures  # noqa: E402
import workbuddy_fixtures  # noqa: E402

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "fixtures"))
T0 = int(datetime(2026, 10, 20, 10, 0, 0, tzinfo=timezone.utc).timestamp() * 1000)


def ts(ms):
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + f"{ms % 1000:03d}Z"


def at(minutes, seconds, millis=0):
    return T0 + minutes * 60_000 + seconds * 1000 + millis


def write_jsonl(rel, rows):
    path = os.path.join(ROOT, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        for row in rows:
            f.write(row if isinstance(row, str) else json.dumps(row, ensure_ascii=False, separators=(",", ":")))
            f.write("\n")


def codex(ms, kind, payload):
    return {"timestamp": ts(ms), "type": kind, "payload": payload}


def cx(i, c, o, r, cw=None):
    u = {"input_tokens": i, "cached_input_tokens": c, "output_tokens": o,
         "reasoning_output_tokens": r, "total_tokens": i + o}
    if cw is not None:
        u["cache_write_input_tokens"] = cw
    return u


def resp(key, start, end, inp, cached, cw, out, reasoning, model, final=True, cw1h=0, provider=None, fast=False):
    return {"key": key, "startMs": start, "endMs": end, "input": inp, "cachedInput": cached,
            "cacheWriteInput": cw, "cacheWrite1hInput": cw1h, "output": out, "reasoning": reasoning, "model": model,
            "provider": provider, "fast": fast, "final": final}


files = {}
order = []


def expect(rel, **kw):
    order.append(rel)
    files[rel] = kw


# --- Codex, modern format -----------------------------------------------------
rel = "codex/sessions/2026/10/20/rollout-2026-10-20T10-00-00-modern.jsonl"
u1 = cx(10000, 8000, 200, 50, 0)
u2 = cx(10400, 10000, 330, 0, 0)
cum2 = cx(20400, 18000, 530, 50, 0)
write_jsonl(rel, [
    codex(at(0, 0), "session_meta", {"id": "thread-main", "session_id": "sess-1", "timestamp": ts(at(0, 0)),
                                     "cwd": "/Users/dev/projects/rocket", "originator": "codex_cli_rs",
                                     "model_provider": "openai",
                                     "cli_version": "0.163.0", "source": "cli"}),
    codex(at(0, 0, 100), "turn_context", {"cwd": "/Users/dev/projects/rocket", "model": "gpt-6.1-sol"}),
    codex(at(0, 1), "event_msg", {"type": "task_started", "turn_id": "turn-1"}),
    codex(at(0, 1), "event_msg", {"type": "user_message", "message": "Ship it", "images": []}),
    codex(at(0, 1, 10), "response_item", {"type": "message", "role": "user",
                                          "content": [{"type": "input_text", "text": "Ship it"}]}),
    codex(at(0, 3), "response_item", {"type": "reasoning", "summary": [], "encrypted_content": "x"}),
    codex(at(0, 5), "response_item", {"type": "function_call", "name": "shell", "arguments": "{}",
                                      "call_id": "call-1"}),
    codex(at(0, 5, 10), "token_usage_record", {"thread_id": "thread-main", "session_id": "sess-1",
                                               "response_id": "resp-1", "usage": u1,
                                               "turn_token_usage": u1, "thread_token_usage": u1}),
    codex(at(0, 5, 12), "event_msg", {"type": "token_count",
                                      "info": {"total_token_usage": u1, "last_token_usage": u1}}),
    codex(at(0, 7, 500), "response_item", {"type": "function_call_output", "call_id": "call-1", "output": "ok"}),
    codex(at(0, 9), "response_item", {"type": "message", "role": "assistant",
                                      "content": [{"type": "output_text", "text": "Done"}]}),
    codex(at(0, 10, 500), "token_usage_record", {"thread_id": "thread-main", "session_id": "sess-1",
                                                 "response_id": "resp-2", "usage": u2,
                                                 "turn_token_usage": u2, "thread_token_usage": cum2}),
    codex(at(0, 10, 502), "event_msg", {"type": "token_count",
                                        "info": {"total_token_usage": cum2, "last_token_usage": u2}}),
    codex(at(0, 10, 600), "token_usage_record", {"thread_id": "thread-main", "session_id": "sess-1",
                                                 "response_id": "resp-2", "usage": u2}),
    "this line is not json",
    codex(at(0, 10, 700), "event_msg", {"type": "task_complete", "turn_id": "turn-1"}),
])
expect(rel, source="codex", project="rocket", model="gpt-6.1-sol", isSubagent=False, parentFile=None,
       phase="idle", inFlightStartMs=None, lastLineMs=at(0, 10, 700), malformedLines=1,
       responses=[
           resp("resp-1", at(0, 1, 10), at(0, 5, 10), 10000, 8000, 0, 200, 50, "gpt-6.1-sol", provider="openai"),
           resp("resp-2", at(0, 7, 500), at(0, 10, 500), 10400, 10000, 0, 330, 0, "gpt-6.1-sol",
                provider="openai"),
       ])

# --- Codex, sub-agent with copied parent history ------------------------------
rel = "codex/sessions/2026/10/20/rollout-2026-10-20T10-00-20-subagent.jsonl"
u3 = cx(5000, 0, 120, 40)
write_jsonl(rel, [
    codex(at(0, 20), "session_meta", {"id": "thread-worker", "session_id": "sess-1", "timestamp": ts(at(0, 20)),
                                      "forked_from_id": "thread-main", "parent_thread_id": "thread-main",
                                      "cwd": "/Users/dev/projects/rocket", "thread_source": "subagent",
                                      "agent_path": "/root/worker",
                                      "source": {"subagent": {"thread_spawn": {"parent_thread_id": "thread-main",
                                                                               "depth": 1,
                                                                               "agent_path": "/root/worker"}}}}),
    codex(at(0, 20), "session_meta", {"id": "thread-main", "session_id": "sess-1", "timestamp": ts(at(0, 0)),
                                      "cwd": "/Users/dev/projects/rocket", "source": "cli",
                                      "model_provider": "openai"}),
    codex(at(0, 1, 10), "response_item", {"type": "message", "role": "user",
                                          "content": [{"type": "input_text", "text": "Ship it"}]}),
    codex(at(0, 5, 10), "token_usage_record", {"thread_id": "thread-main", "session_id": "sess-1",
                                               "response_id": "resp-1", "usage": u1}),
    codex(at(0, 7, 0), "token_usage_record", {"thread_id": "thread-main", "session_id": "sess-1",
                                              "response_id": "resp-old-copy", "usage": u1}),
    codex(at(0, 20, 100), "turn_context", {"cwd": "/Users/dev/projects/rocket", "model": "gpt-6.1-sol"}),
    codex(at(0, 20, 500), "response_item", {"type": "agent_message", "author": "/root/worker",
                                            "recipient": "/root", "content": []}),
    codex(at(0, 21), "response_item", {"type": "agent_message", "author": "/root", "recipient": "/root/worker",
                                       "content": [{"type": "input_text", "text": "Task"}]}),
    codex(at(0, 22), "response_item", {"type": "reasoning", "summary": []}),
    codex(at(0, 23, 900), "response_item", {"type": "custom_tool_call", "name": "exec", "input": "ls",
                                            "call_id": "call-9"}),
    codex(at(0, 24), "token_usage_record", {"thread_id": "thread-worker", "session_id": "sess-1",
                                            "response_id": "resp-3", "usage": u3}),
    codex(at(0, 30), "response_item", {"type": "custom_tool_call_output", "call_id": "call-9", "output": "a b"}),
    codex(at(0, 31), "response_item", {"type": "reasoning", "summary": []}),
    codex(at(0, 32), "event_msg", {"type": "token_count", "info": {"total_token_usage": u3, "last_token_usage": u3}}),
    codex(at(0, 40), "response_item", {"type": "agent_message", "author": "/root", "recipient": "/root/worker",
                                       "content": [{"type": "input_text", "text": "Next"}]}),
    codex(at(0, 45), "response_item", {"type": "reasoning", "summary": []}),
    codex(at(0, 47), "token_usage_record", {"thread_id": "thread-worker", "session_id": "sess-1",
                                            "response_id": "resp-4", "usage": cx(5200, 5000, 60, 10)}),
])
expect(rel, source="codex", project="rocket", model="gpt-6.1-sol", isSubagent=True,
       parentFile="codex/sessions/2026/10/20/rollout-2026-10-20T10-00-00-modern.jsonl", phase="tools", inFlightStartMs=None, lastLineMs=at(0, 47), malformedLines=0,
       responses=[resp("resp-3", at(0, 21), at(0, 24), 5000, 0, 0, 120, 40, "gpt-6.1-sol"),
                  resp("resp-4", at(0, 40), at(0, 47), 5200, 5000, 0, 60, 10, "gpt-6.1-sol")])

# --- Codex, legacy token_count only -------------------------------------------
rel = "codex/sessions/2026/10/20/rollout-2026-10-20T10-01-00-legacy.jsonl"
tA = cx(19515, 7040, 698, 368)
tB = cx(40000, 19000, 1000, 400)
lastB = cx(20485, 11960, 302, 32)
write_jsonl(rel, [
    codex(at(1, 0), "session_meta", {"id": "thread-legacy", "timestamp": ts(at(1, 0)),
                                     "cwd": "/Users/dev/projects/legacy-app", "originator": "codex_vscode"}),
    codex(at(1, 0, 100), "turn_context", {"cwd": "/Users/dev/projects/legacy-app", "model": "gpt-5.5"}),
    codex(at(1, 0, 500), "event_msg", {"type": "task_started", "turn_id": "t-1"}),
    codex(at(1, 0, 500), "event_msg", {"type": "user_message", "message": "hi"}),
    codex(at(1, 0, 600), "event_msg", {"type": "token_count", "info": None}),
    codex(at(1, 2), "response_item", {"type": "reasoning", "summary": []}),
    codex(at(1, 4), "event_msg", {"type": "token_count", "info": {"total_token_usage": tA, "last_token_usage": tA}}),
    codex(at(1, 4, 1), "event_msg", {"type": "token_count", "info": {"total_token_usage": tA, "last_token_usage": tA}}),
    codex(at(1, 6), "response_item", {"type": "function_call_output", "call_id": "c", "output": "x"}),
    codex(at(1, 9), "event_msg", {"type": "token_count", "info": {"total_token_usage": tB, "last_token_usage": lastB}}),
    codex(at(1, 9, 100), "event_msg", {"type": "task_complete", "turn_id": "t-1"}),
])
expect(rel, source="codex", project="legacy-app", model="gpt-5.5", isSubagent=False, parentFile=None,
       phase="idle", inFlightStartMs=None, lastLineMs=at(1, 9, 100), malformedLines=0,
       responses=[
           resp("codex-legacy:thread-legacy:20213", at(1, 0, 500), at(1, 4), 19515, 7040, 0, 698, 368, "gpt-5.5"),
           resp("codex-legacy:thread-legacy:41000", at(1, 6), at(1, 9), 20485, 11960, 0, 302, 32, "gpt-5.5"),
       ])


# --- Codex, compressed session (.jsonl.zst) -------------------------------------
# Two zstd frames split in the middle of a line, with a skippable frame between them.
rel = "codex/sessions/2026/10/20/rollout-2026-10-20T10-01-20-compressed.jsonl.zst"
z1 = cx(6000, 5000, 150, 40, 0)
z2 = cx(6300, 6000, 210, 0, 0)
zcum = cx(12300, 11000, 360, 40, 0)
zrows = [
    codex(at(1, 20), "session_meta", {"id": "thread-zst", "session_id": "sess-z", "timestamp": ts(at(1, 20)),
                                      "cwd": "/Users/dev/projects/comet", "originator": "codex_cli_rs",
                                      "cli_version": "0.170.0", "source": "cli", "model_provider": "custom"}),
    codex(at(1, 20, 100), "turn_context", {"cwd": "/Users/dev/projects/comet", "model": "gpt-6.1-sol-mini"}),
    codex(at(1, 21), "event_msg", {"type": "task_started", "turn_id": "turn-z"}),
    codex(at(1, 21), "event_msg", {"type": "user_message", "message": "Tidy up", "images": []}),
    codex(at(1, 21, 10), "response_item", {"type": "message", "role": "user",
                                           "content": [{"type": "input_text", "text": "Tidy up"}]}),
    codex(at(1, 24), "response_item", {"type": "function_call", "name": "shell", "arguments": "{}",
                                       "call_id": "call-z"}),
    codex(at(1, 24, 10), "token_usage_record", {"thread_id": "thread-zst", "session_id": "sess-z",
                                                "response_id": "resp-z1", "usage": z1,
                                                "turn_token_usage": z1, "thread_token_usage": z1}),
    codex(at(1, 24, 12), "event_msg", {"type": "token_count", "info": {"total_token_usage": z1, "last_token_usage": z1}}),
    codex(at(1, 25, 500), "response_item", {"type": "function_call_output", "call_id": "call-z", "output": "ok"}),
    codex(at(1, 27), "response_item", {"type": "message", "role": "assistant",
                                       "content": [{"type": "output_text", "text": "Tidied"}]}),
    codex(at(1, 28, 500), "token_usage_record", {"thread_id": "thread-zst", "session_id": "sess-z",
                                                 "response_id": "resp-z2", "usage": z2,
                                                 "turn_token_usage": z2, "thread_token_usage": zcum}),
    codex(at(1, 28, 502), "event_msg", {"type": "token_count", "info": {"total_token_usage": zcum, "last_token_usage": z2}}),
    codex(at(1, 28, 700), "event_msg", {"type": "task_complete", "turn_id": "turn-z"}),
]
ztext = "".join(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n" for r in zrows).encode("utf-8")
zsplit = ztext.index(b"resp-z1")
zpath = os.path.join(ROOT, rel)
os.makedirs(os.path.dirname(zpath), exist_ok=True)
with open(zpath, "wb") as f:
    f.write(subprocess.run(["zstd", "-q", "-c"], input=ztext[:zsplit], check=True, capture_output=True).stdout)
    f.write((0x184D2A50).to_bytes(4, "little") + (4).to_bytes(4, "little") + b"skip")
    f.write(subprocess.run(["zstd", "-q", "-c"], input=ztext[zsplit:], check=True, capture_output=True).stdout)
expect(rel, source="codex", project="comet", model="gpt-6.1-sol-mini", isSubagent=False, parentFile=None,
       phase="idle", inFlightStartMs=None, lastLineMs=at(1, 28, 700), malformedLines=0,
       responses=[
           resp("resp-z1", at(1, 21, 10), at(1, 24, 10), 6000, 5000, 0, 150, 40, "gpt-6.1-sol-mini",
                provider="custom"),
           resp("resp-z2", at(1, 25, 500), at(1, 28, 500), 6300, 6000, 0, 210, 0, "gpt-6.1-sol-mini",
                provider="custom"),
       ])

# --- Claude Code CLI ----------------------------------------------------------
def claude(kind, ms, entry="cli", cwd="/Users/dev/projects/nova", session="s-cli", sidechain=False, **extra):
    row = {"parentUuid": None, "isSidechain": sidechain, "userType": "external", "cwd": cwd,
           "sessionId": session, "version": "2.1.300", "entrypoint": entry, "type": kind}
    row.update(extra)
    row["timestamp"] = ts(ms)
    return row


def cl_usage(i, cc, cr, o, thinking=None, h1=None, speed=None):
    u = {"input_tokens": i, "cache_creation_input_tokens": cc, "cache_read_input_tokens": cr, "output_tokens": o,
         "service_tier": "standard"}
    if speed is not None:
        u["speed"] = speed
    if h1 is not None:
        u["cache_creation"] = {"ephemeral_5m_input_tokens": max(0, cc - h1), "ephemeral_1h_input_tokens": h1}
    if thinking is not None:
        u["output_tokens_details"] = {"thinking_tokens": thinking}
    return u


def assistant(ms, mid, content, usage, stop, model="claude-opus-5-5", **kw):
    return claude("assistant", ms, requestId="req_" + mid, uuid="uuid-" + mid + str(ms),
                  message={"id": mid, "type": "message", "role": "assistant", "model": model,
                           "content": [{"type": c} for c in content], "stop_reason": stop, "usage": usage}, **kw)


def user(ms, content, **kw):
    return claude("user", ms, uuid="u" + str(ms), message={"role": "user", "content": content}, **kw)


rel = "claude/projects/-Users-dev-projects-nova/s-cli.jsonl"
write_jsonl(rel, [
    {"type": "permission-mode", "permissionMode": "default", "sessionId": "s-cli"},
    user(at(2, 0), "Build the launch pad"),
    claude("api-request", at(2, 0, 50), id="api-1", params={"model": "claude-opus-5-5"}),
    claude("attachment", at(2, 0, 60), attachment={"type": "todo"}),
    assistant(at(2, 4), "msg_A", ["thinking"], cl_usage(2, 1000, 20000, 150, 60, h1=600), None),
    assistant(at(2, 6, 50), "msg_A", ["tool_use"], cl_usage(2, 1000, 20000, 300, 60, h1=600), "tool_use"),
    user(at(2, 9), [{"type": "tool_result", "tool_use_id": "t1", "content": "ok"}]),
    assistant(at(2, 12), "msg_B", ["text"], cl_usage(5, 200, 21000, 240, speed="standard"), "end_turn"),
    assistant(at(2, 12, 500), "msg_SYN", ["text"], cl_usage(0, 0, 0, 0), "stop_sequence", model="<synthetic>"),
    claude("system", at(2, 13), subtype="turn_duration"),
    user(at(2, 20), "Now polish it"),
    user(at(2, 25), [{"type": "text", "text": "[Request interrupted by user]"}]),
])
expect(rel, source="claudeCode", project="nova", model="claude-opus-5-5", isSubagent=False, parentFile=None,
       phase="idle", inFlightStartMs=None, lastLineMs=at(2, 25), malformedLines=0,
       responses=[
           resp("msg_A", at(2, 0, 50), at(2, 6, 50), 21002, 20000, 1000, 300, 60, "claude-opus-5-5", cw1h=600),
           resp("msg_B", at(2, 9), at(2, 12), 21205, 21000, 200, 240, 0, "claude-opus-5-5"),
       ])

# --- Claude Code sub-agent ----------------------------------------------------
rel = "claude/projects/-Users-dev-projects-nova/s-cli/subagents/agent-abc.jsonl"
write_jsonl(rel, [
    user(at(2, 7), "Search the codebase", sidechain=True, agentId="abc"),
    assistant(at(2, 10), "msg_D", ["tool_use"], cl_usage(4, 500, 0, 90, h1=800), "tool_use", sidechain=True,
              agentId="abc"),
    user(at(2, 11), [{"type": "tool_result", "tool_use_id": "t2", "content": "found"}], sidechain=True,
         agentId="abc"),
    assistant(at(2, 14), "msg_E", ["thinking"], cl_usage(2, 0, 600, 8), None, sidechain=True, agentId="abc"),
    assistant(at(2, 15), "msg_E", ["tool_use"], cl_usage(2, 0, 600, 8), None, sidechain=True, agentId="abc"),
    user(at(2, 16), [{"type": "tool_result", "tool_use_id": "t3", "content": "done"}], sidechain=True,
         agentId="abc"),
])
expect(rel, source="claudeCode", project="nova", model="claude-opus-5-5", isSubagent=True,
       parentFile="claude/projects/-Users-dev-projects-nova/s-cli.jsonl",
       phase="generating", inFlightStartMs=at(2, 16), lastLineMs=at(2, 16), malformedLines=0,
       responses=[resp("msg_D", at(2, 7), at(2, 10), 504, 0, 500, 90, 0, "claude-opus-5-5", cw1h=500),
                  resp("msg_E", at(2, 11), at(2, 15), 602, 600, 0, 8, 0, "claude-opus-5-5", final=False)])

# --- Claude Desktop, resumed session that copies msg_B ------------------------
rel = "claude/projects/-Users-dev-projects-orbit/s-desk.jsonl"
d = dict(entry="claude-desktop", cwd="/Users/dev/projects/orbit", session="s-desk")
write_jsonl(rel, [
    {"type": "custom-title", "customTitle": "Orbit", "sessionId": "s-desk"},
    user(at(2, 9), [{"type": "tool_result", "tool_use_id": "t1", "content": "ok"}],
         **dict(d, entry="claude-desktop-3p")),
    assistant(at(2, 12), "msg_B", ["text"], cl_usage(5, 200, 21000, 240), "end_turn", **d),
    user(at(3, 0), "Plan the orbit", **d),
    assistant(at(3, 5), "msg_C", ["tool_use"], cl_usage(3, 0, 30000, 500, speed="fast"), "tool_use", **d),
])
expect(rel, source="claudeDesktop", project="orbit", model="claude-opus-5-5", isSubagent=False, parentFile=None,
       phase="tools", inFlightStartMs=None, lastLineMs=at(3, 5), malformedLines=0,
       responses=[resp("msg_C", at(3, 0), at(3, 5), 30003, 30000, 0, 500, 0, "claude-opus-5-5", fast=True)])


# --- DeepSeek Harness (dsh): zstd frame streams ------------------------------


def write_zstd(rel, frames):
    path = os.path.join(ROOT, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        for rows in frames:
            text = "".join((r if isinstance(r, str) else json.dumps(r, ensure_ascii=False, separators=(",", ":"))) + "\n"
                           for r in rows)
            f.write(subprocess.run(["zstd", "-q", "-c", "--no-content-size"], input=text.encode("utf-8"),
                                   check=True, capture_output=True).stdout)


def dsh(kind, seq, ms, data, **extra):
    row = {"type": kind, "seq": seq, "time": ms, "data": data}
    row.update(extra)
    return row


def dsh_usage(i, o, cr, cw):
    return {"inputTokens": i, "outputTokens": o, "cacheReadTokens": cr, "cacheWriteTokens": cw,
            "totalTokens": i + o + cr}


def dsh_message(seq, ms, mid, blocks, model, usage):
    return dsh("assistant/message", seq, ms, {
        "turn": 1, "step": seq,
        "message": {"role": "assistant", "content": [{"type": b} for b in blocks],
                    "source": {"kind": "model", "provider": "deepseek-account", "model": model}, "id": mid},
        "usage": usage, "stream": [{"type": "chunk", "time": ms - 100, "chunk": {"type": "usage", "usage": usage}}]},
        surfaceOp="append")


rel = "dsh/sessions/--Users-dev-projects-quasar--/session-dsh-main/session.v4.jsonl.zstd"
write_zstd(rel, [
    [{"type": "session", "version": 4, "id": "session-dsh-main", "createdAt": at(4, 0),
      "cwd": "/Users/dev/projects/quasar", "isSeeded": False, "delegationDepth": 0, "agentPreset": "standard"}],
    [dsh("permission/preset", 1, at(4, 0, 10), {"preset": "default"}), dsh("turn/start", 2, at(4, 1), {"turn": 1})],
    [dsh("step/start", 3, at(4, 1), {"turn": 1, "step": 1}),
     dsh("user/message", 4, at(4, 1, 5), {"content": [{"type": "text", "text": "Fix the build"}], "role": "user"}),
     dsh("request/header", 5, at(4, 1, 10), {"header": {"config": {"provider": "deepseek-account",
                                                                    "model": "deepseek-flash"}}})],
    [dsh("session-log-deepseek/delivery-accepted", 6, at(4, 1, 400), {"throughSeq": 5})],
    [dsh_message(7, at(4, 5), "dsm-1", ["reasoning", "tool-call"], "deepseek-flash", dsh_usage(9000, 400, 0, 0))],
    [dsh("tool/call", 8, at(4, 5, 2), {"callId": "c1", "name": "bash"}),
     dsh("tool/result", 9, at(4, 6), {"message": {"role": "tool", "toolCallId": "c1"}}),
     dsh("step/end", 10, at(4, 6), {"turn": 1, "step": 1})],
    [dsh("step/start", 11, at(4, 6, 10), {"turn": 1, "step": 2})],
    [dsh_message(12, at(4, 8, 10), "dsm-2", ["text"], "deepseek-flash", dsh_usage(120, 300, 9216, 64)),
     dsh_message(13, at(4, 8, 20), "dsm-2", ["text"], "deepseek-flash", dsh_usage(120, 300, 9216, 64))],
    [dsh("step/end", 14, at(4, 8, 25), {"turn": 1, "step": 2}),
     dsh("turn/end", 15, at(4, 8, 30), {"turn": 1, "reason": {"kind": "completed"}}),
     "this line is not json"],
])
expect(rel, source="deepseek", project="quasar", model="deepseek-flash", isSubagent=False, parentFile=None,
       phase="idle", inFlightStartMs=None, lastLineMs=at(4, 8, 30), malformedLines=1,
       responses=[
           resp("dsm-1", at(4, 1), at(4, 5), 9000, 0, 0, 400, 0, "deepseek-flash", provider="deepseek-account"),
           resp("dsm-2", at(4, 6, 10), at(4, 8, 10), 9400, 9216, 64, 300, 0, "deepseek-flash",
                provider="deepseek-account"),
       ])

rel = "dsh/sessions/--Users-dev-projects-quasar--/session-dsh-sub/session.v4.jsonl.zstd"
write_zstd(rel, [
    [{"type": "session", "version": 4, "id": "session-dsh-sub", "createdAt": at(4, 10),
      "cwd": "/Users/dev/projects/quasar", "parentSession": "session-dsh-main", "isSeeded": True,
      "origin": "subagent", "delegationDepth": 1, "agentPreset": "explore"}],
    [dsh("step/start", 3, at(4, 1), {"turn": 1, "step": 1}),
     dsh_message(7, at(4, 5), "dsm-1", ["reasoning", "tool-call"], "deepseek-flash", dsh_usage(9000, 400, 0, 0))],
    [dsh("step/start", 20, at(4, 11), {"turn": 1, "step": 1}),
     dsh("request/header", 21, at(4, 11, 5), {"header": {"config": {"model": "deepseek-pro"}}})],
    [dsh_message(22, at(4, 14), "dss-1", ["tool-call"], "deepseek-pro", dsh_usage(500, 240, 4000, 0))],
    [dsh("tool/call", 23, at(4, 14, 5), {"callId": "c9", "name": "grep"}),
     dsh("tool/result", 24, at(4, 15), {"message": {"role": "tool", "toolCallId": "c9"}})],
    [dsh("step/start", 25, at(4, 15, 10), {"turn": 1, "step": 2})],
])
expect(rel, source="deepseek", project="quasar", model="deepseek-pro", isSubagent=True,
       parentFile="dsh/sessions/--Users-dev-projects-quasar--/session-dsh-main/session.v4.jsonl.zstd",
       phase="generating", inFlightStartMs=at(4, 15, 10), lastLineMs=at(4, 15, 10), malformedLines=0,
       responses=[resp("dss-1", at(4, 11), at(4, 14), 4500, 4000, 0, 240, 0, "deepseek-pro",
                       provider="deepseek-account")])


# --- OpenCode: SQLite database -------------------------------------------------
import sqlite3

opencode_rel = "opencode/opencode.db"
oc_path = os.path.join(ROOT, opencode_rel)
os.makedirs(os.path.dirname(oc_path), exist_ok=True)
if os.path.exists(oc_path):
    os.remove(oc_path)
oc = sqlite3.connect(oc_path)
oc.executescript("""
CREATE TABLE session_v2 (id text PRIMARY KEY, project_id text NOT NULL, parent_id text, slug text NOT NULL,
  directory text NOT NULL, version text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL);
CREATE TABLE session_message (id text PRIMARY KEY, session_id text NOT NULL, type text NOT NULL, seq integer NOT NULL,
  time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
CREATE INDEX session_message_time_created_idx ON session_message (time_created);
""")


def oc_tokens(i, o, r, cr, cw):
    return {"input": i, "output": o, "reasoning": r, "cache": {"read": cr, "write": cw}}


def oc_row(rid, sid, kind, seq, created, updated, data):
    oc.execute("INSERT INTO session_message VALUES (?,?,?,?,?,?,?)",
               (rid, sid, kind, seq, created, updated, json.dumps(data, separators=(",", ":"))))


oc.execute("INSERT INTO session_v2 VALUES (?,?,?,?,?,?,?,?)",
           ("ses_main", "prj", None, "main", "/Users/dev/projects/nebula", "2.0.32", at(5, 0), at(5, 48)))
oc.execute("INSERT INTO session_v2 VALUES (?,?,?,?,?,?,?,?)",
           ("ses_sub", "prj", "ses_main", "sub", "/Users/dev/projects/nebula", "2.0.32", at(5, 20), at(5, 30)))
opus = {"id": "claude-opus-5-5", "providerID": "anthropic"}
sonnet = {"id": "claude-sonnet-5-5", "providerID": "anthropic"}
oc_row("u1", "ses_main", "user", 1, at(5, 1), at(5, 1), {"text": "Plan it", "time": {"created": at(5, 1)}})
oc_row("msg_oc1", "ses_main", "assistant", 2, at(5, 1, 10), at(5, 5, 20),
       {"time": {"created": at(5, 1, 10), "streamed": at(5, 5, 10), "completed": at(5, 5, 20)}, "model": opus,
        "finish": "tool-calls", "tokens": oc_tokens(4, 300, 100, 1000, 200), "content": [{"type": "tool"}]})
oc_row("msg_oc2", "ses_main", "assistant", 3, at(5, 40), at(5, 42, 10),
       {"time": {"created": at(5, 40), "streamed": at(5, 42), "completed": at(5, 42, 10)}, "model": opus,
        "finish": "stop", "tokens": oc_tokens(2, 150, 0, 1200, 0), "content": [{"type": "text"}]})
oc_row("cmp_1", "ses_main", "compaction", 4, at(5, 43), at(5, 47),
       {"time": {"created": at(5, 43), "completed": at(5, 47)}, "model": {"id": "claude-haiku-5"},
        "tokens": oc_tokens(5000, 800, 0, 0, 0), "status": "done"})
oc_row("idle1", "ses_main", "idle", 5, at(5, 48), at(5, 48), {"outcome": "completed", "time": {"created": at(5, 48)}})
oc_row("msg_copy", "ses_sub", "assistant", 1, at(5, 20), at(5, 20),
       {"time": {"created": at(5, 1, 10), "streamed": at(5, 5, 10), "completed": at(5, 5, 20)}, "model": opus,
        "finish": "tool-calls", "tokens": oc_tokens(4, 300, 100, 1000, 200)})
oc_row("msg_oc3", "ses_sub", "assistant", 2, at(5, 21), at(5, 24, 5),
       {"time": {"created": at(5, 21), "streamed": at(5, 24), "completed": at(5, 24, 5)}, "model": sonnet,
        "finish": "tool-calls", "tokens": oc_tokens(3, 90, 30, 0, 500)})
oc_row("msg_oc4", "ses_sub", "assistant", 3, at(5, 30), at(5, 30),
       {"time": {"created": at(5, 30)}, "model": sonnet, "content": []})
oc.commit()
oc.close()
opencode_expected = {
    "opencode:ses_main": dict(source="opencode", project="nebula", model="claude-opus-5-5", isSubagent=False,
                              parentId=None, phase="idle", inFlightStartMs=None, lastLineMs=at(5, 48),
                              responses=[
                                  resp("msg_oc1", at(5, 1, 10), at(5, 5, 10), 1204, 1000, 200, 400, 100,
                                       "claude-opus-5-5", provider="anthropic"),
                                  resp("msg_oc2", at(5, 40), at(5, 42), 1202, 1200, 0, 150, 0, "claude-opus-5-5",
                                       provider="anthropic"),
                                  resp("cmp_1", at(5, 43), at(5, 47), 5000, 0, 0, 800, 0, "claude-haiku-5"),
                              ]),
    "opencode:ses_sub": dict(source="opencode", project="nebula", model="claude-sonnet-5-5", isSubagent=True,
                             parentId="opencode:ses_main", phase="generating", inFlightStartMs=at(5, 30),
                             lastLineMs=at(5, 30),
                             responses=[resp("msg_oc3", at(5, 21), at(5, 24), 503, 0, 500, 120, 30,
                                             "claude-sonnet-5-5", provider="anthropic")]),
}

# --- Gemini CLI -----------------------------------------------------------------
# Modification times: git does not keep them, so tests that depend on startup order (history) apply these first.
mtimes = {}
for rel in order:
    when = int(math.ceil((files[rel]["lastLineMs"] + 1000) / 1000) * 1000)
    mtimes[rel] = max(when, max(mtimes.values(), default=0) + 1000)
    os.utime(os.path.join(ROOT, rel), (mtimes[rel] / 1000, mtimes[rel] / 1000))
gemini = gemini_fixtures.write_fixtures(ROOT)
assert min(gemini["mtimes"].values()) > max(mtimes.values())
order += gemini["order"]
files.update(gemini["files"])
mtimes.update(gemini["mtimes"])

# --- omp ------------------------------------------------------------------------
omp = omp_fixtures.write_fixtures(ROOT)
assert min(omp["mtimes"].values()) > max(mtimes.values())
order += omp["order"]
files.update(omp["files"])
mtimes.update(omp["mtimes"])

# --- Antigravity: one SQLite database per conversation ---------------------------
antigravity = antigravity_fixtures.write_fixtures(ROOT)
assert min(antigravity["mtimes"].values()) > max(mtimes.values())
mtimes.update(antigravity["mtimes"])

# --- WorkBuddy: both editions, one parser ---------------------------------------
workbuddy = workbuddy_fixtures.write_fixtures(ROOT)
assert min(workbuddy["mtimes"].values()) > max(mtimes.values())
order += workbuddy["order"]
files.update(workbuddy["files"])
mtimes.update(workbuddy["mtimes"])

with open(os.path.join(ROOT, "parser-expected.json"), "w", encoding="utf-8") as f:
    json.dump({"_comment": "Process files in `order` with one shared dedupe set, then the OpenCode database, then the "
                           "Antigravity databases in `antigravity.order` (same dedupe set). Paths are relative to this "
                           "folder. `mtimes` (Unix ms) give the modification times that produce both orders; apply "
                           "them to a copy of this folder before computing daily history. `traces` (Gemini, omp) give "
                           "the phase after feeding a file up to and including physical line `afterLine` (after the "
                           "files before it in `order`). omp: the folder `omp` plays ~/.omp, so its automatic roots "
                           "are omp/agent/sessions and omp/profiles/*/agent/sessions; `omp.discover` lists what "
                           "discovery finds there. Antigravity: the folder `antigravity` plays ~/.gemini (stores "
                           "antigravity-cli, antigravity, antigravity-ide); each database is one agent whose id is its "
                           "path; `{\"unsupported\": true}` marks a database that contributes no agent; reading must "
                           "not create any file (no -wal or -shm). WorkBuddy: the folder `workbuddy` plays the home "
                           "folder (data folders .workbuddy and .workbuddy-ai); `workbuddy.discover` lists what "
                           "discovery finds in both projects folders; its `traces` work like the omp ones.",
               "order": order, "files": files, "mtimes": mtimes,
               "opencode": {"database": opencode_rel, "agents": opencode_expected},
               "gemini": {"discover": gemini["discover"], "traces": gemini["traces"]},
               "omp": {"discover": omp["discover"], "traces": omp["traces"], "tailReads": omp["tailReads"]},
               "antigravity": {"order": antigravity["order"], "discover": antigravity["discover"],
                               "databases": antigravity["databases"]},
               "workbuddy": {"discover": workbuddy["discover"], "traces": workbuddy["traces"]}},
              f, indent=2, ensure_ascii=False)
    f.write("\n")

# --- Price tables and cost cases (METRICS 9) ----------------------------------
# Fictional, stable prices: tests never change when the real table (spec/assets/prices.json) changes.
NORMALIZE = {
    "freeProviders": ["ollama", "lmstudio", "lm-studio", "llama.cpp", "llamacpp", "vllm", "local"],
    "cloudSuffixes": ["-cloud", ":cloud"],
    "bedrockRegions": ["global", "us", "eu", "apac", "jp", "au", "ca", "in", "us-gov"],
    "bedrockVendors": ["anthropic", "openai", "google", "meta", "mistral", "deepseek", "qwen", "moonshotai",
                       "minimax", "zai", "xai", "amazon"],
    "freeSuffixes": [":free", "-free"],
    "variantSuffixes": [":thinking", ":extended", ":nitro", ":floor", ":exacto", ":online"],
    "fastSuffixes": ["-fast"],
    "rewrites": [{"prefix": "duo-chat-opus-", "to": "claude-opus-"},
                 {"prefix": "duo-chat-sonnet-", "to": "claude-sonnet-"},
                 {"prefix": "duo-chat-haiku-", "to": "claude-haiku-"}],
    "dateSuffixPrefixes": ["claude-"],
    "modifierSuffixes": [{"prefix": "claude-", "suffixes": ["-thinking", "-minimal", "-low", "-medium", "-high",
                                                            "-xhigh", "-max", "-none", "-off"]},
                         {"prefix": "gemini-", "suffixes": ["-low", "-medium", "-high", "-tiered"]}],
    "dotHyphenPrefixes": ["claude-"],
}
FIXTURE_URL = "https://example.com/fixture-prices"


def price_model(mid, provider, prices=None, tiers=None, aliases=None, free=False, periods=None, fast=None,
                off_peak=None):
    m = {"id": mid, "provider": provider, "name": mid, "status": "current"}
    if free:
        m["free"] = True
    else:
        m["prices"] = prices
        if tiers:
            m["tiers"] = tiers
        if off_peak:
            m["offPeak"] = off_peak
        if periods:
            m["periods"] = periods
        if fast:
            m["fast"] = {"prices": fast}
    if aliases:
        m["aliases"] = aliases
    m.update(source=FIXTURE_URL, checked="2026-10-01")
    return m


def pr(inp, cached=None, write=None, write1h=None, out=None, above=None):
    p = {} if above is None else {"above": above}
    p["input"] = inp
    for k, v in (("cachedInput", cached), ("cacheWrite", write), ("cacheWrite1h", write1h)):
        if v is not None:
            p[k] = v
    p["output"] = out
    return p


DEEPSEEK_PEAK = {"peakUtc": ["01:00-04:00", "06:00-10:00"], "peakWeekdays": [1, 2, 3, 4, 5],
                 "offPeakDates": ["2026-10-01"]}


def price_table(version, updated, opus, opus_tier, opus_fast, pro31_out, extra=()):
    models = [
        price_model("claude-opus-5-5", "anthropic", opus, [opus_tier], fast=opus_fast),
        price_model("claude-sonnet-5-5", "anthropic", pr(3, 0.3, 3.75, 6, 15)),
        price_model("claude-sonnet-4-5", "anthropic", pr(3, 0.3, 3.75, 6, 15),
                    [pr(6, 0.6, 7.5, 12, 22.5, above=200_000)]),
        price_model("claude-haiku-5", "anthropic", pr(1, 0.1, 1.25, 2, 5)),
        price_model("gpt-5.5", "openai", pr(1.25, 0.125, out=10), aliases=["gpt5.5"]),
        price_model("gpt-5.5-mini", "openai", pr(0.25, 0.025, out=2)),
        price_model("gpt-6.1-sol", "openai", pr(2, 0.2, out=16), [pr(4, 0.4, out=24, above=272_000)]),
        price_model("deepseek-flash", "deepseek", pr(0.28, 0.028, out=0.42),
                    periods=[{"to": "2026-09-01", "prices": pr(0.5, 0.05, out=1)}]),
        price_model("deepseek-pro", "deepseek", pr(0.6, 0.06, out=2.4),
                    off_peak=dict(DEEPSEEK_PEAK, prices=pr(0.3, 0.03, out=1.2))),
        price_model("gemini-2.5-pro", "google", pr(1.25, 0.125, out=10), [pr(2.5, 0.25, out=15, above=200_000)]),
        price_model("gemini-2.5-flash", "google", pr(0.3, 0.03, out=2.5)),
        price_model("gemini-3-pro-preview", "google", pr(2, 0.2, out=12), [pr(4, 0.4, out=18, above=200_000)]),
        price_model("gemini-3-flash-preview", "google", pr(0.5, 0.05, out=3),
                    periods=[{"from": "2026-12-01T00:00Z", "prices": pr(1, 0.1, out=6),
                              "tiers": [pr(2, 0.2, out=9, above=200_000)]}]),
        price_model("gemini-3.1-pro", "google", pr(2, 0.2, out=pro31_out),
                    aliases=["gemini-3.1-pro-high", "gemini-3.1-pro-low", "gemini-3.1-pro-high-exp-b",
                             "gemini 3.1 pro (high)"]),
        price_model("gemini-3.1-flash", "google", pr(0.5, 0.05, out=3), aliases=["gemini-3.1-flash-b"]),
        price_model("gemini-3.1-flash-lite", "google", free=True),
        price_model("plain-model-1", "fixture", pr(1, out=2)),
    ] + list(extra)
    return {"_comment": "Fixture price table (fictional prices) for spec/fixtures/price-cases.json, engine cases "
                        "and history-expected.json. Never edit by hand: spec/tools/generate_fixtures.py.",
            "schema": 1, "version": version, "updated": updated, "currency": "USD", "unit": "perMillionTokens",
            "providers": {k: {"name": k, "url": FIXTURE_URL} for k in
                          ("anthropic", "openai", "google", "deepseek", "fixture")},
            "normalize": NORMALIZE,
            "models": models,
            "unknown": [{"match": "prefix", "value": "neko-model-", "reason": "opaque local router alias"},
                        {"match": "exact", "value": "codex-auto-review", "reason": "internal model, no public price"}],
            "tests": [{"model": "claude-opus-5-5", "expect": "claude-opus-5-5"},
                      {"model": "duo-chat-sonnet-5-5", "expect": "claude-sonnet-5-5"},
                      {"model": "neko-model-f1097c63", "expect": "unknown"}]}


price_v1 = price_table(1, "2026-10-01", pr(5, 0.5, 6.25, 10, 25), pr(10, 1, 12.5, 20, 37.5, above=200_000),
                       pr(10, 1, 12.5, 20, 50), 12)
price_v2 = price_table(2, "2026-10-15", pr(4, 0.4, 5, 8, 20), pr(8, 0.8, 10, 16, 30, above=200_000),
                       pr(8, 0.8, 10, 16, 40), 10, [price_model("gpt-6.1-sol-mini", "openai", pr(0.4, 0.04, out=3.2))])
os.makedirs(os.path.join(ROOT, "prices"), exist_ok=True)
for table in (price_v1, price_v2):
    with open(os.path.join(ROOT, "prices", "v%d.json" % table["version"]), "w", encoding="utf-8") as f:
        json.dump(table, f, indent=2, ensure_ascii=False)
        f.write("\n")


def pico(*pairs):
    """Independent expectation: sum of tokens x USD per million tokens, in pico-USD."""
    from decimal import Decimal
    return int(sum(Decimal(t) * Decimal(str(p)) * 1_000_000 for t, p in pairs))


def tk(inp, cached=0, write=0, write1h=0, out=0):
    return {"input": inp, "cachedInput": cached, "cacheWriteInput": write, "cacheWrite1hInput": write1h,
            "output": out, "reasoning": 0}


def cost_case(name, table, model, tokens, pico_usd, tier=None, provider=None):
    exp = {"costPicoUsd": pico_usd, "costMicroUsd": None if pico_usd is None else (pico_usd + 500_000) // 1_000_000,
           "tier": tier}
    case = {"name": name, "table": table, "model": model, "tokens": tokens, "expect": exp}
    if provider is not None:
        case["provider"] = provider
    return case


cost_cases = [
    cost_case("uncached, cache read, 5-minute and 1-hour cache writes, output", "v2", "claude-opus-5-5",
              tk(21002, 20000, 1000, 600, 300), pico((2, 4), (20000, 0.4), (400, 5), (600, 8), (300, 20))),
    cost_case("a long-context tier prices the whole response", "v2", "claude-opus-5-5",
              tk(250_000, 200_000, 0, 0, 1000), pico((50_000, 8), (200_000, 0.8), (1000, 30)), tier=0),
    cost_case("the threshold is exclusive", "v2", "claude-opus-5-5", tk(200_000, 0, 0, 0, 10),
              pico((200_000, 4), (10, 20))),
    cost_case("the tier counts cached and cache-write input", "v1", "gemini-2.5-pro",
              tk(200_001, 150_000, 0, 0, 100), pico((50_001, 2.5), (150_000, 0.25), (100, 15)), tier=0),
    cost_case("1-hour writes are clamped to the cache writes", "v2", "claude-sonnet-5-5", tk(1500, 0, 500, 900, 10),
              pico((1000, 3), (500, 6), (10, 15))),
    cost_case("missing cache prices fall back to the input price", "v2", "plain-model-1",
              tk(1000, 600, 100, 0, 50), pico((300, 1), (600, 1), (100, 1), (50, 2))),
    cost_case("cache read and write exceeding input never go negative", "v2", "gpt-5.5", tk(100, 100, 50, 0, 0),
              pico((100, 0.125), (50, 1.25))),
    cost_case("half a micro-dollar rounds up", "v2", "gpt-5.5", tk(4, 4, 0, 0, 0), 500_000),
    cost_case("below half a micro-dollar rounds down", "v2", "gpt-5.5", tk(3, 3, 0, 0, 0), 375_000),
    cost_case("token classes are clamped to 100 000 000 tokens", "v2", "gpt-5.5", tk(250_000_000, 0, 0, 0, 0),
              pico((100_000_000, 1.25))),
    cost_case("reasoning is billed as output", "v2", "deepseek-flash", dict(tk(1000, 0, 0, 0, 500), reasoning=400),
              pico((1000, 0.28), (500, 0.42))),
    cost_case("a free model costs zero", "v2", "gemini-3.1-flash-lite", tk(5000, 0, 0, 0, 500), 0),
    cost_case("a free provider costs zero", "v2", "qwen3-coder:30b", tk(5000, 0, 0, 0, 500), 0, provider="ollama"),
    cost_case("an unknown model has no cost", "v1", "gpt-6.1-sol-mini", tk(5000, 0, 0, 0, 500), None),
    cost_case("the same model is priced once the table knows it", "v2", "gpt-6.1-sol-mini", tk(5000, 0, 0, 0, 500),
              pico((5000, 0.4), (500, 3.2))),
    dict(cost_case("a period applies before its `to` instant", "v2", "deepseek-flash", tk(1000, 0, 0, 0, 100),
                   pico((1000, 0.5), (100, 1))), at="2026-08-31T23:59Z"),
    dict(cost_case("from its `to` instant the main prices apply", "v2", "deepseek-flash", tk(1000, 0, 0, 0, 100),
                   pico((1000, 0.28), (100, 0.42))), at="2026-09-01"),
    dict(cost_case("a scheduled period applies from its `from` instant, with its own tiers", "v2",
                   "gemini-3-flash-preview", tk(300_000, 100_000, 0, 0, 100),
                   pico((200_000, 2), (100_000, 0.2), (100, 9)), tier=0), at="2026-12-01T00:00Z"),
    dict(cost_case("before a scheduled period the main prices apply", "v2", "gemini-3-flash-preview",
                   tk(300_000, 100_000, 0, 0, 100), pico((200_000, 0.5), (100_000, 0.05), (100, 3))),
         at="2026-11-30T23:59Z"),
    dict(cost_case("inside a peak window on a weekday: the main prices", "v2", "deepseek-pro", tk(1000, 0, 0, 0, 100),
                   pico((1000, 0.6), (100, 2.4))), at="2026-10-20T03:00Z"),
    dict(cost_case("outside the peak windows: off-peak prices", "v2", "deepseek-pro", tk(1000, 0, 0, 0, 100),
                   pico((1000, 0.3), (100, 1.2))), at="2026-10-20T05:00Z"),
    dict(cost_case("a window's end is exclusive", "v2", "deepseek-pro", tk(1000, 0, 0, 0, 100),
                   pico((1000, 0.3), (100, 1.2))), at="2026-10-20T04:00Z"),
    dict(cost_case("weekends are off-peak", "v2", "deepseek-pro", tk(1000, 0, 0, 0, 100),
                   pico((1000, 0.3), (100, 1.2))), at="2026-10-24T03:00Z"),
    dict(cost_case("an off-peak date is off-peak all day", "v2", "deepseek-pro", tk(1000, 0, 0, 0, 100),
                   pico((1000, 0.3), (100, 1.2))), at="2026-10-01T03:00Z"),
    dict(cost_case("fast mode uses the fast prices", "v2", "claude-opus-5-5", tk(1000, 600, 100, 0, 50),
                   pico((300, 8), (600, 0.8), (100, 10), (50, 40))), fast=True),
    cost_case("a -fast id uses the fast prices", "v2", "claude-opus-5-5-fast", tk(1000, 600, 100, 0, 50),
              pico((300, 8), (600, 0.8), (100, 10), (50, 40))),
    dict(cost_case("fast mode without a fast price is unknown", "v2", "claude-sonnet-5-5", tk(1000, 0, 0, 0, 50),
                   None), fast=True),
]
day_cases = [
    {"name": "a bound day keeps its table", "bindings": {"2026-10-20": 1}, "date": "2026-10-20",
     "model": "claude-opus-5-5", "tokens": tk(1000, 0, 0, 0, 100), "version": 1,
     "costMicroUsd": (pico((1000, 5), (100, 25)) + 500_000) // 1_000_000},
    {"name": "an unbound day binds to the current table", "bindings": {"2026-10-20": 1}, "date": "2026-10-21",
     "model": "claude-opus-5-5", "tokens": tk(1000, 0, 0, 0, 100), "version": 2,
     "costMicroUsd": (pico((1000, 4), (100, 20)) + 500_000) // 1_000_000},
    {"name": "a response its day's table cannot price takes the current table", "bindings": {"2026-10-20": 1},
     "date": "2026-10-20", "model": "gpt-6.1-sol-mini", "tokens": tk(5000, 0, 0, 0, 500), "version": 1,
     "costMicroUsd": (pico((5000, 0.4), (500, 3.2)) + 500_000) // 1_000_000},
    {"name": "a binding to a missing table is replaced by the current table", "bindings": {"2026-10-19": 7},
     "date": "2026-10-19", "model": "claude-opus-5-5", "tokens": tk(1000, 0, 0, 0, 100), "version": 2,
     "costMicroUsd": (pico((1000, 4), (100, 20)) + 500_000) // 1_000_000},
    {"name": "unknown in every table stays unknown", "bindings": {}, "date": "2026-10-20",
     "model": "neko-model-f1097c63", "tokens": tk(5000, 0, 0, 0, 500), "version": 2, "costMicroUsd": None},
]
resolve_cases = [{"table": t, "model": m, "provider": p, "expect": e} for t, m, p, e in [
    ("v2", "claude-opus-5-5", None, "claude-opus-5-5"),
    ("v2", "  Claude-Opus-5-5 ", None, "claude-opus-5-5"),
    ("v2", "claude-opus-5-5[1m]", None, "claude-opus-5-5"),
    ("v2", "[Proxy] claude-opus-5-5", None, "claude-opus-5-5"),
    ("v2", "anthropic/claude-sonnet-4.5", None, "claude-sonnet-4-5"),
    ("v2", "openrouter/anthropic/claude-sonnet-4.5:thinking", None, "claude-sonnet-4-5"),
    ("v2", "openai/gpt-5.5:nitro:exacto", None, "gpt-5.5"),
    ("v2", "us.anthropic.claude-sonnet-4-5-20250929-v1:0", None, "claude-sonnet-4-5"),
    ("v2", "global.anthropic.claude-opus-5-5-v1", None, "claude-opus-5-5"),
    ("v2", "anthropic.claude-opus-5-5", None, "claude-opus-5-5"),
    ("v2", "claude-sonnet-4-5@20250929", None, "claude-sonnet-4-5"),
    ("v2", "claude-opus-5-5@default", None, "claude-opus-5-5"),
    ("v2", "claude-opus-5-5-thinking", None, "claude-opus-5-5"),
    ("v2", "claude-opus-5-5-xhigh", None, "claude-opus-5-5"),
    ("v2", "claude-sonnet-4-5-thinking-high", None, "claude-sonnet-4-5"),
    ("v2", "Claude-opus-5-5-off", None, "claude-opus-5-5"),
    ("v2", "claude-opus-5-5-fast", None, "claude-opus-5-5 fast"),
    ("v2", "anthropic/claude-opus-5.5-fast", None, "claude-opus-5-5 fast"),
    ("v2", "claude-sonnet-5-5-fast", None, "unknown"),
    ("v2", "claude-opus-5.5", None, "claude-opus-5-5"),
    ("v2", "claude-opus-5-5-latest", None, "unknown"),
    ("v2", "gpt-5.5-2026-04-23", None, "unknown"),
    ("v2", "gpt5.5", None, "gpt-5.5"),
    ("v2", "gpt-5.5-mini", None, "gpt-5.5-mini"),
    ("v2", "gpt-5.5-pro", None, "unknown"),
    ("v2", "gpt-5.5-high", None, "unknown"),
    ("v2", "Gemini 3.1 Pro (High)", None, "gemini-3.1-pro"),
    ("v2", "models/gemini-2.5-pro", None, "gemini-2.5-pro"),
    ("v2", "gemini-2.5-flash-low", None, "gemini-2.5-flash"),
    ("v2", "gemini-3.1-flash-b", None, "gemini-3.1-flash"),
    ("v2", "gemini-3.1-flash-lite", None, "free"),
    ("v2", "deepseek/deepseek-flash:free", None, "free"),
    ("v2", "big-model-free", None, "free"),
    ("v2", "duo-chat-sonnet-5-5", None, "claude-sonnet-5-5"),
    ("v2", "qwen3-coder:30b", "Ollama", "free"),
    ("v2", "qwen3-coder:30b", None, "unknown"),
    ("v2", "gpt-oss:120b-cloud", "ollama", "unknown"),
    ("v2", "claude-opus-5-5", "lmstudio", "free"),
    ("v2", "claude-opus-5-5", "custom", "claude-opus-5-5"),
    ("v2", "neko-model-f1097c63", None, "unknown"),
    ("v2", "codex-auto-review", None, "unknown"),
    ("v2", "", None, "unknown"),
    ("v2", None, None, "unknown"),
    ("v1", "gpt-6.1-sol-mini", None, "unknown"),
    ("v2", "gpt-6.1-sol-mini", None, "gpt-6.1-sol-mini"),
]]
with open(os.path.join(ROOT, "price-cases.json"), "w", encoding="utf-8") as f:
    json.dump({"_comment": "METRICS 9.2-9.3 against the fixture tables in `tables` (paths relative to this folder). "
                           "`resolve.expect` is a model id, `free` or `unknown`. `cost.expect`: exact pico-USD, "
                           "the rounded micro-USD (null = unknown price) and the index of the tier used (null = the "
                           "base prices); `at` (UTC, YYYY-MM-DD or YYYY-MM-DDTHH:MMZ) is the response's endMs for "
                           "periods and off-peak rules (absent = none applies); `fast` marks a fast-mode response. "
                           "`resolve.expect` adds ` fast` when the id itself selects fast mode. Tokens are "
                           "normalized usage (METRICS 3.2). `days` (9.7): all tables "
                           "loaded, the highest version current, `bindings` stored; `version` is the date's binding "
                           "afterwards.",
               "tables": {"v1": "prices/v1.json", "v2": "prices/v2.json"},
               "resolve": resolve_cases, "cost": cost_cases, "days": day_cases}, f, indent=2, ensure_ascii=False)
    f.write("\n")

# --- Money formatting and exchange rates (DESIGN 9, NETWORK 4) ------------------
NB = "\u00a0"
money_cases = [dict(zip(("form", "value", "currency", "language", "number", "text"), c)) for c in [
    ("rate", "0", "USD", "en", "0", "0 $/s"),
    ("rate", "0.0000004", "USD", "en", "<0.000001", "<0.000001 $/s"),
    ("rate", "0.0000012", "USD", "en", "0.000001", "0.000001 $/s"),
    ("rate", "0.000081", "USD", "en", "0.000081", "0.000081 $/s"),
    ("rate", "0.0042", "USD", "en", "0.0042", "0.0042 $/s"),
    ("rate", "0.00419", "USD", "zh-Hant", "0.0042", "0.0042 US$/s"),
    ("rate", "0.0300", "CNY", "zh-Hans", "0.03", "0.03 ¥/s"),
    ("rate", "0.034", "CNY", "zh-Hant", "0.034", "0.034 CN¥/s"),
    ("rate", "4.2", "CNY", "zh-Hans", "4.20", "4.20 ¥/s"),
    ("rate", "0.5", "USD", "en", "0.50", "0.50 $/s"),
    ("rate", "0.664", "JPY", "ja", "0.66", "0.66 ¥/s"),
    ("rate", "0.3", "JPY", "ja", "0.3", "0.3 ¥/s"),
    ("rate", "4.2", "JPY", "en", "4.2", "4.2 JP¥/s"),
    ("rate", "0.1367184", "TWD", "zh-Hant", "0.14", "0.14 NT$/s"),
    ("rate", "5.567", "KRW", "en", "5.57", "5.57 ₩/s"),
    ("rate", "12.3", "USD", "en", "12.30", "12.30 $/s"),
    ("rate", "0.99996", "USD", "en", "1.00", "1.00 $/s"),
    ("rate", "99.96", "USD", "en", "100", "100 $/s"),
    ("rate", "1234.5", "KRW", "en", "1,235", "1,235 ₩/s"),
    ("rate", "1280000", "IDR", "en", "1.28M", "1.28M Rp/s"),
    ("rate", "0.42", "CHF", "en", "0.42", "0.42 CHF/s"),
    ("amount", "0", "USD", "en", "0.00", "$0.00"),
    ("amount", "0", "JPY", "ja", "0", "¥0"),
    ("amount", "0.0000001", "USD", "en", "<0.000001", "<$0.000001"),
    ("amount", "0.42", "USD", "en", "0.42", "$0.42"),
    ("amount", "0.0042", "USD", "zh-Hant", "0.0042", "US$0.0042"),
    ("amount", "0.030", "USD", "en", "0.03", "$0.03"),
    ("amount", "0.42", "JPY", "ja", "0.42", "¥0.42"),
    ("amount", "12.345", "USD", "en", "12.35", "$12.35"),
    ("amount", "1234.564", "USD", "en", "1,234.56", "$1,234.56"),
    ("amount", "1234.5", "TWD", "zh-Hant", "1,235", "NT$1,235"),
    ("amount", "12345.4", "KRW", "en", "12,345", "₩12,345"),
    ("amount", "999999.996", "USD", "en", "1.00M", "$1.00M"),
    ("amount", "12800000", "IDR", "en", "12.8M", "Rp" + NB + "12.8M"),
    ("amount", "1280000000", "USD", "en", "1.28B", "$1.28B"),
    ("amount", "0.42", "CHF", "en", "0.42", "CHF" + NB + "0.42"),
    ("amount", "1.2", "MYR", "zh-Hant", "1.20", "RM" + NB + "1.20"),
]] + [
    {"form": "amount", "costMicroUsd": 4200, "rate": "32.552", "currency": "TWD", "language": "zh-Hant",
     "number": "0.14", "text": "NT$0.14"},
    {"form": "amount", "costMicroUsd": 37_940_000, "rate": "32.552", "currency": "TWD", "language": "zh-Hant",
     "number": "1,235", "text": "NT$1,235"},
    {"form": "rate", "costMicroUsd": 4200, "rate": "6.67476", "currency": "CNY", "language": "zh-Hans",
     "number": "0.028", "text": "0.028 ¥/s"},
]
with open(os.path.join(ROOT, "money-format.json"), "w", encoding="utf-8") as f:
    json.dump({"_comment": "DESIGN 9 Money formatting. `value` is a decimal string in the currency's units, or it is "
                           "costMicroUsd x rate / 1 000 000 computed in decimal arithmetic. `number` = the digits, "
                           "`text` = an amount with its symbol (U+00A0 after a symbol ending in a letter) or a rate "
                           "followed by \" <symbol>/s\". Currencies and symbols: spec/assets/currencies.json.",
               "cases": money_cases}, f, indent=2, ensure_ascii=False)
    f.write("\n")

NOW = int(datetime(2026, 10, 22, 12, 0, tzinfo=timezone.utc).timestamp() * 1000)
DAYMS = 86_400_000
er_body = {"result": "success", "provider": "https://www.exchangerate-api.com", "time_last_update_unix": 1792627351,
           "base_code": "USD", "rates": {"USD": 1, "CNY": 6.689327, "TWD": 32.411205, "JPY": 158.100039,
                                         "EUR": 0.890292, "XAU": 0.000301}}
fa_body = {"date": "2026-10-22", "usd": {"usd": 1, "cny": 6.67476008, "twd": 32.5520031, "jpy": 157.7279153,
                                         "eur": 0.88943738, "btc": 0.0000091}}
fr_body = {"amount": 1.0, "base": "USD", "date": "2026-10-21", "rates": {"CNY": 6.6761, "JPY": 157.88, "EUR": 0.89015}}
rate_parse = [
    {"name": "ExchangeRate-API open access", "provider": "open.er-api.com", "body": er_body,
     "expect": {"dateMs": 1792627351000, "rates": {"CNY": "6.689327", "EUR": "0.890292", "JPY": "158.100039",
                                                   "TWD": "32.411205", "USD": "1"}}},
    {"name": "an error response is rejected", "provider": "open.er-api.com",
     "body": {"result": "error", "error-type": "unsupported-code"}, "expect": None},
    {"name": "fawazahmed0 currency-api (lower-case codes, extra assets ignored)", "provider": "currency-api",
     "body": fa_body, "expect": {"dateMs": NOW - 12 * 3_600_000,
                                 "rates": {"CNY": "6.67476008", "EUR": "0.88943738", "JPY": "157.7279153",
                                           "TWD": "32.5520031", "USD": "1"}}},
    {"name": "Frankfurter (ECB; no TWD)", "provider": "frankfurter", "body": fr_body,
     "expect": {"dateMs": NOW - 36 * 3_600_000, "rates": {"CNY": "6.6761", "EUR": "0.89015", "JPY": "157.88",
                                                         "USD": "1"}}},
    {"name": "a non-positive rate rejects the response", "provider": "currency-api",
     "body": {"date": "2026-10-22", "usd": {"twd": -1}}, "expect": None},
    {"name": "a non-numeric rate rejects the response", "provider": "open.er-api.com",
     "body": dict(er_body, rates={"TWD": "32.4"}), "expect": None},
]
last = {"dateMs": NOW - DAYMS - 12 * 3_600_000, "acceptedMs": NOW - DAYMS, "rates": {"TWD": "32.4"}}
old = dict(last, acceptedMs=NOW - 40 * DAYMS, dateMs=NOW - 41 * DAYMS)
rate_accept = [
    {"name": "a normal daily change", "selected": "TWD", "dateMs": NOW - 12 * 3_600_000, "rates": {"TWD": "32.55"},
     "nowMs": NOW, "last": last, "accept": True},
    {"name": "more than x2 of the last rate", "selected": "TWD", "dateMs": NOW - 12 * 3_600_000,
     "rates": {"TWD": "97.2"}, "nowMs": NOW, "last": last, "accept": False},
    {"name": "less than x0.5 of the last rate", "selected": "TWD", "dateMs": NOW - 12 * 3_600_000,
     "rates": {"TWD": "16.1"}, "nowMs": NOW, "last": last, "accept": False},
    {"name": "older than the stored rates", "selected": "TWD", "dateMs": NOW - 3 * DAYMS, "rates": {"TWD": "32.5"},
     "nowMs": NOW, "last": last, "accept": False},
    {"name": "more than two days in the future", "selected": "TWD", "dateMs": NOW + 3 * DAYMS,
     "rates": {"TWD": "32.5"}, "nowMs": NOW, "last": last, "accept": False},
    {"name": "first fetch is checked against the bundled rate", "selected": "TWD", "dateMs": NOW,
     "rates": {"TWD": "33.0"}, "nowMs": NOW, "fallback": {"TWD": "32.552"}, "accept": True},
    {"name": "stale last rate: one provider is not enough", "selected": "TWD", "dateMs": NOW,
     "rates": {"TWD": "45.0"}, "nowMs": NOW, "last": old, "accept": False},
    {"name": "stale last rate: two providers within 3 %", "selected": "TWD", "dateMs": NOW,
     "rates": {"TWD": "45.0"}, "nowMs": NOW, "last": old, "other": {"TWD": "44.1"}, "accept": True},
    {"name": "stale last rate: two providers more than 3 % apart", "selected": "TWD", "dateMs": NOW,
     "rates": {"TWD": "45.0"}, "nowMs": NOW, "last": old, "other": {"TWD": "42.0"}, "accept": False},
    {"name": "a provider without the selected currency", "selected": "TWD", "dateMs": NOW,
     "rates": {"USD": "1", "JPY": "157.88"}, "nowMs": NOW, "last": last, "accept": False},
]
with open(os.path.join(ROOT, "rates-cases.json"), "w", encoding="utf-8") as f:
    json.dump({"_comment": "NETWORK 4. `parse`: provider body -> date (Unix ms) and the rates of `supported` "
                           "currencies as decimal strings, USD = 1 (null = rejected). `accept`: checks 3-5 for the "
                           "selected currency; `last` = the stored rates with their date and the time they were "
                           "accepted, `fallback` = bundled rates, `other` = a second provider's rates.",
               "supported": ["USD", "CNY", "TWD", "JPY", "EUR"], "parse": rate_parse, "accept": rate_accept},
              f, indent=2, ensure_ascii=False)
    f.write("\n")

# --- Engine cases -------------------------------------------------------------
B = 1_000_000_000_000
DAY = B - 3_600_000


def er(key, agent, source, model, start, end, out, inp=0, final=True):
    return {"key": key, "agentId": agent, "source": source, "model": model, "startMs": start, "endMs": end,
            "input": inp, "output": out, "final": final}


def agent(aid, source, model, phase="idle", in_flight=None, last=None, parent=None):
    return {"id": aid, "source": source, "model": model, "phase": phase, "inFlightStartMs": in_flight,
            "lastLineMs": last, "parentId": parent}


r1 = er("r1", "a1", "codex", "m1", B, B + 4000, 200, 10000)
cases = [
    {"name": "single completed response",
     "agents": [agent("a1", "codex", "m1", last=B + 4000)], "responses": [r1],
     "queries": [{"nowMs": B + 4000, "liveOutput": 50.0, "liveTotal": 2550.0, "estimatedShare": 0.0},
                 {"nowMs": B + 5000, "liveOutput": 200 * 2000 / 4000 / 3, "liveTotal": 1700.0, "estimatedShare": 0.0},
                 {"nowMs": B + 7000, "liveOutput": 0.0, "liveTotal": 0.0, "estimatedShare": 0.0}]},
    {"name": "in-flight estimate from the agent's recent speed",
     "agents": [agent("a1", "codex", "m1", "generating", B + 4500, B + 4500)], "responses": [r1],
     "queries": [{"nowMs": B + 6000, "liveOutput": 125 / 3, "liveTotal": 2125.0, "estimatedShare": 0.6}]},
    {"name": "stale in-flight agents are not estimated",
     "agents": [agent("a1", "codex", "m1", "generating", B + 4500, B + 4500)], "responses": [r1],
     "queries": [{"nowMs": B + 4500 + 300_001, "liveOutput": 0.0, "liveTotal": 0.0, "estimatedShare": 0.0}]},
    {"name": "parallel agents are summed",
     "agents": [agent("a1", "codex", "m1", last=B + 4000), agent("a2", "claudeCode", "m2", last=B + 3000)],
     "responses": [er("r1", "a1", "codex", "m1", B, B + 4000, 200),
                   er("r2", "a2", "claudeCode", "m2", B + 1000, B + 3000, 100)],
     "queries": [{"nowMs": B + 3000, "liveOutput": 250 / 3, "liveTotal": 250 / 3, "estimatedShare": 0.0}]},
    {"name": "durations shorter than 500 ms are widened backwards",
     "agents": [agent("a1", "codex", "m1", last=B + 1100)],
     "responses": [er("r1", "a1", "codex", "m1", B + 1000, B + 1100, 10)],
     "queries": [{"nowMs": B + 1100, "liveOutput": 10 / 3, "liveTotal": 10 / 3, "estimatedShare": 0.0},
                 {"nowMs": B + 3700, "liveOutput": 8 / 3, "liveTotal": 8 / 3, "estimatedShare": 0.0}]},
    {"name": "unknown or implausible intervals never count as speed",
     "agents": [agent("a1", "codex", "m1", last=B + 960_000)],
     "responses": [er("r1", "a1", "codex", "m1", None, B + 2000, 500),
                   er("r2", "a1", "codex", "m1", B, B + 960_000, 500)],
     "queries": [{"nowMs": B + 2000, "liveOutput": 0.0, "liveTotal": 0.0, "estimatedShare": 0.0},
                 {"nowMs": B + 960_000, "liveOutput": 0.0, "liveTotal": 0.0, "estimatedShare": 0.0}]},
    {"name": "model fallback when the agent has no history",
     "agents": [agent("a1", "codex", "m1", last=B + 4000), agent("a3", "claudeCode", "m1", "generating", B + 5000,
                                                                  B + 5000)],
     "responses": [r1],
     "queries": [{"nowMs": B + 6000, "liveOutput": 100 / 3, "liveTotal": (2550 + 2550) / 3, "estimatedShare": 0.5}]},
    {"name": "source fallback when the model is unknown",
     "agents": [agent("a1", "codex", "m1", last=B + 4000), agent("a4", "codex", "m9", "generating", B + 5000,
                                                                  B + 5000)],
     "responses": [r1],
     "queries": [{"nowMs": B + 6000, "liveOutput": 100 / 3, "liveTotal": (2550 + 2550) / 3, "estimatedShare": 0.5}]},
    {"name": "no estimate without any reference speed",
     "agents": [agent("a1", "codex", "m1", last=B + 4000), agent("a5", "claudeDesktop", "m7", "generating",
                                                                  B + 5000, B + 5000)],
     "responses": [r1],
     "queries": [{"nowMs": B + 6000, "liveOutput": 50 / 3, "liveTotal": 2550 / 3, "estimatedShare": 0.0}]},
    {"name": "recent speed uses the last three responses",
     "agents": [agent("a1", "codex", "m1", "generating", B + 7000, B + 7000)],
     "responses": [er("r1", "a1", "codex", "m1", B, B + 1000, 100),
                   er("r2", "a1", "codex", "m1", B + 2000, B + 3000, 50),
                   er("r3", "a1", "codex", "m1", B + 4000, B + 5000, 50),
                   er("r4", "a1", "codex", "m1", B + 6000, B + 7000, 50)],
     "queries": [{"nowMs": B + 9000, "liveOutput": 50.0, "liveTotal": 50.0, "estimatedShare": 100 / 150}]},
    {"name": "estimates never overlap the agent's own measured responses",
     "agents": [agent("a1", "claudeCode", "m1", "generating", B, B + 2000)],
     "responses": [er("r1", "a1", "claudeCode", "m1", B, B + 2000, 100)],
     "queries": [{"nowMs": B + 3000, "liveOutput": 50.0, "liveTotal": 50.0, "estimatedShare": 1 / 3}]},
    {"name": "unmeasured responses are estimated from a measured reference",
     "agents": [agent("a1", "claudeCode", "m1", last=B + 4000), agent("a2", "claudeCode", "m1", "tools", None, B + 3000)],
     "responses": [er("r1", "a1", "claudeCode", "m1", B, B + 4000, 200),
                   er("r2", "a2", "claudeCode", "m1", B + 1000, B + 3000, 8, final=False)],
     "queries": [{"nowMs": B + 3000, "liveOutput": 250 / 3, "liveTotal": 250 / 3, "estimatedShare": 0.4}]},
    {"name": "agents are listed in parent groups",
     "agents": [agent("P1", "claudeDesktop", "m1", "idle", None, B),
                agent("C1", "claudeDesktop", "m1", "generating", None, B + 3000, "P1"),
                agent("C2", "claudeDesktop", "m1", "generating", None, B + 3000, "P1"),
                agent("P2", "codex", "m2", "generating", None, B + 3000),
                agent("R", "codex", "m2", "idle", None, B - 900_000),
                agent("C3", "codex", "m2", "generating", None, B + 2000, "R"),
                agent("D", "claudeCode", "m3", "idle", None, B - 1000),
                agent("Q", "codex", "m2", "idle", None, B - 700_000)],
     "responses": [er("r1", "P2", "codex", "m2", B, B + 3000, 300),
                   er("r2", "C1", "claudeDesktop", "m1", B, B + 3000, 150),
                   er("r3", "C2", "claudeDesktop", "m1", B, B + 3000, 90)],
     "queries": [{"nowMs": B + 3000, "liveOutput": 180.0, "liveTotal": 180.0, "estimatedShare": 0.0,
                  "agentsOrder": ["P2", "P1", "C1", "C2", "R", "C3", "D"],
                  "agentParents": {"C1": "P1", "C2": "P1", "C3": "R"}}]},
    {"name": "today totals, average, peak and history",
     "todayStartMs": DAY,
     "agents": [agent("a1", "codex", "m1", last=B + 4000)],
     "responses": [er("r0", "a1", "codex", "m1", DAY - 5000, DAY - 1, 999, 999),
                   er("r1", "a1", "codex", "m1", B, B + 4000, 200, 10000),
                   er("r2", "a1", "codex", "m1", B + 2000, B + 3000, 300, 0),
                   er("r3", "a1", "codex", "m1", B + 5000, B + 6000, 8, 0, final=False)],
     "queries": [{"nowMs": B + 10_000, "liveOutput": 0.0, "liveTotal": 0.0, "estimatedShare": 0.0,
                  "todayRequests": 3, "todayOutput": 508, "todayInput": 10000, "averageToday": 100.0,
                  "todayUnfinalized": 1,
                  "peakTodayOutput": 150.0,
                  "historyMeasuredOutput": {str(B): 50.0, str(B + 1000): 50.0, str(B + 2000): 350.0,
                                            str(B + 3000): 50.0, str(B + 4000): 0.0}}]},
    {"name": "orb subsets (METRICS 6.8)",
     "todayStartMs": DAY,
     "agents": [agent("a1", "codex", "m1", last=B + 2000), agent("a2", "claudeCode", "m2", last=B + 3000)],
     "responses": [er("r1", "a1", "codex", "m1", B, B + 2000, 400),
                   er("r2", "a2", "claudeCode", "m2", B, B + 3000, 300)],
     "queries": [{"nowMs": B + 3000, "liveOutput": 700 / 3, "liveTotal": 700 / 3, "estimatedShare": 0.0,
                  "subsets": [{"sources": ["codex"], "liveOutput": 400 / 3, "peakTodayOutput": 400 / 3},
                              {"sources": ["claudeCode"], "liveOutput": 100.0, "peakTodayOutput": 100.0},
                              {"sources": ["codex", "claudeCode"], "liveOutput": 700 / 3,
                               "peakTodayOutput": 700 / 3},
                              {"sources": ["gemini"], "liveOutput": 0.0, "peakTodayOutput": 0.0}]}]},
]


def ec(key, agent_id, source, model, start, end, out, cost, inp=0, final=True):
    return dict(er(key, agent_id, source, model, start, end, out, inp, final), costMicroUsd=cost)


c1 = ec("r1", "a1", "codex", "m1", B, B + 4000, 200, 4000, 10000)
cases += [
    {"name": "live cost spreads each response's cost over its interval (METRICS 9.5)",
     "agents": [agent("a1", "codex", "m1", last=B + 4000)], "responses": [c1],
     "queries": [{"nowMs": B + 4000, "liveOutput": 50.0, "liveTotal": 2550.0, "estimatedShare": 0.0,
                  "liveCost": 1000.0, "liveCostKnownShare": 1.0},
                 {"nowMs": B + 5000, "liveOutput": 200 * 2000 / 4000 / 3, "liveTotal": 1700.0, "estimatedShare": 0.0,
                  "liveCost": 2000 / 3, "liveCostKnownShare": 1.0},
                 {"nowMs": B + 7000, "liveOutput": 0.0, "liveTotal": 0.0, "estimatedShare": 0.0,
                  "liveCost": 0.0, "liveCostKnownShare": 1.0}]},
    {"name": "in-flight cost from the agent's recent cost rate",
     "agents": [agent("a1", "codex", "m1", "generating", B + 4500, B + 4500)], "responses": [c1],
     "queries": [{"nowMs": B + 6000, "liveOutput": 125 / 3, "liveTotal": 2125.0, "estimatedShare": 0.6,
                  "liveCost": 2500 / 3, "liveCostKnownShare": 1.0}]},
    {"name": "unknown prices are never counted as zero",
     "agents": [agent("a1", "codex", "m1", last=B + 4000), agent("a2", "claudeCode", "m2", last=B + 3000)],
     "responses": [ec("r1", "a1", "codex", "m1", B, B + 4000, 200, 4000),
                   ec("r2", "a2", "claudeCode", "m2", B + 1000, B + 3000, 100, None)],
     "queries": [{"nowMs": B + 3000, "liveOutput": 250 / 3, "liveTotal": 250 / 3, "estimatedShare": 0.0,
                  "liveCost": 1000.0, "liveCostKnownShare": 0.6}]},
    {"name": "an unpriced reference leaves the in-flight estimate unpriced",
     "agents": [agent("a1", "codex", "m1", "generating", B + 4500, B + 4500)],
     "responses": [ec("r1", "a1", "codex", "m1", B, B + 4000, 200, None)],
     "queries": [{"nowMs": B + 6000, "liveOutput": 125 / 3, "liveTotal": 125 / 3, "estimatedShare": 0.6,
                  "liveCost": 0.0, "liveCostKnownShare": 0.0}]},
    {"name": "free responses are a known zero",
     "agents": [agent("a1", "codex", "m1", last=B + 4000)],
     "responses": [ec("r1", "a1", "codex", "m1", B, B + 4000, 200, 0)],
     "queries": [{"nowMs": B + 4000, "liveOutput": 50.0, "liveTotal": 50.0, "estimatedShare": 0.0,
                  "liveCost": 0.0, "liveCostKnownShare": 1.0}]},
    {"name": "unmeasured responses use the reference cost rate",
     "agents": [agent("a1", "claudeCode", "m1", last=B + 4000),
                agent("a2", "claudeCode", "m1", "tools", None, B + 3000)],
     "responses": [ec("r1", "a1", "claudeCode", "m1", B, B + 4000, 200, 4000),
                   ec("r2", "a2", "claudeCode", "m1", B + 1000, B + 3000, 8, 999, final=False)],
     "queries": [{"nowMs": B + 3000, "liveOutput": 250 / 3, "liveTotal": 250 / 3, "estimatedShare": 0.4,
                  "liveCost": 5000 / 3, "liveCostKnownShare": 1.0}]},
    {"name": "today's cost and unpriced requests (METRICS 9.6)",
     "todayStartMs": DAY,
     "agents": [agent("a1", "codex", "m1", last=B + 6000)],
     "responses": [ec("r0", "a1", "codex", "m1", DAY - 5000, DAY - 1, 999, 999),
                   ec("r1", "a1", "codex", "m1", B, B + 4000, 200, 4000),
                   ec("r2", "a1", "codex", "m1", B + 2000, B + 3000, 300, None),
                   ec("r3", "a1", "codex", "m1", B + 5000, B + 6000, 8, 0, final=False)],
     "queries": [{"nowMs": B + 10_000, "liveOutput": 0.0, "liveTotal": 0.0, "estimatedShare": 0.0,
                  "liveCost": 0.0, "liveCostKnownShare": 1.0, "todayCostMicroUsd": 4000,
                  "todayUnpricedRequests": 1}]},
    {"name": "cost per source is additive (orb subsets)",
     "todayStartMs": DAY,
     "agents": [agent("a1", "codex", "m1", last=B + 2000), agent("a2", "claudeCode", "m2", last=B + 3000)],
     "responses": [ec("r1", "a1", "codex", "m1", B, B + 2000, 400, 2000),
                   ec("r2", "a2", "claudeCode", "m2", B, B + 3000, 300, 900)],
     "queries": [{"nowMs": B + 3000, "liveOutput": 700 / 3, "liveTotal": 700 / 3, "estimatedShare": 0.0,
                  "liveCost": 2900 / 3, "liveCostKnownShare": 1.0,
                  "subsets": [{"sources": ["codex"], "liveOutput": 400 / 3, "liveCost": 2000 / 3},
                              {"sources": ["claudeCode"], "liveOutput": 100.0, "liveCost": 300.0},
                              {"sources": ["codex", "claudeCode"], "liveOutput": 700 / 3, "liveCost": 2900 / 3},
                              {"sources": ["gemini"], "liveOutput": 0.0, "liveCost": 0.0}]}]},
]
with open(os.path.join(ROOT, "engine-cases.json"), "w", encoding="utf-8") as f:
    json.dump({"_comment": "Times are Unix ms. Unless a case sets todayStartMs, use 0. Compare floats with 1e-6 "
                           "absolute tolerance. historyMeasuredOutput maps bucket start ms to tok/s. `subsets` evaluate "
                           "6.8 for a source set: live output, today's peak and live cost over only those sources' "
                           "responses and agents (keys that are absent are not checked). Responses with "
                           "`costMicroUsd` carry their priced cost (METRICS 9.3; null = unknown price): `liveCost` is "
                           "micro-USD per second and `liveCostKnownShare` the share of live output tokens whose cost "
                           "is known (9.5); `todayCostMicroUsd` and `todayUnpricedRequests` are exact (9.6).",
               "cases": cases}, f, indent=2)
    f.write("\n")
print("fixtures written to", ROOT)
