#!/usr/bin/env python3
"""WorkBuddy session fixtures (METRICS 4.9), used by generate_fixtures.py.

  python3 spec/tools/workbuddy_fixtures.py OUT_DIR

OUT_DIR/workbuddy plays the role of the home folder `~`: `.workbuddy` is the China edition's data folder (source
`workbuddy`) and `.workbuddy-ai` the international edition's (source `workbuddyAi`). Files are laid out as the embedded
CodeBuddy Code CLI (2.161.0, in WorkBuddy 5.8.3 / 5.8.4) writes them, with the key order and fields of its
`transformItemForSaveAsync`; every text is a synthetic placeholder. The returned expectations have the shape of
spec/fixtures/parser-expected.json (`order`, `files`, `mtimes`) plus `discover` (what discovery must find in both
`projects` folders) and `traces` (phase checkpoints after a given physical line of a file). Expected values are written
by hand, independently of reference.py.
"""
import hashlib
import json
import os
import sys
from datetime import datetime, timezone

DAY = "2026-10-21"
CN = "workbuddy/.workbuddy"
INTL = "workbuddy/.workbuddy-ai"
ATLAS = "/Users/dev/projects/atlas"
ORBIT = "C:\\Users\\dev\\projects\\orbit"
ATLAS_SLUG = "Users-dev-projects-atlas"
ORBIT_SLUG = "C-Users-dev-projects-orbit"


def ms(clock, day=DAY):
    """'10:50:05.006' -> Unix ms (UTC)."""
    dt = datetime.strptime("%s %s" % (day, clock), "%Y-%m-%d %H:%M:%S.%f").replace(tzinfo=timezone.utc)
    return int(dt.timestamp() * 1000)


def exact(clock, day=DAY):
    """'11:20:01.500' -> Unix ms (UTC), in integer arithmetic."""
    whole, millis = clock.split(".")
    dt = datetime.strptime("%s %s" % (day, whole), "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
    return int(dt.timestamp()) * 1000 + int(millis)


def escaped(text):
    """A JSON string literal with every character written as a \\u escape."""
    return '"' + "".join("\\u%04x" % ord(c) for c in text) + '"'


def uid(seed):
    """A deterministic UUID-shaped id."""
    h = hashlib.sha256(seed.encode()).hexdigest()
    return "%s-%s-4%s-a%s-%s" % (h[:8], h[8:12], h[13:16], h[17:20], h[20:32])


def mid(seed):
    """A model call's messageId: 32 hex digits, as `withModelMessageCorrelation` makes them."""
    return hashlib.md5(seed.encode()).hexdigest()


def usage(inp, out, cached=0, reasoning=0):
    """agents-core `Usage` JSON as stored in providerData.usage (input includes cached input)."""
    return {"requests": 1, "inputTokens": inp, "outputTokens": out, "totalTokens": inp + out,
            "inputTokensDetails": [{"cached_tokens": cached}], "outputTokensDetails": [{"reasoning_tokens": reasoning}]}


def raw(prompt, completion, cached=None, reasoning=None, **extra):
    """The gateway's OpenAI-style chunk usage as stored in providerData.rawUsage."""
    r = {"prompt_tokens": prompt, "completion_tokens": completion, "total_tokens": prompt + completion}
    if cached is not None:
        r["prompt_tokens_details"] = {"cached_tokens": cached}
    if reasoning is not None:
        r["completion_tokens_details"] = {"reasoning_tokens": reasoning}
    r.update(extra)
    return r


def deepseek_raw(prompt, completion, hit, reasoning=None):
    """DeepSeek reports cache hits and misses; a miss is uncached input, not a cache write."""
    return raw(prompt, completion, reasoning=reasoning, prompt_cache_hit_tokens=hit,
               prompt_cache_miss_tokens=prompt - hit)


class Call:
    """One model call: the providerData every output item of the call shares."""

    def __init__(self, seed, model, request=None, name=None, agent="main", chunk_model=True, step=1):
        self.message_id = mid(seed)
        self.data = {"conversationRequestId": uid("req-" + seed), "messageId": self.message_id, "stepSeq": step}
        if chunk_model:
            self.data["model"] = model
        self.data.update({"requestModelId": request or model, "requestModelName": name or (request or model),
                          "traceId": hashlib.sha1(seed.encode()).hexdigest()[:32], "agent": agent})


class Session:
    """The physical lines of one session file, with the CLI's key order: id, parentId, timestamp, type, role, …"""

    def __init__(self, seed, cwd, session_id=None):
        self.seed, self.cwd, self.session_id = seed, cwd, session_id
        self.lines, self.count, self.last_id = [], 0, None

    def line(self):
        """Physical line number of the last line written (1-based)."""
        return len(self.lines)

    def raw(self, value):
        self.lines.append(value)
        return self.line()

    def item(self, kind, when, role=None, custom=False, cwd=True, **fields):
        """`cwd`: True writes the session's folder, False none, a string that string."""
        self.count += 1
        item_id = uid("%s-%d" % (self.seed, self.count))
        row = {"id": item_id, "parentId": self.last_id, "timestamp": when, "type": kind}
        if role:
            row["role"] = role
        row.update(fields)
        if self.session_id and not custom:
            row["sessionId"] = self.session_id
        if cwd:
            row["cwd"] = self.cwd if cwd is True else cwd
        self.last_id = item_id
        self.lines.append(row)
        return self.line()

    def patch(self, line, **tokens):
        """Writes physical line `line` with JSON text no encoder produces: each string value `"@name"` becomes the raw
        text `tokens[name]` (such as `1e999`, `NaN` or a string with escaped characters)."""
        text = json.dumps(self.lines[line - 1], separators=(",", ":"), ensure_ascii=False)
        for name, raw_text in tokens.items():
            assert '"@%s"' % name in text, name
            text = text.replace('"@%s"' % name, raw_text)
        self.lines[line - 1] = text
        return line

    def copy(self, rows):
        """A fork: the source lines with new ids and remapped parents; timestamp, providerData and cwd are kept and
        the root fork drops `sessionId`."""
        mapping = {}
        for row in rows:
            if not isinstance(row, dict):
                continue
            self.count += 1
            new_id = uid("%s-fork-%d" % (self.seed, self.count))
            mapping[row["id"]] = new_id
            copied = {k: v for k, v in row.items() if k != "sessionId"}
            copied["id"] = new_id
            if "parentId" in copied:
                copied["parentId"] = mapping.get(row.get("parentId"), self.last_id)
            self.last_id = new_id
            self.lines.append(copied)

    def write(self, path, tail=""):
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            for row in self.lines:
                f.write(row if isinstance(row, str) else json.dumps(row, separators=(",", ":"), ensure_ascii=False))
                f.write("\n")
            f.write(tail)

    # ---- line kinds

    def user(self, when, text, agent="main", **extra):
        pd = {"conversationRequestId": uid("ureq-%s-%s" % (self.seed, when)), "agent": agent}
        pd.update(extra)
        return self.item("message", when, "user", content=[{"type": "input_text", "text": text}], providerData=pd)

    def reasoning(self, when, call, text="(reasoning placeholder)", **extra):
        return self.item("reasoning", when, content=[], rawContent=[{"type": "reasoning_text", "text": text}],
                         providerData=dict(call.data, **extra))

    def say(self, when, call, text, use=None, raw_use=None, status="completed", **extra):
        pd = dict(call.data, **extra)
        fields = {"status": status, "content": [{"type": "output_text", "text": text}], "providerData": pd}
        attach(pd, fields, use, raw_use)
        return self.item("message", when, "assistant", **fields)

    def tool_call(self, when, call, call_id, name, arguments, use=None, raw_use=None):
        pd = dict(call.data)
        fields = {"callId": call_id, "name": name, "arguments": json.dumps(arguments, separators=(",", ":")),
                  "status": "completed", "providerData": pd}
        attach(pd, fields, use, raw_use)
        return self.item("function_call", when, **fields)

    def tool_result(self, when, call, call_id, name, text, status="completed", **extra):
        pd = {"toolResult": {"content": text, "renderer": {"type": "text"}}, "messageId": call.message_id,
              "model": call.data.get("model", call.data["requestModelId"]),
              "requestModelId": call.data["requestModelId"]}
        pd.update(extra)
        return self.item("function_call_result", when, name=name, callId=call_id, status=status,
                         output={"type": "text", "text": text}, providerData=pd)

    def notice(self, when, text, status="completed", **pd):
        """A message the CLI writes itself (hooks, interruptions, errors): skipRun, never model output."""
        return self.item("message", when, "assistant", status=status,
                         content=[{"type": "output_text", "text": text}], providerData=dict({"skipRun": True}, **pd))

    def model_usage(self, when, call, use, raw_use):
        pd = {"conversationRequestId": call.data["conversationRequestId"], "messageId": call.message_id,
              "stepSeq": call.data["stepSeq"], "model": call.data.get("model", call.data["requestModelId"]),
              "requestModelId": call.data["requestModelId"], "requestModelName": call.data["requestModelName"],
              "traceId": call.data["traceId"], "agent": call.data["agent"], "rawUsage": raw_use, "usage": use}
        return self.item("model-usage", when, custom=True, providerData=pd)

    def meta(self, when):
        return self.raw({"type": "session-meta", "id": uid("%s-meta-%d" % (self.seed, when)),
                         "sessionId": self.session_id, "timestamp": when,
                         "meta": {"codebuddy.ai/mainAgent": "main", "codebuddy.ai/hostKind": "workbuddy"}})


def attach(pd, fields, use, raw_use):
    """The last output item of a call carries the usage (and usually the raw chunk usage), plus the CLI's own
    `message.usage`, which counts DeepSeek cache misses as cache writes and must not be used."""
    if use is None:
        return
    pd["usage"] = use
    if raw_use is not None:
        pd["rawUsage"] = raw_use
    derived = {"input_tokens": use["inputTokens"], "output_tokens": use["outputTokens"],
               "total_tokens": use["totalTokens"]}
    if raw_use:
        details = raw_use.get("prompt_tokens_details") if isinstance(raw_use.get("prompt_tokens_details"), dict) else {}
        hit = raw_use.get("prompt_cache_hit_tokens", details.get("cached_tokens"))
        write = raw_use.get("cache_creation_input_tokens", raw_use.get("prompt_cache_miss_tokens"))
        if hit:
            derived["cache_read_input_tokens"] = hit
        if write:
            derived["cache_creation_input_tokens"] = write
    fields["message"] = {"usage": derived}


def resp(source_model, key, start, end, inp, cached, write, out, reasoning, provider=None):
    return {"key": key, "startMs": start, "endMs": end, "input": inp, "cachedInput": cached, "cacheWriteInput": write,
            "cacheWrite1hInput": 0, "output": out, "reasoning": reasoning, "model": source_model,
            "provider": provider, "fast": False, "final": True}


def write_fixtures(out_dir):
    def p(rel):
        full = os.path.join(out_dir, *rel.split("/"))
        os.makedirs(os.path.dirname(full), exist_ok=True)
        return full

    files, traces, mtimes = {}, [], {}

    def trace(rel, line, phase, in_flight=None):
        traces.append(dict(file=rel, afterLine=line, phase=phase, inFlightStartMs=in_flight))

    def expect(rel, source, project, model, phase, in_flight, last, responses, parent=None, sub=False, malformed=0):
        files[rel] = dict(source=source, project=project, model=model, isSubagent=sub, parentFile=parent, phase=phase,
                          inFlightStartMs=in_flight, lastLineMs=last, malformedLines=malformed, responses=responses)

    # ==== China edition, project atlas: one long main session -----------------------------------------------------
    a_id = uid("atlas-main")
    a_rel = "%s/projects/%s/%s.jsonl" % (CN, ATLAS_SLUG, a_id)
    a = Session("atlas-main", ATLAS, a_id)

    def glm(seed, **kw):
        return Call(seed, "glm-5.3", name="GLM-5.3", **kw)

    def pro(seed, **kw):
        return Call(seed, "deepseek-v4-pro", name="DeepSeek-V4-Pro", **kw)

    a.meta(ms("09:59:59.990"))                                                                           # 1
    # Turn 1: reasoning, then the answer with usage and raw usage.
    a.user(ms("10:00:00.000"), "(prompt 1)", startsNewUserRequest=True)                                 # 2
    c1 = glm("a1")
    a.reasoning(ms("10:00:03.900"), c1)                                                                  # 3
    a.say(ms("10:00:03.905"), c1, "(answer 1)", usage(12000, 420, 8000, 120),
          raw(12000, 420, cached=8000, reasoning=120))                                                   # 4
    a.item("ai-title", ms("10:00:04.100"), custom=True, aiTitle="(title)")                              # 5
    a.item("credit-usage", ms("10:00:04.200"), custom=True,
           providerData={"conversationRequestId": c1.data["conversationRequestId"], "credit": 1.5,
                         "source": "generation_tool", "stageId": "s1", "messageId": c1.message_id})     # 6
    # Turn 2: text plus two parallel tool calls (usage on the last item), DeepSeek hit/miss counts, a failed tool
    # result that still continues the turn, and a call whose raw usage arrives only in the end-of-run model-usage.
    a.user(ms("10:01:00.000"), "(prompt 2)", startsNewUserRequest=True)                                 # 7
    c2 = pro("a2")
    a.say(ms("10:01:02.500"), c2, "(text before tools)")                                               # 8
    a.tool_call(ms("10:01:02.503"), c2, "call_a1", "Read", {"file_path": "(path)"})                    # 9
    a.tool_call(ms("10:01:02.506"), c2, "call_a2", "Grep", {"pattern": "(pattern)"},
                usage(15000, 260, 0, 200), deepseek_raw(15000, 260, 14000, reasoning=200))           # 10
    a.tool_result(ms("10:01:09.000"), c2, "call_a1", "Read", "(file content)")                        # 11
    a.tool_result(ms("10:01:09.004"), c2, "call_a2", "Grep", "(matches)")                             # 12
    c3 = pro("a3", step=2)
    a.tool_call(ms("10:01:12.300"), c3, "call_a3", "Bash", {"command": "(command)"},
                usage(15800, 90, 0, 0), deepseek_raw(15800, 90, 15000))                               # 13
    a.tool_result(ms("10:01:15.000"), c3, "call_a3", "Bash", '{"isError":true,"error":"(error)"}',
                  status="incomplete")                                                                  # 14
    c4 = pro("a4", step=3)
    a.say(ms("10:01:19.200"), c4, "(answer 2)", usage(16200, 310, 15600, 0))                          # 15
    # Turn 3: a reasoning-only call; its usage is written as model-usage at the end of the run.
    a.user(ms("10:02:00.000"), "(prompt 3)", startsNewUserRequest=True)                                 # 16
    c5 = pro("a5")
    a.reasoning(ms("10:02:05.000"), c5)                                                                  # 17
    a.model_usage(ms("10:02:05.010"), c5, usage(16500, 80, 16000, 80), deepseek_raw(16500, 80, 16000, 80))  # 18
    a.model_usage(ms("10:01:19.198"), c4, usage(16200, 310, 15600, 150),
                  deepseek_raw(16200, 310, 15600, reasoning=150))                                      # 19 earlier ts
    # Turn 4: interrupted mid-stream: a partial draft without usage, then the CLI's notice.
    a.user(ms("10:03:00.000"), "(prompt 4)", startsNewUserRequest=True)                                 # 20
    c6 = glm("a6")
    a.say(ms("10:03:02.000"), c6, "(partial)", status="incomplete", isPartialAborted=True)            # 21
    a.notice(ms("10:03:02.010"), "Interrupted by user", status="incomplete",
             error={"code": "aborted", "message": "(aborted)", "isNetworkError": False})              # 22
    # Turn 5: a network error, the error-recovery reminder, then a retry with a new messageId.
    a.user(ms("10:04:00.000"), "(prompt 5)", startsNewUserRequest=True)                                 # 23
    a.notice(ms("10:04:30.000"), "(network error)", status="incomplete",
             error={"code": "3002", "message": "(error)", "isNetworkError": True, "isRetryable": True})  # 24
    a.user(ms("10:04:30.050"), "(error-recovery reminder)", isMeta=True, startsNewUserRequest=False)  # 25
    c7 = glm("a7")
    a.say(ms("10:04:33.050"), c7, "(answer 5)", usage(17000, 150, 16800, 0), raw(17000, 150, cached=16800))  # 26
    # Turn 6: a sub-agent task; a hook notice while it runs changes nothing.
    a.user(ms("10:05:00.000"), "(prompt 6)", startsNewUserRequest=True)                                 # 27
    c8 = glm("a8")
    a.tool_call(ms("10:05:02.000"), c8, "call_a4", "Task", {"description": "(task)"},
                usage(17300, 70, 17000, 0), raw(17300, 70, cached=17000))                            # 28
    a.notice(ms("10:05:02.010"), "(PreToolUse hook output)", hookEvent="PreToolUse", callId="call_a4",
             hookStatus="success", exitCode=0)                                                         # 29
    sub_name = "agent-%s" % uid("atlas-sub")
    a.tool_result(ms("10:05:40.000"), c8, "call_a4", "Task", "(sub-agent report)",
                  toolResult={"content": "(sub-agent report)", "renderer": {"type": "text"},
                              "subAgent": {"sessionId": sub_name}})                                   # 30
    c9 = glm("a9", step=2)
    a.say(ms("10:05:43.500"), c9, "(answer 6)", usage(17600, 240, 17300, 30), raw(17600, 240, 17300, 30))  # 31
    a.item("summary", ms("10:05:44.000"), custom=True, cwd=False, summary="(summary)",
           providerData={"source": "auto"})                                                            # 32
    # Turn 7: the user rejects a tool call; the CLI writes a skipRun result and the turn ends.
    a.user(ms("10:06:00.000"), "(prompt 7)", startsNewUserRequest=True)                                 # 33
    c10 = glm("a10")
    a.tool_call(ms("10:06:01.500"), c10, "call_a5", "Bash", {"command": "(command)"},
                usage(17900, 40, 17600, 0), raw(17900, 40, cached=17600))                            # 34
    a.tool_result(ms("10:06:20.000"), c10, "call_a5", "Bash", "(rejected)", status="incomplete",
                  skipRun=True, error="(user rejected)")                                               # 35
    # Turn 8: compaction runs before the user's line is written, then the request itself.
    c11 = glm("a11", agent="compact")
    a.user(ms("10:07:00.000"), "(compaction prompt)", agent="compact")                                  # 36
    a.say(ms("10:07:08.000"), c11, "(compacted summary)", usage(60000, 2000), raw(60000, 2000, cached=0))  # 37
    a.user(ms("10:07:08.020"), "(prompt 8)", startsNewUserRequest=True)                                 # 38
    c12 = glm("a12")
    a.say(ms("10:07:11.020"), c12, "(answer 8)", usage(3000, 200, 0, 0), raw(3000, 200, cached=0))   # 39
    a.write(p(a_rel))
    a_responses = [
        resp("glm-5.3", c1.message_id, ms("10:00:00.000"), ms("10:00:03.905"), 12000, 8000, 0, 420, 120),
        resp("deepseek-v4-pro", c2.message_id, ms("10:01:00.000"), ms("10:01:02.506"), 15000, 14000, 0, 260, 200),
        resp("deepseek-v4-pro", c3.message_id, ms("10:01:09.004"), ms("10:01:12.300"), 15800, 15000, 0, 90, 0),
        resp("deepseek-v4-pro", c4.message_id, ms("10:01:15.000"), ms("10:01:19.200"), 16200, 15600, 0, 310, 150),
        resp("deepseek-v4-pro", c5.message_id, ms("10:02:00.000"), ms("10:02:05.010"), 16500, 16000, 0, 80, 80),
        resp("glm-5.3", c7.message_id, ms("10:04:30.050"), ms("10:04:33.050"), 17000, 16800, 0, 150, 0),
        resp("glm-5.3", c8.message_id, ms("10:05:00.000"), ms("10:05:02.000"), 17300, 17000, 0, 70, 0),
        resp("glm-5.3", c9.message_id, ms("10:05:40.000"), ms("10:05:43.500"), 17600, 17300, 0, 240, 30),
        resp("glm-5.3", c10.message_id, ms("10:06:00.000"), ms("10:06:01.500"), 17900, 17600, 0, 40, 0),
        resp("glm-5.3", c11.message_id, ms("10:07:00.000"), ms("10:07:08.000"), 60000, 0, 0, 2000, 0),
        resp("glm-5.3", c12.message_id, ms("10:07:08.020"), ms("10:07:11.020"), 3000, 0, 0, 200, 0),
    ]
    expect(a_rel, "workbuddy", "atlas", "glm-5.3", "idle", None, ms("10:07:11.020"), a_responses)
    for line, phase, in_flight in (
            (1, "idle", None), (2, "generating", ms("10:00:00.000")), (3, "generating", ms("10:00:00.000")),
            (4, "idle", None), (6, "idle", None), (7, "generating", ms("10:01:00.000")), (8, "idle", None),
            (9, "tools", None), (10, "tools", None), (11, "tools", None), (12, "generating", ms("10:01:09.004")),
            (13, "tools", None), (14, "generating", ms("10:01:15.000")), (15, "idle", None),
            (16, "generating", ms("10:02:00.000")), (17, "generating", ms("10:02:00.000")), (18, "idle", None),
            (19, "idle", None), (20, "generating", ms("10:03:00.000")), (21, "generating", ms("10:03:00.000")),
            (22, "idle", None), (23, "generating", ms("10:04:00.000")), (24, "idle", None),
            (25, "generating", ms("10:04:30.050")), (26, "idle", None), (27, "generating", ms("10:05:00.000")),
            (28, "tools", None), (29, "tools", None), (30, "generating", ms("10:05:40.000")), (31, "idle", None),
            (32, "idle", None), (33, "generating", ms("10:06:00.000")), (34, "tools", None), (35, "idle", None),
            (36, "generating", ms("10:07:00.000")), (37, "generating", ms("10:07:08.000")),
            (38, "generating", ms("10:07:08.020")), (39, "idle", None)):
        trace(a_rel, line, phase, in_flight)
    mtimes[a_rel] = ms("10:07:12.000")

    # ---- Its sub-agent (stored flat under the main session), with a legacy .meta.json that is not a transcript.
    sub_rel = "%s/projects/%s/%s/subagents/%s.jsonl" % (CN, ATLAS_SLUG, a_id, sub_name)
    s = Session("atlas-sub", ATLAS, uid("atlas-sub-runtime"))

    def flash(seed, **kw):
        return Call(seed, "glm-5.3-flash", name="GLM-5.3-Flash", agent="code-explorer", **kw)

    s.user(ms("10:05:02.100"), "(task prompt)", agent="code-explorer")                                  # 1
    s1 = flash("s1")
    s.tool_call(ms("10:05:05.000"), s1, "call_s1", "Glob", {"pattern": "(glob)"},
                usage(4000, 60, 0, 0), raw(4000, 60, cached=0))                                       # 2
    s.tool_result(ms("10:05:06.000"), s1, "call_s1", "Glob", "(files)")                               # 3
    s2 = flash("s2", step=2)
    s.reasoning(ms("10:05:09.000"), s2)                                                                  # 4
    s.say(ms("10:05:09.004"), s2, "(report)", usage(4300, 500, 4000, 90), raw(4300, 500, 4000, 90))  # 5
    s.write(p(sub_rel))
    with open(p(sub_rel[:-len(".jsonl")] + ".meta.json"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write('{"agentType":"code-explorer","parentSessionId":"%s"}\n' % a_id)
    expect(sub_rel, "workbuddy", "atlas", "glm-5.3-flash", "idle", None, ms("10:05:09.004"), [
        resp("glm-5.3-flash", s1.message_id, ms("10:05:02.100"), ms("10:05:05.000"), 4000, 0, 0, 60, 0),
        resp("glm-5.3-flash", s2.message_id, ms("10:05:06.000"), ms("10:05:09.004"), 4300, 4000, 0, 500, 90),
    ], parent=a_rel, sub=True)
    mtimes[sub_rel] = ms("10:05:10.000")

    # ---- A second session in the same folder at the same time: routing alias and suffixed ids; ends in flight.
    b_id = uid("atlas-second")
    b_rel = "%s/projects/%s/%s.jsonl" % (CN, ATLAS_SLUG, b_id)
    b = Session("atlas-second", ATLAS, b_id)
    b.user(ms("10:01:05.000"), "(prompt)", startsNewUserRequest=True)                                   # 1
    b1 = Call("b1", "auto", name="Auto", chunk_model=False)
    b.say(ms("10:01:08.000"), b1, "(answer)", usage(5000, 120, 0, 0), raw(5000, 120))                # 2 no model
    b.user(ms("10:01:20.000"), "(prompt)", startsNewUserRequest=True)                                   # 3
    b2 = Call("b2", "minimax-m3-pay", name="MiniMax-M3")
    b.say(ms("10:01:24.000"), b2, "(answer)", usage(5400, 300, 5000, 0), raw(5400, 300, cached=5000))  # 4
    b.user(ms("10:01:26.000"), "(prompt)", startsNewUserRequest=True)                                   # 5
    b3 = Call("b3", "deepseek-v3-2-volc", name="DeepSeek-V3.2")
    b.say(ms("10:01:28.000"), b3, "(answer)", usage(5800, 90, 5300, 0), deepseek_raw(5800, 90, 5300))  # 6
    b.raw('{"id":"%s","timestamp":"not-a-number","type":"message","role":"user"}' % uid("b-bad"))   # 7 no ts
    b.raw("{not json")                                                                                   # 8 malformed
    b.user(ms("10:01:30.000"), "(prompt)", startsNewUserRequest=True)                                   # 9
    b.write(p(b_rel))
    expect(b_rel, "workbuddy", "atlas", "deepseek-v3-2-volc", "generating", ms("10:01:30.000"), ms("10:01:30.000"), [
        resp("auto", b1.message_id, ms("10:01:05.000"), ms("10:01:08.000"), 5000, 0, 0, 120, 0),
        resp("minimax-m3-pay", b2.message_id, ms("10:01:20.000"), ms("10:01:24.000"), 5400, 5000, 0, 300, 0),
        resp("deepseek-v3-2-volc", b3.message_id, ms("10:01:26.000"), ms("10:01:28.000"), 5800, 5300, 0, 90, 0),
    ], malformed=1)
    trace(b_rel, 7, "idle")
    trace(b_rel, 8, "idle")
    trace(b_rel, 9, "generating", ms("10:01:30.000"))
    mtimes[b_rel] = ms("10:01:31.000")

    # ---- A fork of the main session: copied lines keep timestamps and messageIds (owned by the original), the
    # fork's session-meta follows the copy, then one new turn, then a line cut off by a write in progress.
    f_id = uid("atlas-fork")
    f_rel = "%s/projects/%s/%s.jsonl" % (CN, ATLAS_SLUG, f_id)
    f = Session("atlas-fork", ATLAS, f_id)
    f.copy(a.lines[1:19])                                                                                # 1-18
    copied = f.line()
    f.session_id = f_id
    f.meta(ms("10:20:00.000"))                                                                           # 19
    f.raw('{"id":"%s","parentId":null,"timestamp":17920' % uid("fork-torn"))                            # 20 torn
    f.user(ms("10:20:01.000"), "(prompt after fork)", startsNewUserRequest=True)                        # 21
    fc = glm("f1")
    f.say(ms("10:20:04.000"), fc, "(answer)", usage(9000, 180, 8800, 0), raw(9000, 180, cached=8800))  # 22
    f.write(p(f_rel), tail='{"id":"%s","parentId":null,"timestamp":%d,"type":"message","role":"user","con'
            % (uid("fork-partial"), ms("10:20:30.000")))
    expect(f_rel, "workbuddy", "atlas", "glm-5.3", "idle", None, ms("10:20:04.000"), [
        resp("glm-5.3", fc.message_id, ms("10:20:01.000"), ms("10:20:04.000"), 9000, 8800, 0, 180, 0),
    ], malformed=1)
    trace(f_rel, 9, "generating", ms("10:01:00.000"))
    trace(f_rel, copied, "generating", ms("10:02:00.000"))
    trace(f_rel, 21, "generating", ms("10:20:01.000"))
    trace(f_rel, 22, "idle")
    mtimes[f_rel] = ms("10:20:31.000")

    # ==== International edition, project orbit on Windows ------------------------------------------------------------
    d_id = uid("orbit-main")
    d_rel = "%s/projects/%s/%s.jsonl" % (INTL, ORBIT_SLUG, d_id)
    d = Session("orbit-main", ORBIT, d_id)
    d.user(ms("11:00:00.000"), "(prompt)", startsNewUserRequest=True)                                   # 1
    d1 = Call("d1", "gpt-5.5", request="default-model", name="Default")
    d.say(ms("11:00:04.000"), d1, "(answer)", usage(9000, 300, 0, 40), raw(9000, 300, 0, 40))         # 2 resolved
    d.user(ms("11:01:00.000"), "(prompt)", startsNewUserRequest=True)                                   # 3
    d2 = Call("d2", "deepseek-v4.1-flash-sg", name="DeepSeek-V4.1-Flash")
    d.tool_call(ms("11:01:03.000"), d2, "call_d1", "WebFetch", {"url": "(url)"},
                usage(9400, 50, 0, 0), deepseek_raw(9400, 50, 9000))                                  # 4
    d.tool_result(ms("11:01:05.000"), d2, "call_d1", "WebFetch", "(page)")                            # 5
    d3 = Call("d3", "deepseek-v4.1-flash-sg", name="DeepSeek-V4.1-Flash", step=2)
    d.say(ms("11:01:09.000"), d3, "(answer)", usage(12000, 400, 9400, 0), deepseek_raw(12000, 400, 9400))  # 6
    d.user(ms("11:02:00.000"), "(prompt)", startsNewUserRequest=True)                                   # 7
    d4 = Call("d4", "custom-local:claude-sonnet-5-5", name="claude-sonnet-5-5")
    d.say(ms("11:02:06.000"), d4, "(answer)", usage(20000, 500, 15000, 0),
          raw(20000, 500, cached=15000, cache_read_input_tokens=15000, cache_creation_input_tokens=4000))  # 8
    d.user(ms("11:03:00.000"), "(prompt)", startsNewUserRequest=True)                                   # 9
    d5 = Call("d5", "custom:gpt-5.5", name="gpt-5.5")
    d.say(ms("11:03:02.000"), d5, "(answer)", usage(800, 60, 0, 0))                                   # 10 no raw
    d.write(p(d_rel))
    expect(d_rel, "workbuddyAi", "orbit", "gpt-5.5", "idle", None, ms("11:03:02.000"), [
        resp("gpt-5.5", d1.message_id, ms("11:00:00.000"), ms("11:00:04.000"), 9000, 0, 0, 300, 40),
        resp("deepseek-v4.1-flash-sg", d2.message_id, ms("11:01:00.000"), ms("11:01:03.000"), 9400, 9000, 0, 50, 0),
        resp("deepseek-v4.1-flash-sg", d3.message_id, ms("11:01:05.000"), ms("11:01:09.000"), 12000, 9400, 0, 400, 0),
        resp("claude-sonnet-5-5", d4.message_id, ms("11:02:00.000"), ms("11:02:06.000"), 20000, 15000, 4000, 500, 0,
             provider="custom"),
        resp("gpt-5.5", d5.message_id, ms("11:03:00.000"), ms("11:03:02.000"), 800, 0, 0, 60, 0, provider="custom"),
    ])
    trace(d_rel, 4, "tools")
    trace(d_rel, 5, "generating", ms("11:01:05.000"))
    trace(d_rel, 6, "idle")
    mtimes[d_rel] = ms("11:03:03.000")

    # ---- A concurrent session in the same folder: Hunyuan, then a request still in flight.
    e_id = uid("orbit-second")
    e_rel = "%s/projects/%s/%s.jsonl" % (INTL, ORBIT_SLUG, e_id)
    e = Session("orbit-second", ORBIT, e_id)
    e.user(ms("11:01:02.000"), "(prompt)", startsNewUserRequest=True)                                   # 1
    e1 = Call("e1", "hy4-preview", name="Hy4 preview")
    e.say(ms("11:01:06.000"), e1, "(answer)", usage(7000, 260, 6000, 100), raw(7000, 260, 6000, 100))  # 2
    e.user(ms("11:05:00.000"), "(prompt)", startsNewUserRequest=True)                                   # 3
    e.write(p(e_rel))
    expect(e_rel, "workbuddyAi", "orbit", "hy4-preview", "generating", ms("11:05:00.000"), ms("11:05:00.000"), [
        resp("hy4-preview", e1.message_id, ms("11:01:02.000"), ms("11:01:06.000"), 7000, 6000, 0, 260, 100),
    ])
    mtimes[e_rel] = ms("11:05:01.000")

    # ---- Timestamps (METRICS 3.1, 3.6): user lines whose timestamp is valid move the in-flight start; the others are
    # ignored entirely. Every value is computed here by hand, in integer arithmetic.
    year1 = int(datetime(1, 1, 1, tzinfo=timezone.utc).timestamp()) * 1000
    year0 = year1 - 366 * 86_400_000  # 0000 is a leap year in the proleptic Gregorian calendar
    last_second = int(datetime(9999, 12, 31, 23, 59, 59, tzinfo=timezone.utc).timestamp()) * 1000
    off = (23 * 3600 + 59 * 60) * 1000
    int64_max = 2 ** 63 - 1
    t_id = uid("orbit-timestamps")
    t_rel = "%s/projects/%s/%s.jsonl" % (INTL, ORBIT_SLUG, t_id)
    t = Session("orbit-timestamps", ORBIT, t_id)
    current = None
    for stamp, value in (
            (exact("11:20:00.000"), exact("11:20:00.000")),
            ("2026-10-21t11:20:01.5z", exact("11:20:01.500")),                        # lower-case separator, zone
            ("2026-10-21 19:20:02+08:00", exact("11:20:02.000")),                     # space, offset
            ("2026-10-21T06:20:03.123456789-0500", exact("11:20:03.123")),            # offset without colon
            ("2026-10-21T11:20:04." + "0" * 43 + "Z", exact("11:20:04.000")),         # 64 characters
            ("@esc:2026-10-21T11:20:05." + "0" * 43 + "Z", exact("11:20:05.000")),    # 64, every character escaped
            ("2026-10-21T11:20:06", None),                                            # no zone
            (" 2026-10-21T11:20:07Z", None),
            ("2026-10-21T11:20:08Z ", None),
            ("2026-10-21T11:20:60Z", None),                                           # leap second
            ("2026-10-21T11:20:09+08", None),                                         # offset without minutes
            ("2026-10-21T11:20:10+24:00", None),
            ("2026-10-21T11:20:11+05:60", None),
            ("2026-10-21T24:00:00Z", None),
            ("2026-02-29T11:20:12Z", None),                                           # 2026 is no leap year
            ("２０２６-10-21T11:20:13Z", None),                       # full-width digits
            ("2026-10-21T11:20:14." + "0" * 44 + "Z", None),                          # 65 characters
            ("2026-10-21T11:20:15.Z", None),
            ("2026-10-21T11:20:16,5Z", None),
            ("@esc:2026-10-21T11:20:17." + "0" * 44 + "Z", None),                     # 65, escaped
            ("@raw:1e999", None),                                                     # not finite
            ("@raw:1" + "0" * 400, None),                                             # beyond the double range
            (-5, None), (0, None), (True, None),
            ("0000-01-01T00:00:00Z", year0),
            ("0000-02-29T23:59:59.999+23:59", year0 + 59 * 86_400_000 + 86_399_999 - off),
            ("0001-01-01T00:00:00+23:59", year1 - off),
            (0.5, 0),                                                                 # finite, > 0, truncates to 0
            ("9999-12-31T23:59:59.999-23:59", last_second + 999 + off),
            ("@raw:1e19", int64_max),                                                 # saturates
            (exact("11:20:30.000"), exact("11:20:30.000"))):
        kind, _, text = stamp.partition(":") if isinstance(stamp, str) and stamp[:5] in ("@esc:", "@raw:") \
            else (None, None, None)
        line = t.user("@ts" if kind else stamp, "(prompt)", startsNewUserRequest=True)
        if kind == "@esc":
            t.patch(line, ts=escaped(text))
        elif kind == "@raw":
            t.patch(line, ts=text)
        current = value if value is not None else current
        trace(t_rel, line, "generating", current)
    t.write(p(t_rel))
    expect(t_rel, "workbuddyAi", "orbit", None, "generating", exact("11:20:30.000"), int64_max, [])
    mtimes[t_rel] = ms("11:20:31.000")

    # ---- Edge values (METRICS 3.2, 3.6, 4.9): huge and odd numbers, blank and prefixed models, lines without a key,
    # a callId that is not a string, NaN and Infinity, blank working directories, and calls outside the calendar range.
    cap = 10 ** 12
    x_id = uid("orbit-edge")
    x_rel = "%s/projects/%s/%s.jsonl" % (INTL, ORBIT_SLUG, x_id)
    x = Session("orbit-edge", ORBIT, x_id)
    x.user(exact("11:30:00.000"), "(prompt)", startsNewUserRequest=True)                               # 1
    x1 = Call("x1", " \t ", request="glm-5.3", name="GLM-5.3")                                         # blank model
    x.patch(x.say(exact("11:30:02.000"), x1, "(answer)",
                  {"requests": 1, "inputTokens": "@inf", "outputTokens": 300.9, "totalTokens": 1,
                   "inputTokensDetails": {"cached_tokens": 200}, "outputTokensDetails": {"reasoning_tokens": 40.7}},
                  {"prompt_tokens": -5, "completion_tokens": "999", "cache_read_input_tokens": 0.5,
                   "prompt_tokens_details": {"cached_tokens": 900}, "prompt_cache_hit_tokens": 800,
                   "cache_creation_input_tokens": "@inf", "prompt_cache_write_tokens": 70.2}), inf="1e999")  # 2
    trace(x_rel, x.line(), "idle")
    x.user(exact("11:31:00.000"), "(prompt)", startsNewUserRequest=True)                               # 3
    x2 = Call("x2", "CUSTOM-LOCAL:  ", request="kimi-k3", name="Kimi-K3")                              # empty name
    x.patch(x.tool_call(exact("11:31:03.000"), x2, "call_x1", "Read", {"file_path": "(path)"},
                        {"requests": 1, "inputTokens": "@big", "outputTokens": 1e20, "totalTokens": 0,
                         "inputTokensDetails": [{"cached_tokens": 300}, "(text)", 5, {"cached_tokens": 400}],
                         "outputTokensDetails": [{"reasoning_tokens": 600_000_000_000},
                                                 {"reasoning_tokens": 600_000_000_000}]},
                        {"prompt_tokens": 5, "completion_tokens": 6, "cache_read_input_tokens": "@big",
                         "prompt_tokens_details": "(text)", "prompt_cache_hit_tokens": 12.7,
                         "cache_creation_input_tokens": True, "prompt_cache_write_tokens": 0}),
            big="1" + "0" * 400)                                                                         # 4
    trace(x_rel, x.line(), "tools")
    x.tool_result(exact("11:31:05.000"), x2, {"id": "call_x1"}, "Read", "(content)")                  # 5 object
    trace(x_rel, x.line(), "tools")
    x.tool_result(exact("11:31:05.500"), x2, ["call_x1"], "Read", "(content)")                        # 6 array
    trace(x_rel, x.line(), "tools")
    x.tool_result(exact("11:31:06.000"), x2, "call_x1", "Read", "(content)")                          # 7
    trace(x_rel, x.line(), "generating", exact("11:31:06.000"))
    x.item("function_call", exact("11:31:06.500"), callId="call_x9", name="Bash", arguments="{}",
           status="completed", providerData={"messageId": "", "model": "glm-5.3", "usage": usage(10, 5)})
    x.lines[-1]["id"] = ""                                                                              # 8 no key
    trace(x_rel, x.line(), "generating", exact("11:31:06.000"))
    x.item("model-usage", exact("11:31:07.000"), custom=True,
           providerData={"model": "glm-5.3", "usage": usage(10, 5), "rawUsage": raw(10, 5)})
    x.lines[-1]["id"] = 5                                                                               # 9 no key
    trace(x_rel, x.line(), "generating", exact("11:31:06.000"))
    x3 = Call("x3", "Custom:Kimi-K3 ", name="Kimi-K3")
    x.say(exact("11:31:09.000"), x3, "(answer)", dict(usage(1000, 50), outputTokensDetails=7), raw(1000, 50))  # 10
    trace(x_rel, x.line(), "idle")
    x.patch(x.model_usage(exact("11:31:10.000"), x3, dict(usage(1000, 50), outputTokens="@nan"), raw(1000, 50)),
            nan="NaN")                                                                                   # 11 malformed
    x.patch(x.user("@ts", "(prompt)"), ts="Infinity")                                                  # 12 malformed
    trace(x_rel, x.line(), "idle")
    x.user(exact("11:32:00.000"), "(prompt)", startsNewUserRequest=True)                               # 13
    x.lines[-1]["cwd"] = "\u001f"                                                                       # blank
    trace(x_rel, x.line(), "generating", exact("11:32:00.000"))
    x4 = Call("x4", "\u001f", request="hy4-preview", name="Hy4 preview")                               # blank model
    x.say(exact("11:32:04.000"), x4, "(answer)", usage(2000, 80, 1500, 10), raw(2000, 80, 1500, 10))  # 14
    x.lines[-1]["cwd"] = "　\u001c"
    trace(x_rel, x.line(), "idle")
    x.user("0000-01-01T00:00:00Z", "(prompt)", startsNewUserRequest=True)                              # 15
    trace(x_rel, x.line(), "generating", year0)
    x5 = Call("x5", "glm-5.3", name="GLM-5.3")
    x.say("0000-01-01T00:00:01Z", x5, "(answer)", usage(100, 10), raw(100, 10))                       # 16
    trace(x_rel, x.line(), "idle")
    x.user("9999-12-31T23:59:58-23:59", "(prompt)", startsNewUserRequest=True)                         # 17
    trace(x_rel, x.line(), "generating", last_second - 1000 + off)
    x6 = Call("x6", "glm-5.3", name="GLM-5.3")
    x.say("9999-12-31T23:59:59.999-23:59", x6, "(answer)", usage(100, 10), raw(100, 10))              # 18
    trace(x_rel, x.line(), "idle")
    x.user(exact("11:33:00.000"), "(prompt)", startsNewUserRequest=True)                               # 19
    x.lines[-1]["cwd"] = "\u001d "
    trace(x_rel, x.line(), "generating", exact("11:33:00.000"))
    for line in range(15, 19):
        x.lines[line - 1].pop("cwd")
    x.write(p(x_rel))
    expect(x_rel, "workbuddyAi", "orbit", "glm-5.3", "generating", exact("11:33:00.000"), last_second + 999 + off, [
        resp("glm-5.3", x1.message_id, exact("11:30:00.000"), exact("11:30:02.000"), cap, 200, 70, 300, 40),
        resp(None, x2.message_id, exact("11:31:00.000"), exact("11:31:03.000"), cap, 700, 0, cap, cap,
             provider="custom"),
        resp("Kimi-K3", x3.message_id, exact("11:31:06.000"), exact("11:31:09.000"), 1000, 0, 0, 50, 0,
             provider="custom"),
        resp("hy4-preview", x4.message_id, exact("11:32:00.000"), exact("11:32:04.000"), 2000, 1500, 0, 80, 10),
        resp("glm-5.3", x5.message_id, year0, year0 + 1000, 100, 0, 0, 10, 0),
        resp("glm-5.3", x6.message_id, last_second - 1000 + off, last_second + 999 + off, 100, 0, 0, 10, 0),
    ], malformed=2)
    mtimes[x_rel] = ms("11:33:01.000")

    # ==== Discovery decoys: none of these is a session transcript --------------------------------------------------
    usage_line = json.dumps(a.lines[3], separators=(",", ":")) + "\n"
    cloud_id = uid("cloud-conversation")
    decoys = {
        "%s/projects/cloud/user-%s/%s.jsonl" % (CN, cloud_id, cloud_id): usage_line,
        "%s/projects/cloud/%s.jsonl" % (CN, cloud_id): usage_line,
        "%s/projects/%s/%s.meta.json" % (CN, ATLAS_SLUG, a_id): '{"title":"(title)"}\n',
        "%s/projects/%s/%s/tool-results/call_a1.jsonl" % (CN, ATLAS_SLUG, a_id): usage_line,
        "%s/projects/%s/%s/subagents/workflows/wf_1/journal.jsonl" % (CN, ATLAS_SLUG, a_id): usage_line,
        "%s/projects/%s/.%s.jsonl" % (CN, ATLAS_SLUG, uid("hidden")): usage_line,
        "%s/projects/%s/notes.txt" % (CN, ATLAS_SLUG): "(notes)\n",
        "%s/projects/stray.jsonl" % CN: usage_line,
        "%s/traces/4242/%s.jsonl" % (CN, uid("trace")): usage_line,
        "%s/sessions/4242.json" % CN: '{"pid":4242}\n',
        "%s/models.json" % CN: '{"models":[]}\n',
        "%s/settings.json" % CN: "{}\n",
        "%s/workbuddy.db" % CN: "",
        "%s/logs/main.log" % CN: "(log)\n",
        "%s/projects/%s/%s/subagents/nested/agent-deep.jsonl" % (INTL, ORBIT_SLUG, d_id): usage_line,
        "%s/app/Local Storage/leveldb/LOG" % INTL: "(log)\n",
        "workbuddy/.codebuddy/projects/%s/%s.jsonl" % (ATLAS_SLUG, uid("codebuddy")): usage_line,
    }
    for rel, content in decoys.items():
        with open(p(rel), "w", encoding="utf-8", newline="\n") as fh:
            fh.write(content)

    order = sorted(mtimes, key=lambda rel: (mtimes[rel], rel))
    for rel in order:
        os.utime(p(rel), (mtimes[rel] / 1000, mtimes[rel] / 1000))
    return {
        "_comment": "WorkBuddy: the folder `workbuddy` plays the home folder, so the automatic roots are "
                    "workbuddy/.workbuddy/projects (source workbuddy) and workbuddy/.workbuddy-ai/projects (source "
                    "workbuddyAi); `discover` lists what discovery finds in both. The fork copies 18 lines of the "
                    "main session with their original timestamps and messageIds, so every copied response is owned "
                    "by the main session. Line 19 of the main session is an end-of-run model-usage line for an "
                    "earlier call (an earlier timestamp): it merges into that call's response.",
        "order": order,
        "mtimes": mtimes,
        "discover": sorted(files),
        "files": {rel: files[rel] for rel in order},
        "traces": traces,
    }


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip())
        sys.exit(2)
    print(json.dumps(write_fixtures(sys.argv[1]), indent=2))


if __name__ == "__main__":
    main()
