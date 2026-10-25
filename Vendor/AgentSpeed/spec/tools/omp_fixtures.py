#!/usr/bin/env python3
"""omp (oh-my-pi) session fixtures (METRICS 4.7), used by generate_fixtures.py.

  python3 spec/tools/omp_fixtures.py OUT_DIR

OUT_DIR/omp plays the role of `~/.omp`: the default root is omp/agent/sessions and one named profile root is
omp/profiles/work/agent/sessions. Files are laid out exactly as omp writes them. The returned expectations have the
shape of spec/fixtures/parser-expected.json (`order`, `files`, `mtimes`) plus `discover` (the session files discovery
must find across every automatic root of the config folder `omp`) and `traces` (phase checkpoints after a given
physical line of a file). Expected values are written by hand, independently of reference.py.
"""
import gzip
import json
import os
import sys
from datetime import datetime, timezone

DAY = "2026-10-20"
NEXT_DAY = "2026-10-21"
HOME = "/Users/dev"
SESSIONS = "omp/agent/sessions"
PROFILE_SESSIONS = "omp/profiles/work/agent/sessions"
RUNTIME = {"version": "18.12.6"}

OPUS = ("anthropic-messages", "anthropic", "claude-opus-5-5")
SONNET = ("anthropic-messages", "anthropic", "claude-sonnet-5-5")
HAIKU = ("anthropic-messages", "anthropic", "claude-haiku-5")
SONNET_OLD = ("anthropic-messages", "anthropic", "claude-sonnet-4-5")
GPT = ("openai-responses", "openai", "gpt-5.5")
GPT_MINI = ("openai-responses", "openai", "gpt-5.5-mini")
DUO = ("gitlab-duo-workflow", "gitlab-duo", "duo-chat-sonnet-5-5")


def ms(clock, day=DAY):
    """'10:50:05.006' -> Unix ms (UTC)."""
    dt = datetime.strptime("%s %s" % (day, clock), "%Y-%m-%d %H:%M:%S.%f").replace(tzinfo=timezone.utc)
    return int(dt.timestamp() * 1000)


def iso(value):
    """Unix ms -> ISO string as written by Date.toISOString()."""
    dt = datetime.fromtimestamp(value / 1000, tz=timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (value % 1000)


def uuid7(created, seed):
    """A deterministic UUIDv7 whose first 48 bits are the creation time."""
    h = "%012x" % created
    return "%s-%s-7%03x-%04x-%012x" % (h[:8], h[8:], seed * 0x2F1 % 0x1000, 0x8000 | (seed * 0x1D3 % 0x4000),
                                       seed * 0x9E3779B1 % (1 << 48))


def session_name(created, session_id):
    return "%s_%s.jsonl" % (iso(created).replace(":", "-").replace(".", "-"), session_id)


def usage(inp, out, cache_read, cache_write, reasoning=None, orchestration=None):
    total = inp + out + cache_read + cache_write + sum((orchestration or {}).values())
    u = {"input": inp, "output": out, "cacheRead": cache_read, "cacheWrite": cache_write, "totalTokens": total}
    if reasoning is not None:
        u["reasoningTokens"] = reasoning
    if orchestration is not None:
        u["orchestration"] = orchestration
    cost = [round(inp * 3e-6, 6), round(out * 15e-6, 6), round(cache_read * 3e-7, 6), round(cache_write * 3.75e-6, 6)]
    u["cost"] = {"input": cost[0], "output": cost[1], "cacheRead": cost[2], "cacheWrite": cost[3],
                 "total": round(sum(cost), 6)}
    return u


def text(value):
    return {"type": "text", "text": value}


def thinking(value):
    return {"type": "thinking", "thinking": value, "thinkingSignature": "sig-" + value[:12].replace(" ", "-")}


def tool_call(call_id, name, arguments):
    return {"type": "toolCall", "id": call_id, "name": name, "arguments": arguments}


class Session:
    """The physical lines of one session file. Entry ids are `<prefix><n:04x>`, parents chain in append order."""

    def __init__(self, prefix, runtime=RUNTIME):
        self.prefix, self.runtime = prefix, runtime
        self.lines, self.count, self.last_id = [], 0, None

    def line(self):
        """Physical line number of the last line written (1-based)."""
        return len(self.lines)

    def raw(self, value):
        self.lines.append(value)
        return self.line()

    def title(self, title, updated):
        slot = {"type": "title", "v": 1, "title": title, "source": "auto", "updatedAt": iso(updated), "pad": ""}
        size = len(json.dumps(slot, separators=(",", ":"), ensure_ascii=False).encode("utf-8")) + 1
        slot["pad"] = " " * (256 - size)
        return self.raw(slot)

    def header(self, created, session_id, cwd, **extra):
        return self.raw(dict({"type": "session", "version": 3, "id": session_id, "timestamp": iso(created), "cwd": cwd},
                             **extra))

    def entry(self, kind, when, **fields):
        self.count += 1
        entry_id = "%s%04x" % (self.prefix, self.count)
        row = {"type": kind, "id": entry_id, "parentId": self.last_id, "timestamp": iso(when)}
        if self.runtime:
            row["runtime"] = self.runtime
        row.update(fields)
        self.last_id = entry_id
        self.lines.append(row)
        return entry_id

    def copy(self, rows):
        """Entries copied verbatim from another session (forks, branches): same ids, timestamps and parents."""
        for row in rows:
            self.lines.append(row)
            if isinstance(row, dict) and isinstance(row.get("id"), str):
                self.last_id = row["id"]

    def entries(self):
        return [r for r in self.lines if isinstance(r, dict) and r.get("type") not in ("title", "session")]

    def model_change(self, when, model):
        return self.entry("model_change", when, model=model)

    def user(self, when, value, role="user"):
        return self.entry("message", when, message={"role": role, "content": [text(value)], "timestamp": when})

    def tool_result(self, when, call_id, name, value, is_error=False):
        return self.entry("message", when, message={
            "role": "toolResult", "toolCallId": call_id, "toolName": name, "content": [text(value)],
            "isError": is_error, "timestamp": when})

    def assistant(self, when, route, content, use, stop, started, duration=None, ttft=None, completed=None, **extra):
        api, provider, model = route
        msg = {"role": "assistant", "content": content}
        if api is not None:
            msg["api"] = api
        msg.update({"provider": provider, "model": model, "usage": use})
        if stop is not None:
            msg["stopReason"] = stop
        msg.update(extra)
        msg["timestamp"] = started
        for key, value in (("duration", duration), ("ttft", ttft), ("completedAt", completed)):
            if value is not None:
                msg[key] = value
        return self.entry("message", when, message=msg)

    def model_usage(self, when, purpose, route, use, stop="stop", role=None, **extra):
        api, provider, model = route
        fields = {"purpose": purpose}
        if role:
            fields["role"] = role
        fields.update({"api": api, "provider": provider, "model": model, "usage": use, "stopReason": stop})
        fields.update(extra)
        return self.entry("model_usage", when, **fields)

    def custom(self, when, custom_type, data):
        return self.entry("custom", when, customType=custom_type, data=data)

    def write(self, path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            for row in self.lines:
                f.write(row if isinstance(row, str) else json.dumps(row, separators=(",", ":"), ensure_ascii=False))
                f.write("\n")


PROVIDERS = {route[2]: route[1] for route in (OPUS, SONNET, HAIKU, SONNET_OLD, GPT, GPT_MINI, DUO)}


def resp(key, start, end, inp, cached, cache_write, out, reasoning, model):
    return {"key": key, "startMs": start, "endMs": end, "input": inp, "cachedInput": cached,
            "cacheWriteInput": cache_write, "cacheWrite1hInput": 0, "output": out, "reasoning": reasoning,
            "model": model, "provider": PROVIDERS[model], "fast": False, "final": True}


def key(entry_id, stamp):
    return "omp:%s:%d" % (entry_id, stamp)


def write_fixtures(out_dir):
    def p(rel):
        full = os.path.join(out_dir, *rel.split("/"))
        os.makedirs(os.path.dirname(full), exist_ok=True)
        return full

    files, traces, mtimes = {}, [], {}

    def trace(rel, line, phase, in_flight=None):
        traces.append(dict(file=rel, afterLine=line, phase=phase, inFlightStartMs=in_flight))

    # ---- 3.x - 6.9.0 era: no title slot, no runtime, no duration -> endMs = entry timestamp.
    legacy_created = ms("10:46:00.000")
    legacy_rel = "%s/-projects-legacy-tool/%s" % (SESSIONS, session_name(legacy_created, uuid7(legacy_created, 1)))
    s = Session("1e9a", runtime=None)
    s.header(legacy_created, uuid7(legacy_created, 1), HOME + "/projects/legacy-tool")              # 1
    s.model_change(ms("10:46:00.010"), "anthropic/claude-sonnet-4-5")                              # 2
    s.entry("thinking_level_change", ms("10:46:00.011"), thinkingLevel="medium")                   # 3
    s.user(ms("10:46:05.000"), "Why does the CLI print the version twice?")                        # 4
    l1 = s.assistant(ms("10:46:09.400"), SONNET_OLD, [tool_call("toolu_L1", "read", {"path": "src/cli.ts"})],
                     usage(12, 180, 0, 9800), "toolUse", ms("10:46:05.006"))                       # 5
    s.tool_result(ms("10:46:10.200"), "toolu_L1", "read", "console.log(version)")                  # 6
    l2 = s.assistant(ms("10:46:13.000"), SONNET_OLD, [text("main() logs it, and so does --version.")],
                     usage(8, 95, 9800, 120), "stop", ms("10:46:10.205"))                          # 7
    s.raw({"type": "message", "parentId": l2, "timestamp": iso(ms("10:47:00.000")),               # 8 no id: ignored
           "message": {"role": "user", "content": "Fix it", "timestamp": ms("10:47:00.000")}})
    s.write(p(legacy_rel))
    files[legacy_rel] = dict(
        source="omp", project="legacy-tool", model="claude-sonnet-4-5", isSubagent=False, parentFile=None,
        phase="idle", inFlightStartMs=None, lastLineMs=ms("10:46:13.000"), malformedLines=0,
        responses=[
            resp(key(l1, ms("10:46:05.006")), ms("10:46:05.006"), ms("10:46:09.400"), 9812, 0, 9800, 180, 0,
                 "claude-sonnet-4-5"),
            resp(key(l2, ms("10:46:10.205")), ms("10:46:10.205"), ms("10:46:13.000"), 9928, 9800, 120, 95, 0,
                 "claude-sonnet-4-5"),
        ])
    trace(legacy_rel, 4, "generating", ms("10:46:05.000"))
    trace(legacy_rel, 5, "tools")
    trace(legacy_rel, 6, "generating", ms("10:46:10.200"))
    trace(legacy_rel, 7, "idle")
    trace(legacy_rel, 8, "idle")
    mtimes[legacy_rel] = ms("10:47:01.000")

    # ---- 6.9.69 - 16.2 era: duration and ttft, no title slot; a `length` turn; a later header is ignored.
    comet_created = ms("10:48:00.000")
    comet_rel = "%s/-projects-comet/%s" % (SESSIONS, session_name(comet_created, uuid7(comet_created, 2)))
    s = Session("c0e7", runtime=None)
    s.header(comet_created, uuid7(comet_created, 2), HOME + "/projects/comet")                     # 1
    s.model_change(ms("10:48:00.010"), "openai/gpt-5.5")                                           # 2
    s.user(ms("10:48:02.000"), "Rename Orbit to Trajectory everywhere")                            # 3
    c1 = s.assistant(ms("10:48:08.420"), GPT, [thinking("Many files to touch"),
                                               tool_call("call_len1", "edit", {"path": "src/orbit.ts"})],
                     usage(5200, 4096, 0, 0, reasoning=3000), "length", ms("10:48:02.005"), duration=6400.618,
                     ttft=900.25)                                                                     # 4
    s.tool_result(ms("10:48:08.430"), "call_len1", "edit", "Skipped: arguments were truncated", True)  # 5
    c2 = s.assistant(ms("10:48:11.560"), GPT, [text("Renamed in 14 files.")],
                     usage(300, 410, 5100, 0, reasoning=120), "stop", ms("10:48:08.436"), duration=3100,
                     ttft=700)                                                                     # 6
    s.header(ms("10:49:00.000"), uuid7(ms("10:49:00.000"), 3), HOME + "/projects/other")           # 7 ignored
    s.user(ms("10:49:30.000"), "Now update the docs")                                              # 8
    s.write(p(comet_rel))
    files[comet_rel] = dict(
        source="omp", project="comet", model="gpt-5.5", isSubagent=False, parentFile=None,
        phase="generating", inFlightStartMs=ms("10:49:30.000"), lastLineMs=ms("10:49:30.000"), malformedLines=0,
        responses=[
            resp(key(c1, ms("10:48:02.005")), ms("10:48:02.005"), ms("10:48:08.405"), 5200, 0, 0, 4096, 3000,
                 "gpt-5.5"),
            resp(key(c2, ms("10:48:08.436")), ms("10:48:08.436"), ms("10:48:11.536"), 5400, 5100, 0, 410, 120,
                 "gpt-5.5"),
        ])
    trace(comet_rel, 3, "generating", ms("10:48:02.000"))
    trace(comet_rel, 4, "tools")
    trace(comet_rel, 5, "generating", ms("10:48:08.430"))
    trace(comet_rel, 6, "idle")
    trace(comet_rel, 7, "idle")
    trace(comet_rel, 8, "generating", ms("10:49:30.000"))
    mtimes[comet_rel] = ms("10:49:31.000")

    # ---- 18.1+ main session with a task sub-agent, which starts a nested sub-agent.
    main_created = ms("10:50:00.000")
    main_id = uuid7(main_created, 4)
    main_name = session_name(main_created, main_id)
    main_rel = "%s/-projects-pulsar/%s" % (SESSIONS, main_name)
    main_stem = main_rel[:-len(".jsonl")]
    sub_rel = main_stem + "/ScanCallSites.jsonl"
    nested_rel = main_stem + "/ScanCallSites/VerifyImports.jsonl"
    pulsar = HOME + "/projects/pulsar"

    m = Session("c0de")
    m.title("Refactor the pulsar scheduler", ms("10:50:05.600"))                                   # 1
    m.header(main_created, main_id, pulsar)                                                        # 2
    m.model_change(ms("10:50:00.020"), "anthropic/claude-opus-5-5")                                # 3
    m.entry("thinking_level_change", ms("10:50:00.021"), thinkingLevel="high", configured="auto")  # 4
    m.user(ms("10:50:05.000"), "Split the scheduler queue from the dispatcher")                    # 5
    a1 = m.assistant(ms("10:50:11.210"), OPUS, [thinking("Find the queue first"),
                                                tool_call("toolu_t1", "read", {"path": "src/scheduler.ts"}),
                                                tool_call("toolu_t2", "grep", {"pattern": "dispatch("})],
                     usage(3, 420, 0, 18000, reasoning=150), "toolUse", ms("10:50:05.006"), duration=6200,
                     ttft=1480, completed=ms("10:50:11.207"))                                      # 6
    mu1 = m.model_usage(ms("10:50:11.300"), "ttsr", HAIKU, usage(900, 40, 0, 0), role="smol")      # 7
    m.tool_result(ms("10:50:11.900"), "toolu_t1", "read", "export class Scheduler {}")             # 8
    m.tool_result(ms("10:50:12.400"), "toolu_t2", "grep", "src/run.ts:41")                         # 9
    m.custom(ms("10:50:12.402"), "system-prompt-digest", "9c41f0d2b7aa")                           # 10
    a2 = m.assistant(ms("10:50:16.520"), OPUS, [text("I'll map the call sites with a sub-agent."),
                                                tool_call("toolu_t3", "task", {"name": "ScanCallSites"})],
                     usage(5, 260, 18000, 600), "stop", ms("10:50:12.405"), duration=4100, ttft=900,
                     completed=ms("10:50:16.512"))                                                 # 11 stop + call
    m.custom(ms("10:50:16.530"), "tool_execution_start",
             {"toolCallId": "toolu_t3", "toolName": "task", "startedAt": iso(ms("10:50:16.530"))})  # 12
    m.tool_result(ms("10:50:44.000"), "toolu_t3", "task", "3 call sites, imports verified")        # 13
    a3 = m.assistant(ms("10:50:46.520"), OPUS, [text("Moving the queue into its own module...")],
                     usage(4, 90, 18600, 0), "stop", ms("10:50:44.004"), duration=2500,
                     completed=ms("10:50:46.508"), stopDetails={"type": "pause_turn"})              # 14 pause_turn
    a4_message = dict(role="assistant", content=[text("Done: Queue lives in src/queue.ts.")], api=OPUS[0],
                      provider=OPUS[1], model=OPUS[2], usage=usage(2, 150, 18700, 0), stopReason="stop",
                      timestamp=ms("10:50:46.530"), duration=3000, completedAt=ms("10:50:49.535"))
    a4 = m.entry("message", ms("10:50:49.540"), message=a4_message)                                # 15
    a4_repeat = dict(m.lines[-1], message=dict(a4_message, usage=usage(2, 152, 18700, 0)))
    m.raw(a4_repeat)                                                                               # 16 same key
    m.model_usage(ms("10:50:49.600"), "job-widget", HAIKU, usage(0, 0, 0, 0), stop="error",
                  errorMessage="aborted")                                                          # 17 zero usage
    m.entry("custom_message", ms("10:50:55.000"), customType="com.example.notes",
            content="Remember the queue size limit", display=True)                                 # 18
    m.entry("label", ms("10:51:00.000"), targetId=a4, label="queue split")                          # 19
    m.user(ms("10:52:00.000"), "Run the tests")                                                    # 20
    e1 = m.assistant(ms("10:52:01.810"), OPUS, [tool_call("toolu_t4", "bash", {"command": "bun test"})],
                     usage(3, 12, 18800, 0), "error", ms("10:52:00.006"), duration=1800,
                     completed=ms("10:52:01.808"), errorMessage="overloaded_error")                # 21 error
    m.tool_result(ms("10:52:01.812"), "toolu_t4", "bash", "Tool call aborted", True)               # 22 placeholder
    m.user(ms("10:52:20.000"), "Run the tests")                                                    # 23
    ab1 = m.assistant(ms("10:52:22.610"), OPUS, [text("Running bun te")], usage(4, 33, 18800, 0), "aborted",
                      ms("10:52:20.005"), duration=2600, errorMessage="Request was aborted")       # 24 aborted
    m.user(ms("10:53:00.000"), "Run the tests, please")                                            # 25
    a5 = m.assistant(ms("10:53:04.020"), OPUS, [tool_call("toolu_t5", "bash", {"command": "bun test"})],
                     usage(6, 75, 18900, 300, reasoning=20), "toolUse", ms("10:53:00.006"), duration=4000,
                     completed=ms("10:53:04.012"))                                                 # 26
    m.custom(ms("10:53:04.030"), "tool_execution_start",
             {"toolCallId": "toolu_t5", "toolName": "bash", "startedAt": iso(ms("10:53:04.030"))})  # 27
    m.custom(ms("10:53:30.000"), "session_exit",
             {"reason": "SIGTERM", "kind": "signal", "recordedAt": iso(ms("10:53:30.000")),
              "pendingToolCalls": [{"toolCallId": "toolu_t5", "toolName": "bash"}]})                # 28
    m.assistant(ms("10:58:00.000"), OPUS, [], usage(0, 0, 0, 0), "aborted", ms("10:58:00.000"),
                errorMessage="Interrupted by process exit")                                        # 29 placeholder
    m.user(ms("10:58:10.000"), "Continue")                                                         # 30
    a6 = m.assistant(ms("10:58:15.020"), OPUS, [tool_call("toolu_t6", "read", {"path": "test/queue.test.ts"})],
                     usage(3, 110, 0, 19400), "toolUse", ms("10:58:10.006"), duration=5000,
                     completed=ms("10:58:15.011"))                                                 # 31
    m.tool_result(ms("10:58:16.000"), "toolu_t6", "read", "12 passing")                            # 32
    a7 = m.assistant(ms("10:58:19.520"), OPUS, [text("All 12 queue tests pass.")],
                     usage(2, 340, 19400, 500, reasoning=90), "stop", ms("10:58:16.004"), duration=3500,
                     completed=ms("10:58:19.509"))                                                 # 33
    m.write(p(main_rel))
    files[main_rel] = dict(
        source="omp", project="pulsar", model="claude-opus-5-5", isSubagent=False, parentFile=None,
        phase="idle", inFlightStartMs=None, lastLineMs=ms("10:58:19.520"), malformedLines=0,
        responses=[
            resp(key(a1, ms("10:50:05.006")), ms("10:50:05.006"), ms("10:50:11.206"), 18003, 0, 18000, 420, 150,
                 "claude-opus-5-5"),
            resp(key(mu1, ms("10:50:11.300")), None, ms("10:50:11.300"), 900, 0, 0, 40, 0, "claude-haiku-5"),
            resp(key(a2, ms("10:50:12.405")), ms("10:50:12.405"), ms("10:50:16.505"), 18605, 18000, 600, 260, 0,
                 "claude-opus-5-5"),
            resp(key(a3, ms("10:50:44.004")), ms("10:50:44.004"), ms("10:50:46.504"), 18604, 18600, 0, 90, 0,
                 "claude-opus-5-5"),
            resp(key(a4, ms("10:50:46.530")), ms("10:50:46.530"), ms("10:50:49.530"), 18702, 18700, 0, 152, 0,
                 "claude-opus-5-5"),
            resp(key(e1, ms("10:52:00.006")), None, ms("10:52:01.806"), 18803, 18800, 0, 12, 0, "claude-opus-5-5"),
            resp(key(ab1, ms("10:52:20.005")), None, ms("10:52:22.605"), 18804, 18800, 0, 33, 0, "claude-opus-5-5"),
            resp(key(a5, ms("10:53:00.006")), ms("10:53:00.006"), ms("10:53:04.006"), 19206, 18900, 300, 75, 20,
                 "claude-opus-5-5"),
            resp(key(a6, ms("10:58:10.006")), ms("10:58:10.006"), ms("10:58:15.006"), 19403, 0, 19400, 110, 0,
                 "claude-opus-5-5"),
            resp(key(a7, ms("10:58:16.004")), ms("10:58:16.004"), ms("10:58:19.504"), 19902, 19400, 500, 340, 90,
                 "claude-opus-5-5"),
        ])
    for line, phase, in_flight in (
            (2, "idle", None), (5, "generating", ms("10:50:05.000")), (6, "tools", None), (7, "tools", None),
            (8, "tools", None), (9, "generating", ms("10:50:12.400")), (10, "generating", ms("10:50:12.400")),
            (11, "tools", None), (12, "tools", None), (13, "generating", ms("10:50:44.000")),
            (14, "generating", ms("10:50:46.504")), (15, "idle", None), (16, "idle", None), (17, "idle", None),
            (20, "generating", ms("10:52:00.000")), (21, "idle", None), (22, "idle", None),
            (23, "generating", ms("10:52:20.000")), (24, "idle", None), (25, "generating", ms("10:53:00.000")),
            (26, "tools", None), (27, "tools", None), (28, "idle", None), (29, "idle", None),
            (30, "generating", ms("10:58:10.000")), (31, "tools", None), (32, "generating", ms("10:58:16.000")),
            (33, "idle", None)):
        trace(main_rel, line, phase, in_flight)
    mtimes[main_rel] = ms("10:58:20.000")

    # ---- Task sub-agent: a rejected yield does not end it, a successful yield does.
    sub_created = ms("10:50:16.600")
    sub = Session("5ca1")
    sub.title("ScanCallSites", ms("10:50:16.700"))                                                  # 1
    sub.header(sub_created, uuid7(sub_created, 5), pulsar,
               parentSession=HOME + "/.omp/agent/sessions/-projects-pulsar/" + main_name)          # 2
    sub.model_change(ms("10:50:16.610"), "anthropic/claude-sonnet-5-5")                            # 3
    sub.user(ms("10:50:16.700"), "List every caller of Scheduler.dispatch")                        # 4
    sa1 = sub.assistant(ms("10:50:19.720"), SONNET, [tool_call("toolu_s1", "grep", {"pattern": "dispatch("}),
                                                     tool_call("toolu_s2", "find", {"pattern": "*.ts"})],
                        usage(6, 140, 0, 7000), "toolUse", ms("10:50:16.705"), duration=3000,
                        completed=ms("10:50:19.712"))                                              # 5
    sub.tool_result(ms("10:50:20.100"), "toolu_s1", "grep", "src/run.ts:41\nsrc/cli.ts:12")         # 6
    sub.tool_result(ms("10:50:20.300"), "toolu_s2", "find", "41 files")                            # 7
    sa2 = sub.assistant(ms("10:50:23.120"), SONNET, [tool_call("toolu_s3", "yield", {"result": "2 callers"})],
                        usage(4, 60, 7000, 300), "toolUse", ms("10:50:20.305"), duration=2800,
                        completed=ms("10:50:23.110"))                                              # 8
    sub.tool_result(ms("10:50:23.200"), "toolu_s3", "yield", "Output does not match the schema", True)  # 9
    sa3 = sub.assistant(ms("10:50:25.420"), SONNET, [tool_call("toolu_s4", "task", {"name": "VerifyImports"})],
                        usage(3, 85, 7300, 0, reasoning=25), "toolUse", ms("10:50:23.205"), duration=2200,
                        completed=ms("10:50:25.410"))                                              # 10
    sub.tool_result(ms("10:50:41.000"), "toolu_s4", "task", "imports verified")                    # 11
    sa4 = sub.assistant(ms("10:50:43.020"), SONNET,
                        [tool_call("toolu_s5", "yield", {"result": {"callers": 3}})],
                        usage(2, 48, 7400, 0), "toolUse", ms("10:50:41.004"), duration=2000,
                        completed=ms("10:50:43.010"))                                              # 12
    sub.tool_result(ms("10:50:43.100"), "toolu_s5", "yield", "Result accepted")                    # 13
    sub.write(p(sub_rel))
    files[sub_rel] = dict(
        source="omp", project="pulsar", model="claude-sonnet-5-5", isSubagent=True, parentFile=main_rel,
        phase="idle", inFlightStartMs=None, lastLineMs=ms("10:50:43.100"), malformedLines=0,
        responses=[
            resp(key(sa1, ms("10:50:16.705")), ms("10:50:16.705"), ms("10:50:19.705"), 7006, 0, 7000, 140, 0,
                 "claude-sonnet-5-5"),
            resp(key(sa2, ms("10:50:20.305")), ms("10:50:20.305"), ms("10:50:23.105"), 7304, 7000, 300, 60, 0,
                 "claude-sonnet-5-5"),
            resp(key(sa3, ms("10:50:23.205")), ms("10:50:23.205"), ms("10:50:25.405"), 7303, 7300, 0, 85, 25,
                 "claude-sonnet-5-5"),
            resp(key(sa4, ms("10:50:41.004")), ms("10:50:41.004"), ms("10:50:43.004"), 7402, 7400, 0, 48, 0,
                 "claude-sonnet-5-5"),
        ])
    for line, phase, in_flight in (
            (2, "idle", None), (4, "generating", ms("10:50:16.700")), (5, "tools", None), (6, "tools", None),
            (7, "generating", ms("10:50:20.300")), (8, "tools", None), (9, "generating", ms("10:50:23.200")),
            (10, "tools", None), (11, "generating", ms("10:50:41.000")), (12, "tools", None), (13, "idle", None)):
        trace(sub_rel, line, phase, in_flight)
    mtimes[sub_rel] = ms("10:50:44.000")

    # ---- Nested sub-agent started by ScanCallSites.
    nested_created = ms("10:50:25.500")
    nested = Session("9e57")
    nested.title("VerifyImports", ms("10:50:25.600"))                                              # 1
    nested.header(nested_created, uuid7(nested_created, 6), pulsar,
                  parentSession=HOME + "/.omp/agent/sessions/" + sub_rel[len(SESSIONS) + 1:])     # 2
    nested.model_change(ms("10:50:25.510"), "anthropic/claude-haiku-5")                            # 3
    nested.user(ms("10:50:25.600"), "Check that every caller imports Scheduler from src/queue")    # 4
    na1 = nested.assistant(ms("10:50:27.120"), HAIKU, [tool_call("toolu_n1", "read", {"path": "src/run.ts"})],
                           usage(3, 45, 0, 2500, reasoning=10), "toolUse", ms("10:50:25.604"), duration=1500,
                           completed=ms("10:50:27.110"))                                           # 5
    nested.tool_result(ms("10:50:28.000"), "toolu_n1", "read", "import { Scheduler } from './queue'")  # 6
    na2 = nested.assistant(ms("10:50:29.720"), HAIKU, [tool_call("toolu_n2", "yield", {"result": "ok"})],
                           usage(2, 30, 2500, 0), "toolUse", ms("10:50:28.004"), duration=1700,
                           completed=ms("10:50:29.712"))                                           # 7
    nested.tool_result(ms("10:50:29.800"), "toolu_n2", "yield", "Result accepted")                 # 8
    nested.write(p(nested_rel))
    files[nested_rel] = dict(
        source="omp", project="pulsar", model="claude-haiku-5", isSubagent=True, parentFile=sub_rel,
        phase="idle", inFlightStartMs=None, lastLineMs=ms("10:50:29.800"), malformedLines=0,
        responses=[
            resp(key(na1, ms("10:50:25.604")), ms("10:50:25.604"), ms("10:50:27.104"), 2503, 0, 2500, 45, 10,
                 "claude-haiku-5"),
            resp(key(na2, ms("10:50:28.004")), ms("10:50:28.004"), ms("10:50:29.704"), 2502, 2500, 0, 30, 0,
                 "claude-haiku-5"),
        ])
    mtimes[nested_rel] = ms("10:50:30.000")

    # ---- /fork of the main session: fresh header, every entry copied verbatim, then a new turn.
    fork_created = ms("11:00:00.000")
    fork_id = uuid7(fork_created, 7)
    fork_rel = "%s/-projects-pulsar/%s" % (SESSIONS, session_name(fork_created, fork_id))
    fork_stem = fork_rel[:-len(".jsonl")]
    f = Session("f04c")
    f.title("Refactor the pulsar scheduler (fork)", ms("11:00:00.000"))                            # 1
    f.header(fork_created, fork_id, pulsar, parentSession=main_id)                                 # 2
    f.copy(m.entries())                                                                            # 3-33 copies
    copied_end = f.line()
    f.raw('{"type":"message","id":"f04c0001","parentId":"%s","timestamp":"2026-10-20T11:00:0' % a7)  # 34 torn
    f.user(ms("11:00:05.000"), "Try a ring buffer instead")                                        # 35
    fa1 = f.assistant(ms("11:00:09.420"), OPUS, [text("A ring buffer fits: fixed capacity, O(1) push.")],
                      usage(3, 310, 19000, 400, reasoning=80), "stop", ms("11:00:05.006"), duration=4400,
                      completed=ms("11:00:09.410"))                                                # 36
    f.write(p(fork_rel))
    files[fork_rel] = dict(
        source="omp", project="pulsar", model="claude-opus-5-5", isSubagent=False, parentFile=None,
        phase="idle", inFlightStartMs=None, lastLineMs=ms("11:00:09.420"), malformedLines=1,
        responses=[
            resp(key(fa1, ms("11:00:05.006")), ms("11:00:05.006"), ms("11:00:09.406"), 19403, 19000, 400, 310, 80,
                 "claude-opus-5-5"),
        ])
    trace(fork_rel, 2, "idle")
    trace(fork_rel, copied_end, "idle")
    trace(fork_rel, copied_end + 1, "idle")
    trace(fork_rel, copied_end + 2, "generating", ms("11:00:05.000"))
    trace(fork_rel, copied_end + 3, "idle")
    mtimes[fork_rel] = ms("11:00:10.000")

    # ---- The fork's background copy of the source's artifacts folder: byte-identical sub-agent transcripts.
    sub_copy_rel = fork_stem + "/ScanCallSites.jsonl"
    nested_copy_rel = fork_stem + "/ScanCallSites/VerifyImports.jsonl"
    sub.write(p(sub_copy_rel))
    nested.write(p(nested_copy_rel))
    files[sub_copy_rel] = dict(
        source="omp", project="pulsar", model=None, isSubagent=True, parentFile=fork_rel,
        phase="idle", inFlightStartMs=None, lastLineMs=ms("10:50:43.100"), malformedLines=0, responses=[])
    files[nested_copy_rel] = dict(
        source="omp", project="pulsar", model=None, isSubagent=True, parentFile=sub_copy_rel,
        phase="idle", inFlightStartMs=None, lastLineMs=ms("10:50:29.800"), malformedLines=0, responses=[])
    for line, phase, in_flight in ((4, "generating", ms("10:50:16.700")), (5, "generating", ms("10:50:16.700")),
                                   (7, "generating", ms("10:50:16.700")), (9, "generating", ms("10:50:16.700")),
                                   (13, "idle", None)):
        trace(sub_copy_rel, line, phase, in_flight)
    mtimes[sub_copy_rel] = ms("11:00:02.000")
    mtimes[nested_copy_rel] = ms("11:00:03.000")

    # ---- /tree branch whose source session no longer exists: only the copied-history rule removes the copies.
    branch_created = ms("11:10:00.000")
    branch_id = uuid7(branch_created, 8)
    gone_created = ms("11:09:40.000")
    branch_rel = "%s/-projects-pulsar/%s" % (SESSIONS, session_name(branch_created, branch_id))
    gone = Session("90e0")
    gone.model_change(ms("11:09:40.010"), "openai/gpt-5.5")
    gone.user(ms("11:09:45.000"), "Profile the dispatcher")
    gone.assistant(ms("11:09:48.020"), GPT, [tool_call("call_b1", "bash", {"command": "bun run profile"})],
                   usage(3, 200, 0, 9000), "toolUse", ms("11:09:45.006"), duration=3000)
    gone.tool_result(ms("11:09:53.000"), "call_b1", "bash", "dispatch: 41 ms")
    gone.assistant(ms("11:09:55.020"), GPT, [text("dispatch() dominates.")], usage(2, 150, 9000, 100), "stop",
                   ms("11:09:53.005"), duration=2000)  # 4.98 s before the branch header: still copied history
    b = Session("b4a7")
    b.title("Profile the dispatcher", ms("11:10:00.000"))                                          # 1
    b.header(branch_created, branch_id, pulsar,
             parentSession=HOME + "/.omp/agent/sessions/-projects-pulsar/" + session_name(
                 gone_created, uuid7(gone_created, 9)))                                            # 2
    b.copy(gone.entries())                                                                         # 3-7 copies
    b.entry("branch_summary", ms("11:10:00.050"), fromId=b.last_id,
            summary="Profiled the dispatcher; dispatch() dominates.")                              # 8
    b.user(ms("11:10:05.000"), "Compare with the ring buffer")                                     # 9
    b.assistant(ms("11:10:07.000"), (None, "openai-compatible", "qwen3-coder"), [text("Comparing...")],
                usage(5, 60, 0, 0), "stop", ms("11:10:05.004"), duration=1900)                     # 10 no api
    g2 = b.assistant(ms("11:10:12.310"), GPT, [text("The ring buffer is 3x faster.")], usage(2, 120, 9000, 0),
                     "stop", 0, completed=ms("11:10:12.300"))                                      # 11 timestamp 0
    b.write(p(branch_rel))
    files[branch_rel] = dict(
        source="omp", project="pulsar", model="gpt-5.5", isSubagent=False, parentFile=None,
        phase="idle", inFlightStartMs=None, lastLineMs=ms("11:10:12.310"), malformedLines=0,
        responses=[resp(key(g2, ms("11:10:12.310")), None, ms("11:10:12.300"), 9002, 9000, 0, 120, 0, "gpt-5.5")])
    trace(branch_rel, 6, "idle")
    trace(branch_rel, 7, "idle")
    trace(branch_rel, 9, "generating", ms("11:10:05.000"))
    trace(branch_rel, 10, "generating", ms("11:10:05.000"))
    trace(branch_rel, 11, "idle")
    mtimes[branch_rel] = ms("11:10:13.000")

    # ---- /resume @claude: the Claude Code fixture session imported with its original timestamps and usage.
    import_created = ms("11:20:00.000")
    import_id = uuid7(import_created, 10)
    import_rel = "%s/-projects-nova/%s" % (SESSIONS, session_name(import_created, import_id))
    i = Session("1a90")
    i.title("Build the launch pad", ms("11:20:00.000"))                                            # 1
    i.header(import_created, import_id, HOME + "/projects/nova")                                   # 2

    def imported(entry_id, when, **fields):
        row = {"type": fields.pop("kind", "message"), "id": entry_id, "parentId": i.last_id, "timestamp": iso(when)}
        row.update(fields)
        i.copy([row])

    claude = dict(api=OPUS[0], provider=OPUS[1], model=OPUS[2])
    imported("claude-u1792490520000-user-1", ms("10:02:00.000"),
             message={"role": "user", "content": "Build the launch pad", "timestamp": ms("10:02:00.000")})   # 3
    imported("claude-uuid-msg_A1792490524000-model", ms("10:02:04.000"), kind="model_change",
             model="anthropic/claude-opus-5-5")                                                    # 4
    imported("claude-uuid-msg_A1792490524000-assistant-2", ms("10:02:04.000"), message=dict(
        role="assistant", content=[thinking("Plan the launch pad")], **claude, responseId="msg_A",
        usage=usage(2, 150, 20000, 1000), stopReason="stop", timestamp=ms("10:02:04.000")))       # 5
    imported("claude-uuid-msg_A1792490526050-assistant-3", ms("10:02:06.050"), message=dict(
        role="assistant", content=[tool_call("t1", "bash", {"command": "mkdir pad"})], **claude, responseId="msg_A",
        usage=usage(2, 300, 20000, 1000), stopReason="toolUse", timestamp=ms("10:02:06.050")))    # 6
    imported("claude-u1792490529000-toolResult-4", ms("10:02:09.000"), message={
        "role": "toolResult", "toolCallId": "t1", "toolName": "bash", "content": [text("ok")], "isError": False,
        "timestamp": ms("10:02:09.000")})                                                          # 7
    imported("claude-uuid-msg_B1792490532000-assistant-5", ms("10:02:12.000"), message=dict(
        role="assistant", content=[text("The launch pad is ready.")], **claude, responseId="msg_B",
        usage=usage(5, 240, 21000, 200), stopReason="stop", timestamp=ms("10:02:12.000")))        # 8
    i.user(ms("11:20:30.000"), "Add a countdown")                                                  # 9
    ia1 = i.assistant(ms("11:20:35.215"), OPUS, [text("Added a 10-second countdown.")], usage(4, 380, 0, 22000),
                      "stop", ms("11:20:30.006"), duration=5200, ttft=1100, completed=ms("11:20:35.210"))  # 10
    imu = i.model_usage(ms("11:20:35.400"), "memory", GPT_MINI, usage(1200, 64, 0, 0, reasoning=32),
                        role="smol")                                                               # 11
    i.custom(ms("11:21:00.000"), "session_exit",
             {"reason": "exit", "kind": "normal", "recordedAt": iso(ms("11:21:00.000"))})          # 12
    i.write(p(import_rel))
    files[import_rel] = dict(
        source="omp", project="nova", model="claude-opus-5-5", isSubagent=False, parentFile=None,
        phase="idle", inFlightStartMs=None, lastLineMs=ms("11:21:00.000"), malformedLines=0,
        responses=[
            resp(key(ia1, ms("11:20:30.006")), ms("11:20:30.006"), ms("11:20:35.206"), 22004, 0, 22000, 380, 0,
                 "claude-opus-5-5"),
            resp(key(imu, ms("11:20:35.400")), None, ms("11:20:35.400"), 1200, 0, 0, 64, 32, "gpt-5.5-mini"),
        ])
    trace(import_rel, 6, "idle")
    trace(import_rel, 7, "idle")
    trace(import_rel, 9, "generating", ms("11:20:30.000"))
    trace(import_rel, 10, "idle")
    trace(import_rel, 11, "idle")
    mtimes[import_rel] = ms("11:21:01.000")

    # ---- Profile `work`: a Windows working directory, GitLab Duo without duration, midnight crossing.
    prof_created = ms("23:58:00.000")
    prof_rel = "%s/-projects-orbit/%s" % (PROFILE_SESSIONS, session_name(prof_created, uuid7(prof_created, 11)))
    w = Session("0b17")
    w.title("Orbit release checklist", ms("23:59:50.000"))                                         # 1
    w.header(prof_created, uuid7(prof_created, 11), "C:\\Users\\dev\\projects\\orbit")             # 2
    w.model_change(ms("23:58:00.010"), "gitlab-duo/duo-chat-sonnet-5-5")                           # 3
    w.user(ms("23:59:50.000"), "Follow the release checklist", role="developer")                   # 4
    d1 = w.assistant(ms("23:59:58.260"), DUO, [tool_call("g1", "bash", {"command": "git tag --list"})],
                     usage(1200, 90, 0, 0), "toolUse", ms("23:59:50.004"), completed=ms("23:59:58.250"))  # 5
    w.tool_result(ms("23:59:59.900"), "g1", "bash", "v1.0.0")                                       # 6
    d2 = w.assistant(ms("00:00:05.510", NEXT_DAY), DUO, [text("Tagging v1.1")], usage(1300, 20, 0, 0), None,
                     ms("23:59:59.905"), duration=5600)                                            # 7 no stopReason
    w.model_change(ms("00:00:09.000", NEXT_DAY), "anthropic/claude-sonnet-5-5")                    # 8
    w.user(ms("00:00:10.000", NEXT_DAY), "Write the release notes")                                # 9
    pmu = w.model_usage(ms("00:00:10.100", NEXT_DAY), "auto-thinking", GPT_MINI,
                        usage(400, 12, 0, 0, reasoning=8), role="tiny")                            # 10
    d3 = w.assistant(ms("00:00:14.012", NEXT_DAY), SONNET, [text("Release notes drafted.")],
                     usage(1400, 210, 1200, 0, reasoning=60, orchestration={"input": 300, "output": 50}), "stop",
                     ms("00:00:10.205", NEXT_DAY), duration=3800, completed=ms("00:00:14.010", NEXT_DAY))  # 11
    w.write(p(prof_rel))
    files[prof_rel] = dict(
        source="omp", project="orbit", model="claude-sonnet-5-5", isSubagent=False, parentFile=None,
        phase="idle", inFlightStartMs=None, lastLineMs=ms("00:00:14.012", NEXT_DAY), malformedLines=0,
        responses=[
            resp(key(d1, ms("23:59:50.004")), ms("23:59:50.004"), ms("23:59:58.250"), 1200, 0, 0, 90, 0,
                 "duo-chat-sonnet-5-5"),
            resp(key(d2, ms("23:59:59.905")), None, ms("00:00:05.505", NEXT_DAY), 1300, 0, 0, 20, 0,
                 "duo-chat-sonnet-5-5"),
            resp(key(pmu, ms("00:00:10.100", NEXT_DAY)), None, ms("00:00:10.100", NEXT_DAY), 400, 0, 0, 12, 8,
                 "gpt-5.5-mini"),
            resp(key(d3, ms("00:00:10.205", NEXT_DAY)), ms("00:00:10.205", NEXT_DAY), ms("00:00:14.005", NEXT_DAY),
                 2600, 1200, 0, 210, 60, "claude-sonnet-5-5"),
        ])
    for line, phase, in_flight in (
            (4, "generating", ms("23:59:50.000")), (5, "tools", None), (6, "generating", ms("23:59:59.900")),
            (7, "idle", None), (9, "generating", ms("00:00:10.000", NEXT_DAY)),
            (10, "generating", ms("00:00:10.000", NEXT_DAY)), (11, "idle", None)):
        trace(prof_rel, line, phase, in_flight)
    mtimes[prof_rel] = ms("00:00:15.000", NEXT_DAY)

    # ---- `/new` in the same profile: the header is materialized at once, nothing else is written yet.
    fresh_created = ms("00:10:00.000", NEXT_DAY)
    fresh_rel = "%s/-projects-orbit/%s" % (PROFILE_SESSIONS, session_name(fresh_created, uuid7(fresh_created, 12)))
    n = Session("0f2e")
    n.title("", fresh_created)                                                                     # 1
    n.header(fresh_created, uuid7(fresh_created, 12), "C:\\Users\\dev\\projects\\orbit")           # 2
    n.write(p(fresh_rel))
    files[fresh_rel] = dict(
        source="omp", project="orbit", model=None, isSubagent=False, parentFile=None,
        phase="idle", inFlightStartMs=None, lastLineMs=fresh_created, malformedLines=0, responses=[])
    trace(fresh_rel, 2, "idle")
    mtimes[fresh_rel] = ms("00:10:01.000", NEXT_DAY)

    # ---- Discovery decoys: none of these is a session file.
    head = "".join(json.dumps(r, separators=(",", ":")) + "\n" for r in m.lines[:5])
    decoys = {
        "%s/-projects-pulsar/.omp-gc-compress-4242/%s" % (SESSIONS, main_name): head,
        "%s/-projects-pulsar/.%s.7f3e.tmp" % (SESSIONS, main_name): head,
        "%s/-projects-pulsar/%s.7f3e.bak" % (SESSIONS, main_name): head,
        main_stem + "/ScanCallSites.log": "grep dispatch( -> 2 matches\n",
        main_stem + "/ScanCallSites.md": "# ScanCallSites\n\n3 call sites.\n",
        main_stem + "/draft.txt": "queue split\n",
        "%s/stray.jsonl" % SESSIONS: head,
        "omp/collab/room-7c1e.jsonl": head,
    }
    for rel, content in decoys.items():
        with open(p(rel), "w", encoding="utf-8", newline="\n") as fh:
            fh.write(content)
    archived = "omp/agent/archive/sessions/-projects-pulsar/%s.gz" % session_name(gone_created, uuid7(gone_created, 9))
    with open(p(archived), "wb") as fh:
        fh.write(gzip.compress(head.encode("utf-8"), mtime=0))

    with open(p(import_rel), "rb") as fh:
        raw = fh.read()
    tail_offset = [i for i, byte in enumerate(raw) if byte == 0x0A][4]  # the newline that ends line 5
    tail_reads = [dict(file=import_rel, offset=tail_offset, project="nova", phase="idle", inFlightStartMs=None,
                       lastLineMs=ms("11:21:00.000"),
                       responseKeys=[key(ia1, ms("11:20:30.006")), key(imu, ms("11:20:35.400"))])]

    order = sorted(mtimes, key=lambda rel: (mtimes[rel], rel))
    for rel in order:
        os.utime(p(rel), (mtimes[rel] / 1000, mtimes[rel] / 1000))
    return {
        "_comment": "omp roots: %s and every %s. Copied history: the fork and the branch copy entries with their "
                    "original timestamps under a fresh header; the import keeps Claude-era timestamps. The fork's "
                    "artifacts copies are byte-identical to the originals, so every key is owned by the originals. "
                    "The main session repeats one assistant entry with changed usage: re-reading a file after a "
                    "rewrite (identity change, METRICS 5) merges the same keys in exactly this way, as same-file "
                    "updates (4.4). `tailReads` start reading at byte `offset` (a newline, so reading begins on the "
                    "next line) after the files before it in `order`: the header must still be read first (4.7)."
                    % (SESSIONS, "omp/profiles/<name>/agent/sessions"),
        "order": order,
        "mtimes": mtimes,
        "discover": sorted(files),
        "files": {rel: files[rel] for rel in order},
        "traces": traces,
        "tailReads": tail_reads,
    }


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip())
        sys.exit(2)
    print(json.dumps(write_fixtures(sys.argv[1]), indent=2))


if __name__ == "__main__":
    main()
