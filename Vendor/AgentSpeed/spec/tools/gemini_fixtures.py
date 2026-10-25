#!/usr/bin/env python3
"""Gemini CLI session fixtures (METRICS 4.6), used by generate_fixtures.py.

  python3 spec/tools/gemini_fixtures.py OUT_DIR

Files are written under OUT_DIR/gemini/tmp/... exactly as Gemini CLI lays them out. The returned expectations have
the shape of spec/fixtures/parser-expected.json (`order`, `files`, `mtimes`) plus `discover` (the session files
discovery must find) and `traces` (phase checkpoints after a given physical line of a .jsonl file). Expected values
are written by hand, independently of reference.py.
"""
import hashlib
import json
import os
import sys
from datetime import datetime, timezone

DAY = "2026-10-20"

NOVA_ROOT = "/Users/dev/projects/nova"
ORBIT_ROOT_ORIGINAL = "C:\\Users\\dev\\projects\\orbit"
ORBIT_ROOT_MARKER = "c:\\users\\dev\\projects\\orbit"

LEGACY_SESSION = "1e9c0a77-2b4d-4c6e-8f10-3a5b7c9d1e2f"
MAIN_SESSION = "7f3a2b10-5c1d-4e2f-9a3b-0c4d5e6f7a8b"
SUB_RUNNING = "0b8e6d2c-3f4a-4b5c-8d6e-7f8091a2b3c4"
SUB_DONE = "5d4c3b2a-1f0e-4d9c-8b7a-695847362514"

LEGACY_JSON = "gemini/tmp/nova/chats/session-2026-10-20T10-20-1e9c0a77.json"
MIGRATED_JSONL = LEGACY_JSON + "l"
MAIN_JSONL = "gemini/tmp/orbit/chats/session-2026-10-20T10-30-7f3a2b10.jsonl"
SUB_RUNNING_JSONL = "gemini/tmp/orbit/chats/%s/%s.jsonl" % (MAIN_SESSION, SUB_RUNNING)
SUB_DONE_JSONL = "gemini/tmp/orbit/chats/%s/%s.jsonl" % (MAIN_SESSION, SUB_DONE)


def ts(clock):
    """'10:30:05.000' -> ISO string as written by Date.toISOString()."""
    return "%sT%sZ" % (DAY, clock)


def ms(clock):
    dt = datetime.strptime("%s %s" % (DAY, clock), "%Y-%m-%d %H:%M:%S.%f").replace(tzinfo=timezone.utc)
    return int(dt.timestamp() * 1000)


def mid(prefix, n):
    return "%s-0000-4000-8000-%012d" % (prefix, n)


def sha(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def tokens(inp, out, cached, thoughts, tool):
    return {"input": inp, "output": out, "cached": cached, "thoughts": thoughts, "tool": tool,
            "total": inp + out + thoughts + tool}


def user(id_, clock, text):
    return {"id": id_, "timestamp": ts(clock), "type": "user", "content": [{"text": text}]}


def tool_result(id_, clock, call_id, name, output):
    return {"id": id_, "timestamp": ts(clock), "type": "user",
            "content": [{"functionResponse": {"id": call_id, "name": name, "response": {"output": output}}}]}


def gemini(id_, clock, content, toks, model, thoughts=None):
    msg = {"id": id_, "timestamp": ts(clock), "type": "gemini", "content": content, "thoughts": thoughts or [],
           "tokens": toks, "model": model}
    return msg


def thought(subject, clock):
    return {"subject": subject, "description": "Working through %s." % subject.lower(), "timestamp": ts(clock)}


def call(call_id, name, args, status, clock, output="ok"):
    return {"id": call_id, "name": name, "args": args,
            "result": [{"functionResponse": {"id": call_id, "name": name, "response": {"output": output}}}],
            "status": status, "timestamp": ts(clock), "displayName": name, "description": "",
            "renderOutputAsMarkdown": False}


def with_calls(msg, calls):
    out = dict(msg)
    out["toolCalls"] = calls
    return out


def set_updated(clock):
    return {"$set": {"lastUpdated": ts(clock)}}


def resp(key, start, end, inp, cached, out, reasoning, model):
    return {"key": key, "startMs": None if start is None else ms(start), "endMs": ms(end), "input": inp,
            "cachedInput": cached, "cacheWriteInput": 0, "cacheWrite1hInput": 0, "output": out,
            "reasoning": reasoning, "model": model, "provider": None, "fast": False,
            "final": True}


def write_jsonl(path, records):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        for r in records:
            f.write(r if isinstance(r, str) else json.dumps(r, separators=(",", ":")))
            f.write("\n")


def write_fixtures(out_dir):
    def p(rel):
        full = os.path.join(out_dir, *rel.split("/"))
        os.makedirs(os.path.dirname(full), exist_ok=True)
        return full

    with open(p("gemini/tmp/nova/.project_root"), "w", encoding="utf-8") as f:
        f.write(NOVA_ROOT)
    with open(p("gemini/tmp/orbit/.project_root"), "w", encoding="utf-8") as f:
        f.write(ORBIT_ROOT_MARKER)
    with open(p("gemini/projects.json"), "w", encoding="utf-8") as f:
        json.dump({"projects": {NOVA_ROOT: "nova", ORBIT_ROOT_MARKER: "orbit"}}, f, indent=2)
    # Decoys that must not be discovered.
    with open(p("gemini/tmp/orbit/checkpoint-release.json"), "w", encoding="utf-8") as f:
        json.dump([{"role": "user", "parts": [{"text": "saved chat"}]}], f)
    with open(p("gemini/tmp/orbit/logs.json"), "w", encoding="utf-8") as f:
        json.dump([], f)
    with open(p("gemini/tmp/orbit/chats/session-2026-10-20T10-30-7f3a2b10.jsonl.tmp-4242"), "w") as f:
        f.write("")

    # ---- Legacy JSON (v0.31-era): tool-only response created at tool completion, then error.
    c_u1, c_g1, c_g2, c_u2, c_e1 = (mid("c0c0c0c0", n) for n in range(1, 6))
    legacy_messages = [
        user(c_u1, "10:20:00.000", "Fix the build"),
        {"id": c_g1, "timestamp": ts("10:20:09.000"), "type": "gemini", "content": "",
         "toolCalls": [call("run_shell_command-1792491608998-0", "run_shell_command", {"command": "npm run build"},
                            "success", "10:20:08.998")],
         "thoughts": [thought("Reproducing the failure", "10:20:02.500")], "model": "gemini-2.5-pro",
         "tokens": tokens(8000, 60, 0, 200, 0)},
        gemini(c_g2, "10:20:14.000", "The build is fixed: a missing export in src/index.ts.",
               tokens(8400, 220, 4096, 0, 0), "gemini-2.5-pro"),
        user(c_u2, "10:21:00.000", "Now run the tests"),
        {"id": c_e1, "timestamp": ts("10:21:03.000"), "type": "error",
         "content": "[API Error: 503 The model is overloaded. Please try again later.]"},
    ]
    legacy = {"sessionId": LEGACY_SESSION, "projectHash": sha(NOVA_ROOT), "startTime": ts("10:20:00.000"),
              "lastUpdated": ts("10:21:03.004"), "messages": legacy_messages}
    with open(p(LEGACY_JSON), "w", encoding="utf-8") as f:
        f.write(json.dumps(legacy, indent=2))

    # ---- Migrated JSONL (written by a v0.54 - v0.63 binary resuming the legacy session).
    d_u3, d_g3, d_u4, d_g4, d_u5, d_i1 = (mid("d0d0d0d0", n) for n in range(3, 9))
    d_g3_msg = gemini(d_g3, "10:40:04.000", "", tokens(9000, 80, 8192, 40, 0), "gemini-2.5-flash",
                      [thought("Finding the changelog", "10:40:03.990")])
    d_g3_calls = with_calls(d_g3_msg, [call("write_file__x1", "write_file", {"file_path": "CHANGELOG.md"},
                                            "success", "10:40:06.500")])
    d_g4_msg = gemini(d_g4, "10:40:09.000", "Added the entry to CHANGELOG.md.", tokens(9300, 150, 9000, 0, 0),
                      "gemini-2.5-flash")
    migrated = [
        {"sessionId": LEGACY_SESSION, "projectHash": sha(NOVA_ROOT), "startTime": ts("10:20:00.000"),
         "lastUpdated": ts("10:21:03.004")},                                                      # 1
        *legacy_messages,                                                                          # 2-6 copies
        {"$set": {"sessionId": LEGACY_SESSION}},                                                   # 7
        user(d_u3, "10:40:00.000", "Add a changelog entry"),                                       # 8
        set_updated("10:40:00.002"),                                                               # 9
        d_g3_msg,                                                                                  # 10
        set_updated("10:40:04.002"),                                                               # 11
        d_g3_calls,                                                                                # 12
        tool_result(d_u4, "10:40:06.520", "write_file__x1", "write_file", "Wrote CHANGELOG.md"),   # 13
        set_updated("10:40:06.521"),                                                               # 14
        d_g4_msg,                                                                                  # 15
        set_updated("10:40:09.002"),                                                               # 16
        '{"id":"d0d0d0d0-0000-4000-8000-000000000099","timestamp":',                               # 17 malformed
        user(d_u5, "10:41:00.000", "Also bump the version"),                                       # 18
        set_updated("10:41:00.002"),                                                               # 19
        {"$set": {"messages": legacy_messages + [user(d_u3, "10:40:00.000", "Add a changelog entry"), d_g3_calls,
                                                 tool_result(d_u4, "10:40:06.520", "write_file__x1", "write_file",
                                                             "Wrote CHANGELOG.md"), d_g4_msg],
                  "lastUpdated": ts("10:41:02.000")}},                                             # 20 rollback
        {"id": d_i1, "timestamp": ts("10:41:02.010"), "type": "info", "content": "Request cancelled."},  # 21
    ]
    write_jsonl(p(MIGRATED_JSONL), migrated)

    # ---- Main session (v0.64+): thoughts, cached and tool tokens, tool cycle, duplicate, $set, $patch, $rewindTo.
    a_u1, a_g1, a_u2, a_g2, a_u3, a_i1, a_u4, a_g3, a_u5, a_e1, a_u6 = (mid("a0a0a0a0", n) for n in range(1, 12))
    a_g1_msg = gemini(a_g1, "10:30:11.000", "", tokens(15000, 90, 12288, 410, 0), "gemini-3-pro-preview",
                      [thought("Locating the parser", "10:30:10.990")])
    a_g2_msg = gemini(a_g2, "10:30:20.000", "Here is the plan: split parseConfig into lexer and validator.",
                      tokens(16200, 640, 15000, 160, 96), "gemini-3-pro-preview")
    main = [
        {"sessionId": MAIN_SESSION, "projectHash": sha(ORBIT_ROOT_ORIGINAL), "startTime": ts("10:30:00.000"),
         "lastUpdated": ts("10:30:00.000"), "kind": "main"},                                       # 1
        user(a_u1, "10:30:05.000", "Refactor the config parser"),                                  # 2
        set_updated("10:30:05.001"),                                                               # 3
        a_g1_msg,                                                                                  # 4
        set_updated("10:30:11.001"),                                                               # 5
        with_calls(a_g1_msg, [call("read_file__k3f9", "read_file", {"file_path": "src/config.ts"}, "success",
                                   "10:30:12.400")]),                                              # 6
        tool_result(a_u2, "10:30:12.420", "read_file__k3f9", "read_file", "export function parseConfig() {}"),  # 7
        set_updated("10:30:12.421"),                                                               # 8
        a_g2_msg,                                                                                  # 9
        set_updated("10:30:20.001"),                                                               # 10
        a_g2_msg,                                                                                  # 11 duplicate
        with_calls(a_g1_msg, [call("read_file__k3f9", "read_file", {"file_path": "src/config.ts"}, "success",
                                   "10:30:12.400", "[masked]")]),                                  # 12 re-append, known calls
        {"$set": {"directories": [ORBIT_ROOT_ORIGINAL]}},                                          # 13
        user(a_u3, "10:31:00.000", "Go ahead"),                                                    # 14
        set_updated("10:31:00.001"),                                                               # 15
        {"$patch": {"updates": [{"id": a_u2, "content": [{"functionResponse": {
            "id": "read_file__k3f9", "name": "read_file", "response": {"output": "[masked]"}}}]}]}},  # 16
        {"id": a_i1, "timestamp": ts("10:31:02.500"), "type": "info", "content": "Request cancelled."},  # 17
        set_updated("10:31:02.501"),                                                               # 18
        {"$rewindTo": a_u3},                                                                       # 19
        user(a_u5, "10:31:30.000", "Go ahead, keep the public API"),                               # 20
        set_updated("10:31:30.001"),                                                               # 21
        {"$rewindTo": a_u5},                                                                       # 22 failed request
        {"id": a_e1, "timestamp": ts("10:31:41.000"), "type": "error",
         "content": "[API Error: 500 Internal error encountered.]"},                               # 23
        set_updated("10:31:41.001"),                                                               # 24
        user(a_u6, "10:31:50.000", "Retry"),                                                       # 25
        {"$patch": {"updates": [{"id": a_u2, "content": [{"functionResponse": {
            "id": "read_file__k3f9", "name": "read_file", "response": {"output": "[masked]"}}}]}],
            "removeIds": [a_u6]}},                                                                 # 26 rollback
        user(a_u4, "10:32:00.000", "Apply only the first change; use sub-agents for the call sites"),  # 27
        set_updated("10:32:00.001"),                                                               # 28
        gemini(a_g3, "10:32:07.000", "", tokens(17000, 120, 16384, 300, 0), "gemini-3-pro-preview"),  # 29
        set_updated("10:32:07.002"),                                                               # 30
    ]
    write_jsonl(p(MAIN_JSONL), main)

    # ---- Running sub-agent: tool cycle, request in flight.
    b_u1, b_g1, b_u2 = (mid("b0b0b0b0", n) for n in range(1, 4))
    b_g1_msg = gemini(b_g1, "10:32:10.000", "", tokens(6000, 70, 0, 150, 0), "gemini-3-flash-preview")
    sub_running = [
        {"sessionId": SUB_RUNNING, "projectHash": sha(ORBIT_ROOT_ORIGINAL), "startTime": ts("10:32:07.100"),
         "lastUpdated": ts("10:32:07.100"), "kind": "subagent", "directories": [ORBIT_ROOT_ORIGINAL]},  # 1
        user(b_u1, "10:32:07.200", "Find all call sites of parseConfig"),                         # 2
        set_updated("10:32:07.201"),                                                               # 3
        b_g1_msg,                                                                                  # 4
        set_updated("10:32:10.001"),                                                               # 5
        with_calls(b_g1_msg, [call("grep_search__q1", "grep_search", {"pattern": "parseConfig"}, "success",
                                   "10:32:10.800")]),                                              # 6
        tool_result(b_u2, "10:32:10.810", "grep_search__q1", "grep_search", "src/cli.ts:12"),      # 7
        set_updated("10:32:10.811"),                                                               # 8
    ]
    write_jsonl(p(SUB_RUNNING_JSONL), sub_running)

    # ---- Finished sub-agent: complete_task, then $set.summary.
    e_u1, e_g1 = (mid("e0e0e0e0", n) for n in range(1, 3))
    e_g1_msg = gemini(e_g1, "10:32:12.000", "", tokens(5000, 300, 4096, 0, 0), "gemini-3-flash-preview")
    sub_done = [
        {"sessionId": SUB_DONE, "projectHash": sha(ORBIT_ROOT_ORIGINAL), "startTime": ts("10:32:07.150"),
         "lastUpdated": ts("10:32:07.150"), "kind": "subagent", "directories": [ORBIT_ROOT_ORIGINAL]},  # 1
        user(e_u1, "10:32:07.250", "Summarize the parser tests"),                                 # 2
        set_updated("10:32:07.251"),                                                               # 3
        e_g1_msg,                                                                                  # 4
        set_updated("10:32:12.001"),                                                               # 5
        with_calls(e_g1_msg, [call("complete_task__z9", "complete_task", {"result": "14 cases"}, "success",
                                   "10:32:12.300")]),                                              # 6
        {"$set": {"summary": "Parser tests cover 14 cases"}},                                      # 7
    ]
    write_jsonl(p(SUB_DONE_JSONL), sub_done)

    # Startup order = modification time ascending.
    mtimes = {rel: ms(clock) for rel, clock in ((LEGACY_JSON, "10:21:04.000"), (MAIN_JSONL, "10:32:08.000"),
                                                (SUB_RUNNING_JSONL, "10:32:11.000"), (SUB_DONE_JSONL, "10:32:13.000"),
                                                (MIGRATED_JSONL, "10:41:03.000"))}
    for rel, when in mtimes.items():
        os.utime(p(rel), (when / 1000, when / 1000))

    order = [LEGACY_JSON, MAIN_JSONL, SUB_RUNNING_JSONL, SUB_DONE_JSONL, MIGRATED_JSONL]
    files = {
        LEGACY_JSON: dict(
            source="gemini", project="nova", model="gemini-2.5-pro", isSubagent=False, parentFile=None,
            phase="idle", inFlightStartMs=None, lastLineMs=ms("10:21:03.004"), malformedLines=0,
            responses=[
                resp(c_g1, None, "10:20:09.000", 8000, 0, 260, 200, "gemini-2.5-pro"),
                resp(c_g2, "10:20:08.998", "10:20:14.000", 8400, 4096, 220, 0, "gemini-2.5-pro"),
            ]),
        MAIN_JSONL: dict(
            source="gemini", project="orbit", model="gemini-3-pro-preview", isSubagent=False, parentFile=None,
            phase="tools", inFlightStartMs=None, lastLineMs=ms("10:32:07.002"), malformedLines=0,
            responses=[
                resp(a_g1, "10:30:05.000", "10:30:11.000", 15000, 12288, 500, 410, "gemini-3-pro-preview"),
                resp(a_g2, "10:30:12.420", "10:30:20.000", 16296, 15000, 800, 160, "gemini-3-pro-preview"),
                resp(a_g3, "10:32:00.000", "10:32:07.000", 17000, 16384, 420, 300, "gemini-3-pro-preview"),
            ]),
        SUB_RUNNING_JSONL: dict(
            source="gemini", project="orbit", model="gemini-3-flash-preview", isSubagent=True, parentFile=MAIN_JSONL,
            phase="generating", inFlightStartMs=ms("10:32:10.810"), lastLineMs=ms("10:32:10.811"), malformedLines=0,
            responses=[
                resp(b_g1, "10:32:07.200", "10:32:10.000", 6000, 0, 220, 150, "gemini-3-flash-preview"),
            ]),
        SUB_DONE_JSONL: dict(
            source="gemini", project="orbit", model="gemini-3-flash-preview", isSubagent=True, parentFile=MAIN_JSONL,
            phase="idle", inFlightStartMs=None, lastLineMs=ms("10:32:12.300"), malformedLines=0,
            responses=[
                resp(e_g1, "10:32:07.250", "10:32:12.000", 5000, 4096, 300, 0, "gemini-3-flash-preview"),
            ]),
        MIGRATED_JSONL: dict(
            source="gemini", project="nova", model="gemini-2.5-flash", isSubagent=False, parentFile=None,
            phase="idle", inFlightStartMs=None, lastLineMs=ms("10:41:02.010"), malformedLines=1,
            responses=[
                resp(d_g3, "10:40:00.000", "10:40:04.000", 9000, 8192, 120, 40, "gemini-2.5-flash"),
                resp(d_g4, "10:40:06.520", "10:40:09.000", 9300, 9000, 150, 0, "gemini-2.5-flash"),
            ]),
    }

    def trace(rel, line, phase, in_flight=None):
        return dict(file=rel, afterLine=line, phase=phase, inFlightStartMs=None if in_flight is None else ms(in_flight))

    traces = [
        trace(MAIN_JSONL, 2, "generating", "10:30:05.000"),
        trace(MAIN_JSONL, 4, "tools"),
        trace(MAIN_JSONL, 6, "generating", "10:30:12.400"),
        trace(MAIN_JSONL, 7, "generating", "10:30:12.420"),
        trace(MAIN_JSONL, 9, "idle"),
        trace(MAIN_JSONL, 11, "idle"),
        trace(MAIN_JSONL, 12, "idle"),
        trace(MAIN_JSONL, 14, "generating", "10:31:00.000"),
        trace(MAIN_JSONL, 16, "generating", "10:31:00.000"),
        trace(MAIN_JSONL, 17, "idle"),
        trace(MAIN_JSONL, 19, "idle"),
        trace(MAIN_JSONL, 20, "generating", "10:31:30.000"),
        trace(MAIN_JSONL, 22, "idle"),
        trace(MAIN_JSONL, 25, "generating", "10:31:50.000"),
        trace(MAIN_JSONL, 26, "idle"),
        trace(MAIN_JSONL, 27, "generating", "10:32:00.000"),
        trace(MAIN_JSONL, 29, "tools"),
        trace(SUB_DONE_JSONL, 4, "tools"),
        trace(SUB_DONE_JSONL, 6, "idle"),
        trace(MIGRATED_JSONL, 5, "generating", "10:21:00.000"),
        trace(MIGRATED_JSONL, 6, "idle"),
        trace(MIGRATED_JSONL, 10, "tools"),
        trace(MIGRATED_JSONL, 12, "generating", "10:40:06.500"),
        trace(MIGRATED_JSONL, 13, "generating", "10:40:06.520"),
        trace(MIGRATED_JSONL, 18, "generating", "10:41:00.000"),
        trace(MIGRATED_JSONL, 20, "idle"),
    ]
    return {
        "_comment": "Responses of the copied legacy messages in %s are owned by %s." % (MIGRATED_JSONL, LEGACY_JSON),
        "order": order,
        "mtimes": mtimes,
        "discover": sorted([LEGACY_JSON, MIGRATED_JSONL, MAIN_JSONL, SUB_RUNNING_JSONL, SUB_DONE_JSONL]),
        "files": files,
        "traces": traces,
    }


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip())
        sys.exit(2)
    expected = write_fixtures(sys.argv[1])
    print(json.dumps(expected, indent=2))


if __name__ == "__main__":
    main()
