#!/usr/bin/env python3
"""Independent reference implementation of spec/METRICS.md, used to cross-check the Swift and C# cores.

  python3 spec/tools/reference.py --check-fixtures
  python3 spec/tools/reference.py --dump-today [--codex PATH] [--claude PATH] [--dsh PATH] [--gemini PATH]
                                              [--omp PATH] [--antigravity PATH] [--workbuddy PATH]
                                              [--workbuddy-ai PATH]
  python3 spec/tools/reference.py --dump-history [--utc] [--prices PATH] [...]
  python3 spec/tools/reference.py --write-history-fixture

The dump format matches the `--dump-today` output of both platform probes. Conversation content is never printed.
Costs (METRICS 9) use spec/assets/prices.json unless --prices names another table; prices.py does the pricing.
"""
import argparse
import math
import sqlite3
import subprocess
import json
import os
import re
import shutil
import sys
import tempfile
import time
from collections import OrderedDict
from datetime import datetime, timezone
from urllib.parse import unquote

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import prices as pricing  # noqa: E402
import harness_reference as harnesses  # noqa: E402

if hasattr(sys, "set_int_max_str_digits"):
    sys.set_int_max_str_digits(0)  # integer literals of any length are numbers (METRICS 3.6), not malformed lines

MAX_LINE = 32 * 1024 * 1024
DEDUPE_LIMIT = 65_536
WINDOW_MS = 3000
TS_MAX_CHARS = 64
TS_RE = re.compile(r"([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt ]([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]+))?"
                   r"(?:[Zz]|([+-])([0-9]{2}):?([0-9]{2}))")
INT64_MIN, INT64_MAX = -2 ** 63, 2 ** 63 - 1
TOKEN_CAP = 10 ** 12
DAY_FIRST_MS = -62_135_596_800_000 + 2 * 86_400_000  # 0001-01-03T00:00:00Z
DAY_LAST_MS = 253_402_300_799_999 - 2 * 86_400_000  # 9999-12-29T23:59:59.999Z
TOKEN_FIELDS = ("input", "cachedInput", "cacheWriteInput", "cacheWrite1hInput", "output", "reasoning")
GEMINI_LEGACY_MAX = 64 * 1024 * 1024
GEMINI_SANITIZE = re.compile(r"[^A-Za-z0-9_-]")
GEMINI_CANCELLED = "Request cancelled."
OMP_COPY_MS = 2000
AG_BLOB_MAX = 1024 * 1024
AG_TOKEN_MAX = 10_000_000
AG_OPEN = {1, 2, 8, 9, 11}
AG_FAILED = {6, 7, 12}
AG_NAME = re.compile(r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.db$")


def days_from_civil(y, m, d):
    """Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's algorithm), for any year."""
    y = y - 1 if m <= 2 else y
    era = y // 400
    yoe = y - era * 400
    doy = (153 * (m + (-3 if m > 2 else 9)) + 2) // 5 + d - 1
    return era * 146_097 + yoe * 365 + yoe // 4 - yoe // 100 + doy - 719_468


def days_in_month(y, m):
    if m == 2:
        return 29 if y % 4 == 0 and (y % 100 != 0 or y % 400 == 0) else 28
    return 30 if m in (4, 6, 9, 11) else 31


def parse_ts(value):
    """A timestamp string of METRICS 3.1 -> Unix ms; None when the string does not follow it exactly."""
    if not isinstance(value, str) or len(value) > TS_MAX_CHARS:
        return None
    m = TS_RE.fullmatch(value)
    if not m:
        return None
    y, mo, d, h, mi, s = (int(g) for g in m.groups()[:6])
    frac, sign, oh, om = m.groups()[6:]
    if not (1 <= mo <= 12 and 1 <= d <= days_in_month(y, mo) and h <= 23 and mi <= 59 and s <= 59):
        return None
    offset = 0
    if sign:
        if int(oh) > 23 or int(om) > 59:
            return None
        offset = (int(oh) * 3600 + int(om) * 60) * (1 if sign == "+" else -1)
    seconds = days_from_civil(y, mo, d) * 86_400 + h * 3600 + mi * 60 + s - offset
    return seconds * 1000 + int((frac or "0")[:3].ljust(3, "0"))


def finite(value):
    """A JSON number whose nearest double is finite (METRICS 3.6): 1e999 and integers past ~1.8e308 are not."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    if isinstance(value, int):
        try:
            float(value)
        except OverflowError:
            return False
        return True
    return math.isfinite(value)


def trunc64(value):
    """A finite number truncated toward zero and saturated to the signed 64-bit range (METRICS 3.6)."""
    return min(max(int(value), INT64_MIN), INT64_MAX)


def num(value):
    """A token value (METRICS 3.2): a number truncated toward zero and clamped to 0…10^12; anything else is 0."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return 0
    if isinstance(value, float) and not math.isfinite(value):
        return TOKEN_CAP if value > 0 else 0
    return min(max(0, int(value)), TOKEN_CAP)


def cap(value):
    """A normalized token field that is a sum saturates at 10^12 (METRICS 3.2)."""
    return min(value, TOKEN_CAP)


def has_day(ms):
    """Whether an instant has a calendar date in every time zone (METRICS 8)."""
    return DAY_FIRST_MS <= ms <= DAY_LAST_MS


def not_json(constant):
    raise ValueError("%s is not JSON" % constant)


def loads(raw):
    """json.loads without NaN / Infinity / -Infinity, which are not JSON: such a line is malformed (METRICS 3.6)."""
    return json.loads(raw, parse_constant=not_json)


def basename(path):
    if not isinstance(path, str) or not path:
        return None
    parts = [p for p in re.split(r"[\\/]", path) if p]
    return parts[-1] if parts else None


class Deduper:
    def __init__(self, limit=DEDUPE_LIMIT):
        self.owners = OrderedDict()
        self.limit = limit

    def owner(self, key):
        return self.owners.get(key)

    def claim(self, key, owner):
        self.owners[key] = owner
        while len(self.owners) > self.limit:
            self.owners.popitem(last=False)


class FileState:
    def __init__(self, path, source, root=None):
        self.path = path
        self.source = source
        self.source_decided = False
        self.project = None
        self.model = None
        self.is_subagent = source == "claudeCode" and "subagents" in [p for p in re.split(r"[\\/]", path) if p]
        self.phase = "idle"
        self.in_flight = None
        self.last_line = None
        self.pending = None
        self.malformed = 0
        self.responses = OrderedDict()
        # codex
        self.file_created = None
        self.provider = None
        self.my_agent_path = "/root"
        self.thread_id = None
        self.parent_thread_id = None
        self.streaming = False
        self.saw_modern = False
        self.prev_legacy = None
        # claude
        self.precise = False
        # deepseek, gemini
        self.parent_session = None
        # gemini
        self.marker = None
        self.seen_calls = set()
        if source == "gemini":
            parts = [p for p in re.split(r"[\\/]", path) if p]
            nested = len(parts) >= 3 and parts[-3] == "chats"
            self.source_decided = True
            self.is_subagent = nested
            self.parent_session = parts[-2] if nested else None
            self.project = gemini_project(path)
        # omp
        self.header_seen = False
        self.pending_calls = set()
        if source == "omp":
            self.source_decided = True
            rel = os.path.relpath(path, root) if root else path
            self.is_subagent = len([p for p in re.split(r"[\\/]", rel) if p]) >= 3
        # workbuddy
        self.cwd = None
        self.open_calls = OrderedDict()
        if source in WB_FOLDERS:
            self.source_decided = True
            rel = [p for p in re.split(r"[\\/]", os.path.relpath(path, root) if root else path) if p]
            self.is_subagent = len(rel) == 4 and rel[2] == "subagents"


def emit(state, key, start, end, tokens, model, final=True, provider=None, fast=False):
    tokens.setdefault("cacheWrite1hInput", 0)
    state.responses[key] = dict(key=key, startMs=start, endMs=end, model=model, provider=provider, fast=fast,
                                final=final, **tokens)


def codex_tokens(usage):
    usage = usage if isinstance(usage, dict) else {}
    return dict(input=num(usage.get("input_tokens")), cachedInput=num(usage.get("cached_input_tokens")),
                cacheWriteInput=num(usage.get("cache_write_input_tokens")), output=num(usage.get("output_tokens")),
                reasoning=num(usage.get("reasoning_output_tokens")))


def codex_line(state, obj, dedupe):
    ts = parse_ts(obj.get("timestamp"))
    if ts is None:
        return
    kind = obj.get("type")
    payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else {}
    if kind == "session_meta":
        if state.file_created is not None:
            return
        state.file_created = ts
        state.last_line = ts if state.last_line is None else max(state.last_line, ts)
        state.project = basename(payload.get("cwd")) or state.project
        state.my_agent_path = payload.get("agent_path") or "/root"
        state.provider = payload.get("model_provider") if isinstance(payload.get("model_provider"), str) else None
        source = payload.get("source")
        state.is_subagent = state.is_subagent or payload.get("thread_source") == "subagent" or (
            isinstance(source, dict) and "subagent" in source)
        state.thread_id = payload.get("id") or state.thread_id
        subagent = source.get("subagent") if isinstance(source, dict) else None
        spawn = subagent.get("thread_spawn") if isinstance(subagent, dict) else None
        state.parent_thread_id = payload.get("parent_thread_id") or (
            spawn.get("parent_thread_id") if isinstance(spawn, dict) else None)
        return
    if state.file_created is not None and ts < state.file_created - 2000:
        return
    state.last_line = ts if state.last_line is None else max(state.last_line, ts)
    ptype = payload.get("type")
    if kind == "turn_context":
        state.model = payload.get("model") or state.model
        state.project = basename(payload.get("cwd")) or state.project
        return
    if kind == "token_usage_record":
        state.saw_modern = True
        thread = payload.get("thread_id") or state.thread_id or state.path
        key = payload.get("response_id") or "codex:%s:%d" % (thread, ts)
        if dedupe.owner(key) is not None:
            return
        dedupe.claim(key, state.path)
        emit(state, key, state.pending, ts, codex_tokens(payload.get("usage")), state.model,
             provider=state.provider)
        after_usage(state, ts)
        return
    if kind == "event_msg":
        if ptype == "token_count":
            if state.saw_modern and state.streaming:
                after_usage(state, ts)
            else:
                legacy(state, ts, payload, dedupe)
        elif ptype in ("task_complete", "turn_aborted"):
            state.phase, state.pending, state.streaming, state.in_flight = "idle", None, False, None
        elif ptype in ("task_started", "user_message"):
            input_line(state, ts)
        return
    if kind == "response_item":
        role = payload.get("role")
        if ptype == "reasoning" or (isinstance(ptype, str) and ptype.endswith("_call")) or (
                ptype == "message" and role == "assistant"):
            state.streaming = True
            state.phase = "generating"
            state.in_flight = state.pending if state.pending is not None else ts
        elif (isinstance(ptype, str) and ptype.endswith("_output")) or (
                ptype == "message" and role in ("user", "developer", "system")):
            input_line(state, ts)
        elif ptype == "agent_message" and payload.get("recipient") == state.my_agent_path:
            if not state.streaming:
                state.pending = ts


def input_line(state, ts):
    if not state.streaming:
        state.pending = ts
        state.phase = "generating"
        state.in_flight = state.pending


def after_usage(state, ts):
    state.pending, state.streaming, state.phase, state.in_flight = ts, False, "tools", None


def legacy(state, ts, payload, dedupe):
    info = payload.get("info")
    if state.saw_modern or not isinstance(info, dict):
        return
    total = info.get("total_token_usage")
    last = info.get("last_token_usage")
    if not isinstance(total, dict):
        return
    fields = ("input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens",
              "reasoning_output_tokens", "total_tokens")
    if state.prev_legacy is None:
        usage = last if isinstance(last, dict) else total
    else:
        delta = {f: num(total.get(f)) - num(state.prev_legacy.get(f)) for f in fields}
        if delta["total_tokens"] == 0:
            return
        usage = (last if isinstance(last, dict) else {}) if any(v < 0 for v in delta.values()) else delta
    state.prev_legacy = total
    thread = state.thread_id or state.path
    key = "codex-legacy:%s:%d" % (thread, num(total.get("total_tokens")))
    if dedupe.owner(key) is not None:
        return
    dedupe.claim(key, state.path)
    emit(state, key, state.pending, ts, codex_tokens(usage), state.model, provider=state.provider)
    after_usage(state, ts)


def is_interrupt(message):
    content = message.get("content") if isinstance(message, dict) else None
    marker = "[Request interrupted by user"
    if isinstance(content, str):
        return content.startswith(marker)
    if isinstance(content, list):
        return any(isinstance(b, dict) and b.get("type") == "text" and isinstance(b.get("text"), str)
                   and b["text"].startswith(marker) for b in content)
    return False


def claude_tokens(usage):
    usage = usage if isinstance(usage, dict) else {}
    inp, cc, cr = num(usage.get("input_tokens")), num(usage.get("cache_creation_input_tokens")), num(
        usage.get("cache_read_input_tokens"))
    details = usage.get("output_tokens_details") if isinstance(usage.get("output_tokens_details"), dict) else {}
    creation = usage.get("cache_creation") if isinstance(usage.get("cache_creation"), dict) else {}
    return dict(input=cap(inp + cc + cr), cachedInput=cr, cacheWriteInput=cc,
                cacheWrite1hInput=min(cc, num(creation.get("ephemeral_1h_input_tokens"))),
                output=num(usage.get("output_tokens")), reasoning=num(details.get("thinking_tokens")))


def claude_line(state, obj, dedupe):
    ts = parse_ts(obj.get("timestamp"))
    if ts is None:
        return
    state.last_line = ts if state.last_line is None else max(state.last_line, ts)
    if not state.source_decided and isinstance(obj.get("entrypoint"), str):
        state.source = "claudeDesktop" if obj["entrypoint"].startswith("claude-desktop") else "claudeCode"
        state.source_decided = True
    state.project = basename(obj.get("cwd")) or state.project
    if obj.get("isSidechain") is True:
        state.is_subagent = True
    kind = obj.get("type")
    if kind == "api-request":
        state.pending, state.precise, state.phase, state.in_flight = ts, True, "generating", ts
    elif kind == "user":
        if is_interrupt(obj.get("message")):
            state.phase, state.pending, state.precise, state.in_flight = "idle", None, False, None
        else:
            if not state.precise:
                state.pending = ts
            state.phase, state.in_flight = "generating", state.pending
    elif kind == "assistant":
        message = obj.get("message") if isinstance(obj.get("message"), dict) else {}
        if message.get("model") == "<synthetic>":
            return
        key = message.get("id") or obj.get("requestId") or obj.get("uuid")
        if not isinstance(key, str) or not key:
            return
        owner = dedupe.owner(key)
        if owner is not None and owner != state.path:
            return
        tokens = claude_tokens(message.get("usage"))
        usage = message.get("usage") if isinstance(message.get("usage"), dict) else {}
        fast = usage.get("speed") == "fast"
        stop = message.get("stop_reason")
        resp = state.responses.get(key)
        if resp is None:
            dedupe.claim(key, state.path)
            emit(state, key, state.pending, ts, tokens, message.get("model"), stop is not None, fast=fast)
            state.pending, state.precise = None, False
            resp = state.responses[key]
        else:
            resp["endMs"] = max(resp["endMs"], ts)
            for f in TOKEN_FIELDS:
                resp[f] = max(resp[f], tokens[f])
            resp["model"] = message.get("model") or resp["model"]
            resp["fast"] = resp["fast"] or fast
            resp["final"] = resp["final"] or stop is not None
        state.model = resp["model"] or state.model
        content = message.get("content") if isinstance(message.get("content"), list) else []
        has_tool_use = any(isinstance(b, dict) and b.get("type") == "tool_use" for b in content)
        if stop == "tool_use" or (stop is None and has_tool_use):
            state.phase, state.in_flight = "tools", None
        elif stop is None or stop == "pause_turn":
            state.phase, state.in_flight = "generating", resp["startMs"] if resp["startMs"] is not None else ts
        else:
            state.phase, state.in_flight = "idle", None


ZSTD_MAGIC = 0xFD2FB528
SKIPPABLE_MAGIC = re.compile(rb"[\x50-\x5f]\x2a\x4d\x18")


def zstd_frame_size(data, pos):
    """Compressed size of the frame starting at pos, or None when it is not complete yet (zstd format spec)."""
    if len(data) - pos < 8:
        return None
    magic = int.from_bytes(data[pos:pos + 4], "little")
    if magic & 0xFFFFFFF0 == 0x184D2A50:
        size = 8 + int.from_bytes(data[pos + 4:pos + 8], "little")
        return size if len(data) - pos >= size else None
    if magic != ZSTD_MAGIC:
        raise ValueError("not a zstd frame")
    fhd = data[pos + 4]
    single, fcs_flag, checksum, dict_flag = (fhd >> 5) & 1, fhd >> 6, (fhd >> 2) & 1, fhd & 3
    header = 1 + (0 if single else 1) + [0, 1, 2, 4][dict_flag] + [1 if single else 0, 2, 4, 8][fcs_flag]
    cur = pos + 4 + header
    while True:
        if len(data) - cur < 3:
            return None
        bh = int.from_bytes(data[cur:cur + 3], "little")
        last, kind, size = bh & 1, (bh >> 1) & 3, bh >> 3
        cur += 3 + (1 if kind == 1 else size)
        if kind == 3:
            raise ValueError("reserved block type")
        if last:
            break
    cur += 4 if checksum else 0
    return cur - pos if cur <= len(data) else None


def zstd_lines(path, start_offset=0):
    data = open(path, "rb").read()
    pos, pending, malformed = start_offset, b"", 0
    while pos < len(data):
        try:
            size = zstd_frame_size(data, pos)
        except ValueError:
            malformed += 1
            candidates = [i for i in [data.find(b"\x28\xb5\x2f\xfd", pos + 1)] if i >= 0]
            skippable = SKIPPABLE_MAGIC.search(data, pos + 1)
            if skippable:
                candidates.append(skippable.start())
            if not candidates:
                break
            pos = min(candidates)
            continue
        if size is None:
            break
        frame = data[pos:pos + size]
        pos += size
        if int.from_bytes(frame[:4], "little") != ZSTD_MAGIC:
            continue
        out = subprocess.run(["zstd", "-dc", "-q"], input=frame, capture_output=True)
        if out.returncode != 0 or len(out.stdout) > 64 * 1024 * 1024:
            malformed += 1
            continue
        pending += out.stdout
        *complete, pending = pending.split(b"\n")
        for raw in complete:
            if raw.strip() and len(raw) <= MAX_LINE:
                yield raw
    if malformed:
        yield ("malformed", malformed)


def read_lines(path, start_offset=0, max_lines=None):
    with open(path, "rb") as f:
        f.seek(start_offset)
        data = f.read()
    if start_offset:
        nl = data.find(b"\n")
        data = data[nl + 1:] if nl >= 0 else b""
    end = data.rfind(b"\n")
    if end < 0:
        return
    for count, raw in enumerate(data[:end].split(b"\n"), start=1):
        if max_lines is not None and count > max_lines:
            return
        if len(raw) > MAX_LINE or not raw.strip():
            continue
        yield raw


def zst_stream_lines(path):
    """A compressed Codex session (METRICS 5.3): decompressed as one stream, always from the start."""
    if os.path.getsize(path) == 0:
        return  # nothing to read; not a decoding error (zstd -dc exits non-zero on an empty file)
    proc = subprocess.Popen(["zstd", "-dc", "-q", path], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    pending = b""
    try:
        for chunk in iter(lambda: proc.stdout.read(1 << 20), b""):
            pending += chunk
            *complete, pending = pending.split(b"\n")
            for raw in complete:
                if raw.strip() and len(raw) <= MAX_LINE:
                    yield raw
            if len(pending) > MAX_LINE:
                pending = b""
    finally:
        proc.stdout.close()
        if proc.wait() != 0:
            yield ("malformed", 1)


def process_file(state, dedupe, start_offset=0, max_lines=None):
    if state.source == "gemini" and state.path.endswith(".json"):
        return gemini_legacy(state, dedupe)
    handler = {"codex": codex_line, "deepseek": dsh_event, "gemini": gemini_record, "omp": omp_line,
               "workbuddy": workbuddy_line, "workbuddyAi": workbuddy_line}.get(state.source, claude_line)
    if state.source == "omp" and start_offset > 0:
        omp_read_header(state, dedupe)
    if state.path.endswith(".zstd"):
        lines = zstd_lines(state.path, start_offset)
    elif state.path.endswith(".jsonl.zst"):
        lines = zst_stream_lines(state.path)
    else:
        lines = read_lines(state.path, start_offset, max_lines)
    for raw in lines:
        if isinstance(raw, tuple):
            state.malformed += raw[1]
            continue
        try:
            obj = loads(raw)
        except (ValueError, UnicodeDecodeError, RecursionError):
            state.malformed += 1
            continue
        if not isinstance(obj, dict):
            state.malformed += 1
            continue
        handler(state, obj, dedupe)


def resolve_parents(states):
    """Maps agent id (path) to its parent agent id per METRICS 6.7."""
    by_path = {s.path: s for s in states}
    by_thread, by_session = {}, {}
    for s in sorted(states, key=lambda s: (s.file_created or 0, s.path)):
        if s.source == "codex" and s.thread_id and s.thread_id not in by_thread:
            by_thread[s.thread_id] = s.path
        if s.source == "deepseek" and s.thread_id and s.thread_id not in by_session:
            by_session[s.thread_id] = s.path
    gemini_mains = {}
    for s in sorted((s for s in states if s.source == "gemini" and s.thread_id),
                    key=lambda s: (0 if s.path.endswith(".jsonl") else 1, s.file_created or 0, s.path)):
        parts = re.split(r"[\\/]", s.path)
        if len(parts) >= 2 and parts[-2] == "chats":
            gemini_mains.setdefault((os.sep.join(parts[:-1]), GEMINI_SANITIZE.sub("_", s.thread_id)), s.path)
    parents = {}
    for s in states:
        parent = None
        if s.source == "codex":
            parent = by_thread.get(s.parent_thread_id) if s.parent_thread_id else None
        elif s.source == "deepseek":
            parent = by_session.get(s.parent_session) if s.parent_session else None
        elif s.source == "gemini":
            chats = os.sep.join(re.split(r"[\\/]", s.path)[:-2])
            parent = gemini_mains.get((chats, s.parent_session)) if s.parent_session else None
        elif s.source == "omp":
            candidate = os.path.dirname(s.path) + ".jsonl"
            tracked = candidate in by_path and by_path[candidate].source == "omp"
            parent = candidate if s.is_subagent and tracked else None
        else:
            parts = re.split(r"[\\/]", s.path)
            if len(parts) >= 3 and parts[-2] == "subagents":
                candidate = s.path[:len(s.path) - len(parts[-1]) - len(parts[-2]) - 2] + ".jsonl"
                parent = candidate if candidate in by_path else None
        parents[s.path] = parent if parent != s.path else None
    for path in list(parents):
        seen, cur = set(), path
        while cur is not None and cur not in seen:
            seen.add(cur)
            cur = parents.get(cur)
        if cur is not None:
            parents[path] = None
    return parents


def dsh_event(state, obj, dedupe):
    kind = obj.get("type")
    if kind == "event" and isinstance(obj.get("event"), dict):
        return dsh_event(state, obj["event"], dedupe)
    if kind == "snapshot":
        if isinstance(obj.get("header"), dict):
            dsh_header(state, obj["header"])
        for record in obj.get("records") or []:
            if isinstance(record, dict):
                dsh_event(state, record, dedupe)
        return
    if kind == "session":
        dsh_header(state, obj)
        return
    ts = obj.get("time")
    if not finite(ts):
        return
    ts = trunc64(ts)
    if state.file_created is not None and ts < state.file_created - 2000:
        return
    state.last_line = ts if state.last_line is None else max(state.last_line, ts)
    data = obj.get("data") if isinstance(obj.get("data"), dict) else {}
    if kind == "request/header":
        config = (data.get("header") or {}).get("config") if isinstance(data.get("header"), dict) else None
        if isinstance(config, dict) and isinstance(config.get("model"), str) and config["model"]:
            state.model = config["model"]
        if isinstance(config, dict) and isinstance(config.get("provider"), str) and config["provider"]:
            state.provider = config["provider"]
    elif kind == "step/start":
        state.pending, state.phase, state.in_flight = ts, "generating", ts
    elif kind == "turn/end":
        state.phase, state.pending, state.in_flight = "idle", None, None
    elif kind == "assistant/message":
        message = data.get("message") if isinstance(data.get("message"), dict) else {}
        key = message.get("id") or "dsh:%s:%s" % (state.thread_id, obj.get("seq"))
        if dedupe.owner(key) is not None:
            return
        dedupe.claim(key, state.path)
        usage = data.get("usage")
        if isinstance(usage, dict):
            cr, cw = num(usage.get("cacheReadTokens")), num(usage.get("cacheWriteTokens"))
            tokens = dict(input=cap(num(usage.get("inputTokens")) + cr + cw), cachedInput=cr, cacheWriteInput=cw,
                          output=num(usage.get("outputTokens")), reasoning=0)
            source = message.get("source") if isinstance(message.get("source"), dict) else {}
            model = source.get("model") or state.model
            provider = source.get("provider") if isinstance(source.get("provider"), str) and source["provider"] \
                else state.provider
            emit(state, key, state.pending, ts, tokens, model, provider=provider)
            state.model = model or state.model
        content = message.get("content") if isinstance(message.get("content"), list) else []
        tool = any(isinstance(b, dict) and b.get("type") == "tool-call" for b in content)
        state.pending, state.phase, state.in_flight = None, ("tools" if tool else "idle"), None


def dsh_header(state, header):
    if state.file_created is not None:
        return
    created = header.get("createdAt")
    state.file_created = trunc64(created) if finite(created) else 0
    state.thread_id = header.get("id") or state.thread_id
    state.project = basename(header.get("cwd")) or state.project
    parent = header.get("parentSession")
    depth = header.get("delegationDepth")
    state.parent_session = parent if isinstance(parent, str) and parent else None
    state.is_subagent = state.is_subagent or header.get("origin") == "subagent" or bool(state.parent_session) or (
        isinstance(depth, (int, float)) and not isinstance(depth, bool) and depth > 0)


def opencode_states(db_path, dedupe):
    """Parses an OpenCode database (METRICS 4.5); returns one state per session, keyed like agent ids."""
    db = sqlite_readonly(db_path)
    try:
        tables = {r[0] for r in db.execute("select name from sqlite_master where type='table'")}
        if not {"session_v2", "session_message"} <= tables:
            return []
        sessions = {r[0]: r for r in db.execute(
            "select id, parent_id, directory, time_created from session_v2")}
        states = {}
        for sid, parent, directory, created in sessions.values():
            st = FileState("opencode:" + sid, "opencode")
            st.project = basename(directory)
            st.is_subagent = parent is not None
            st.parent_session = ("opencode:" + parent) if parent in sessions else None
            st.file_created = created
            states[sid] = st
        rows = db.execute("select id, session_id, type, time_updated, data from session_message "
                          "order by session_id, seq")
        for rid, sid, kind, updated, data in rows:
            st = states.get(sid)
            if st is None:
                continue
            try:
                d = loads(data)
            except (ValueError, RecursionError):
                st.malformed += 1
                continue
            if not isinstance(d, dict):
                st.malformed += 1
                continue
            times = d.get("time") if isinstance(d.get("time"), dict) else {}
            if kind == "assistant":
                created = times.get("created")
                if isinstance(created, (int, float)) and created < st.file_created - 2000:
                    continue
                st.last_line = updated if st.last_line is None else max(st.last_line, updated)
                model = (d.get("model") or {}).get("id") if isinstance(d.get("model"), dict) else None
                provider = d["model"].get("providerID") if isinstance(d.get("model"), dict) else None
                provider = provider if isinstance(provider, str) and provider else None
                st.model = model or st.model
                if "streamed" not in times:
                    st.phase, st.in_flight = "generating", created
                    continue
                tokens = d.get("tokens")
                if isinstance(tokens, dict) and dedupe.owner(rid) in (None, st.path):
                    dedupe.claim(rid, st.path)
                    emit(st, rid, created, times["streamed"], opencode_tokens(tokens), model, provider=provider)
                st.phase = "tools" if d.get("finish") == "tool-calls" else "idle"
                st.in_flight = None
            else:
                st.last_line = updated if st.last_line is None else max(st.last_line, updated)
                if kind == "compaction" and isinstance(d.get("tokens"), dict):
                    if dedupe.owner(rid) in (None, st.path):
                        dedupe.claim(rid, st.path)
                        model = (d.get("model") or {}).get("id") if isinstance(d.get("model"), dict) else None
                        provider = d["model"].get("providerID") if isinstance(d.get("model"), dict) else None
                        emit(st, rid, times.get("created"), times.get("completed", updated),
                             opencode_tokens(d["tokens"]), model,
                             provider=provider if isinstance(provider, str) and provider else None)
                elif kind == "idle":
                    st.phase, st.in_flight = "idle", None
        return list(states.values())
    finally:
        db.close()


def opencode_tokens(t):
    cache = t.get("cache") if isinstance(t.get("cache"), dict) else {}
    cr, cw, r = num(cache.get("read")), num(cache.get("write")), num(t.get("reasoning"))
    return dict(input=cap(num(t.get("input")) + cr + cw), cachedInput=cr, cacheWriteInput=cw,
                output=cap(num(t.get("output")) + r), reasoning=r)


def gemini_tokens(t):
    return dict(input=cap(num(t.get("input")) + num(t.get("tool"))), cachedInput=num(t.get("cached")),
                cacheWriteInput=0, output=cap(num(t.get("output")) + num(t.get("thoughts"))),
                reasoning=num(t.get("thoughts")))


def gemini_content(content):
    """(has visible non-thought text, has a functionCall part)."""
    if isinstance(content, str):
        return bool(content.strip()), False
    if isinstance(content, dict):
        content = [content]
    text = call = False
    if isinstance(content, list):
        for part in content:
            if isinstance(part, str):
                text = text or bool(part.strip())
            elif isinstance(part, dict):
                if isinstance(part.get("functionCall"), dict):
                    call = True
                value = part.get("text")
                if isinstance(value, str) and value.strip() and part.get("thought") is not True:
                    text = True
    return text, call


def gemini_touch(state, ts):
    if ts is not None:
        state.last_line = ts if state.last_line is None else max(state.last_line, ts)


def gemini_idle(state):
    state.phase, state.pending, state.marker, state.in_flight = "idle", None, None, None


def gemini_generating(state, start, marker):
    state.phase, state.pending, state.marker, state.in_flight = "generating", start, marker, start


def gemini_model(msg):
    return msg.get("model") if isinstance(msg.get("model"), str) and msg.get("model") else None


def gemini_update(state, resp, end, tokens, model):
    resp.update(tokens)
    resp["endMs"] = max(resp["endMs"], end)
    resp["model"] = model or resp["model"]
    state.model = resp["model"] or state.model


def gemini_record(state, obj, dedupe):
    """One line of a Gemini CLI session (METRICS 4.6)."""
    if isinstance(obj.get("$rewindTo"), str):
        gemini_idle(state)
    elif isinstance(obj.get("$patch"), dict):
        removed = obj["$patch"].get("removeIds")
        if state.phase == "generating" and isinstance(removed, list) and state.marker in removed:
            gemini_idle(state)
    elif isinstance(obj.get("id"), str):
        gemini_message(state, obj, dedupe)
    elif isinstance(obj.get("$set"), dict):
        gemini_set(state, obj["$set"], dedupe)
    elif isinstance(obj.get("sessionId"), str) and isinstance(obj.get("projectHash"), str):
        gemini_header(state, obj, dedupe)


def gemini_header(state, obj, dedupe):
    state.thread_id = obj["sessionId"]
    if obj.get("kind") == "subagent":
        state.is_subagent = True
    started = parse_ts(obj.get("startTime"))
    if state.file_created is None:
        state.file_created = started
    gemini_touch(state, started)
    gemini_touch(state, parse_ts(obj.get("lastUpdated")))
    if isinstance(obj.get("messages"), list):
        for msg in obj["messages"]:
            if isinstance(msg, dict) and isinstance(msg.get("id"), str):
                gemini_message(state, msg, dedupe)


def gemini_set(state, values, dedupe):
    gemini_touch(state, parse_ts(values.get("lastUpdated")))
    if values.get("kind") == "subagent":
        state.is_subagent = True
    if isinstance(values.get("sessionId"), str):
        state.thread_id = values["sessionId"]
    if isinstance(values.get("messages"), list):
        gemini_checkpoint(state, values["messages"], dedupe)
    if isinstance(values.get("summary"), str) and values["summary"]:
        gemini_idle(state)


def gemini_checkpoint(state, messages, dedupe):
    ids = set()
    for msg in messages:
        if not isinstance(msg, dict) or not isinstance(msg.get("id"), str):
            continue
        ids.add(msg["id"])
        if msg.get("type") != "gemini" or not isinstance(msg.get("tokens"), dict):
            continue
        key, ts = msg["id"], parse_ts(msg.get("timestamp"))
        if ts is None or dedupe.owner(key) not in (None, state.path):
            continue
        tokens, model = gemini_tokens(msg["tokens"]), gemini_model(msg)
        resp = state.responses.get(key)
        if resp is None:
            dedupe.claim(key, state.path)
            emit(state, key, None, ts, tokens, model)
            state.model = model or state.model
        else:
            gemini_update(state, resp, ts, tokens, model)
    if state.phase == "generating" and state.marker not in ids:
        gemini_idle(state)


def gemini_message(state, msg, dedupe):
    ts = parse_ts(msg.get("timestamp"))
    if ts is None:
        return
    gemini_touch(state, ts)
    calls = msg.get("toolCalls") if isinstance(msg.get("toolCalls"), list) else []
    calls = [c for c in calls if isinstance(c, dict) and isinstance(c.get("id"), str)]
    call_ts = [t for t in (parse_ts(c.get("timestamp")) for c in calls) if t is not None]
    for t in call_ts:
        gemini_touch(state, t)
    for th in msg.get("thoughts") if isinstance(msg.get("thoughts"), list) else []:
        if isinstance(th, dict):
            gemini_touch(state, parse_ts(th.get("timestamp")))
    kind = msg.get("type")
    if kind == "user":
        gemini_generating(state, ts, msg["id"])
        return
    if kind == "error" or (kind == "info" and msg.get("content") == GEMINI_CANCELLED):
        gemini_idle(state)
        return
    if kind != "gemini":
        return
    key = msg["id"]
    if dedupe.owner(key) not in (None, state.path):
        return
    if isinstance(msg.get("tokens"), dict):
        tokens, model = gemini_tokens(msg["tokens"]), gemini_model(msg)
        resp = state.responses.get(key)
        if resp is None:
            start = None if call_ts and ts >= min(call_ts) else state.pending
            dedupe.claim(key, state.path)
            emit(state, key, start, ts, tokens, model)
            state.model = model or state.model
            has_text, has_call = gemini_content(msg.get("content"))
            state.phase = "tools" if has_call or not has_text else "idle"
            state.pending, state.marker, state.in_flight = None, None, None
        else:
            gemini_update(state, resp, ts, tokens, model)
    new_calls = [c for c in calls if c["id"] not in state.seen_calls]
    state.seen_calls.update(c["id"] for c in new_calls)
    if not new_calls:
        return
    if any(c.get("name") == "complete_task" and c.get("status") == "success" for c in new_calls):
        gemini_idle(state)
    elif all(c.get("status") == "cancelled" for c in new_calls):
        gemini_idle(state)
    else:
        times = [t for t in (parse_ts(c.get("timestamp")) for c in new_calls) if t is not None]
        gemini_generating(state, max(times) if times else ts, key)


def gemini_legacy(state, dedupe):
    """A legacy (<= v0.38) whole-document session file: replayed from the start on every change."""
    if os.path.getsize(state.path) > GEMINI_LEGACY_MAX:
        state.partial_history = True
        return
    try:
        with open(state.path, "rb") as f:
            obj = loads(f.read())
    except (ValueError, UnicodeDecodeError, RecursionError):
        state.malformed += 1
        return
    if isinstance(obj, dict) and isinstance(obj.get("sessionId"), str):
        gemini_header(state, obj, dedupe)
    else:
        state.malformed += 1


_gemini_projects = {}


def gemini_project(path):
    parts = re.split(r"[\\/]", path)
    if len(parts) >= 3 and parts[-2] == "chats":
        project_dir = os.sep.join(parts[:-2])
    elif len(parts) >= 4 and parts[-3] == "chats":
        project_dir = os.sep.join(parts[:-3])
    else:
        return None
    if project_dir in _gemini_projects:
        return _gemini_projects[project_dir]
    project = None
    try:
        with open(os.path.join(project_dir, ".project_root"), encoding="utf-8") as f:
            project = basename(f.read().strip())
    except OSError:
        try:
            registry = os.path.join(os.path.dirname(os.path.dirname(project_dir)), "projects.json")
            with open(registry, encoding="utf-8") as f:
                projects = json.load(f).get("projects")
            slug = os.path.basename(project_dir)
            if isinstance(projects, dict):
                project = next((basename(k) for k, v in projects.items() if v == slug), None)
        except (OSError, ValueError, AttributeError):
            project = None
    _gemini_projects[project_dir] = project
    return project


def gemini_roots(env=None, platform=None):
    env = os.environ if env is None else env
    platform = sys.platform if platform is None else platform
    home = env.get("GEMINI_CLI_HOME") or os.path.expanduser("~")
    found = [os.path.join(home, ".gemini", "tmp")]
    if platform == "darwin":
        found.append(os.path.join(home, ".cache", ".gemini", "tmp"))
    return found


def discover_gemini(root, limit=20_000):
    found = []
    if not os.path.isdir(root):
        return found
    for project in sorted(os.listdir(root)):
        chats = os.path.join(root, project, "chats")
        if os.path.islink(os.path.join(root, project)) or os.path.islink(chats) or not os.path.isdir(chats):
            continue
        for name in os.listdir(chats):
            full = os.path.join(chats, name)
            if os.path.islink(full):
                continue
            if os.path.isdir(full):
                for sub in os.listdir(full):
                    nested = os.path.join(full, sub)
                    if sub.endswith((".jsonl", ".json")) and os.path.isfile(nested) and not os.path.islink(nested):
                        found.append(nested)
            elif name.endswith((".jsonl", ".json")) and os.path.isfile(full):
                found.append(full)
    found.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return found[:limit]


# ----------------------------------------------------------------------------- omp (METRICS 4.7)

def omp_touch(state, ts):
    state.last_line = ts if state.last_line is None else max(state.last_line, ts)


def omp_tokens(usage):
    cr, cw = num(usage.get("cacheRead")), num(usage.get("cacheWrite"))
    return dict(input=cap(num(usage.get("input")) + cr + cw), cachedInput=cr, cacheWriteInput=cw,
                output=num(usage.get("output")), reasoning=num(usage.get("reasoningTokens")))


def omp_has_usage(usage):
    return any(num(usage.get(f)) > 0 for f in ("input", "output", "cacheRead", "cacheWrite"))


def omp_guard(obj):
    return (all(isinstance(obj.get(f), str) for f in ("model", "provider", "api"))
            and isinstance(obj.get("usage"), dict))


def omp_line(state, obj, dedupe):
    """One line of an omp session file (METRICS 4.7)."""
    kind = obj.get("type")
    if kind == "title":
        return
    if kind == "session":
        if state.header_seen:
            return
        state.header_seen = True
        state.file_created = parse_ts(obj.get("timestamp"))
        state.project = basename(obj.get("cwd"))
        state.thread_id = obj.get("id") if isinstance(obj.get("id"), str) else None
        if state.file_created is not None:
            omp_touch(state, state.file_created)
        return
    if not state.header_seen or not isinstance(obj.get("id"), str):
        return
    ts = parse_ts(obj.get("timestamp"))
    if ts is None or (state.file_created is not None and ts < state.file_created - OMP_COPY_MS):
        return
    omp_touch(state, ts)
    if kind == "message" and isinstance(obj.get("message"), dict):
        msg = obj["message"]
        role = msg.get("role")
        if role in ("user", "developer"):
            state.phase, state.in_flight = "generating", ts
            state.pending_calls.clear()
        elif role == "assistant":
            omp_assistant(state, obj, msg, ts, dedupe)
        elif role == "toolResult":
            state.pending_calls.discard(msg.get("toolCallId"))
            if msg.get("toolName") == "yield" and msg.get("isError") is not True:
                state.phase, state.in_flight = "idle", None
            elif state.phase == "tools" and not state.pending_calls:
                state.phase, state.in_flight = "generating", ts
    elif kind == "model_usage":
        if not omp_guard(obj):
            return
        key = "omp:%s:%d" % (obj["id"], ts)
        if dedupe.owner(key) not in (None, state.path) or not omp_has_usage(obj["usage"]):
            return
        dedupe.claim(key, state.path)
        emit(state, key, None, ts, omp_tokens(obj["usage"]), obj["model"], provider=obj["provider"] or None)
    elif kind == "custom" and obj.get("customType") == "session_exit":
        state.phase, state.in_flight = "idle", None
        state.pending_calls.clear()


def omp_assistant(state, entry, msg, ts, dedupe):
    if not omp_guard(msg):
        return
    started = trunc64(msg["timestamp"]) if finite(msg.get("timestamp")) and msg["timestamp"] > 0 else None
    key = "omp:%s:%d" % (entry["id"], started if started is not None else ts)
    if dedupe.owner(key) not in (None, state.path):
        return
    stop = msg.get("stopReason") if isinstance(msg.get("stopReason"), str) else "aborted"
    duration, completed = msg.get("duration"), msg.get("completedAt")
    if started is not None and finite(duration) and duration >= 0:
        end = min(started + trunc64(duration), INT64_MAX)
    elif finite(completed) and completed > 0:
        end = trunc64(completed)
    else:
        end = ts
    if omp_has_usage(msg["usage"]):
        dedupe.claim(key, state.path)
        emit(state, key, None if stop in ("error", "aborted") else started, end, omp_tokens(msg["usage"]),
             msg["model"], provider=msg["provider"] or None)
        state.model = msg["model"]
    content = msg.get("content") if isinstance(msg.get("content"), list) else []
    calls = {b["id"] for b in content if isinstance(b, dict) and b.get("type") == "toolCall"
             and isinstance(b.get("id"), str)}
    details = msg.get("stopDetails") if isinstance(msg.get("stopDetails"), dict) else {}
    if stop in ("error", "aborted"):
        state.phase, state.in_flight = "idle", None
        state.pending_calls.clear()
    elif calls and stop in ("toolUse", "stop", "length"):
        state.phase, state.in_flight, state.pending_calls = "tools", None, calls
    elif stop == "stop" and details.get("type") == "pause_turn":
        state.phase, state.in_flight = "generating", end
    else:
        state.phase, state.in_flight = "idle", None


def omp_read_header(state, dedupe):
    """Reading that starts mid-file first takes the header from the first two lines (METRICS 4.7)."""
    with open(state.path, "rb") as f:
        for _ in range(2):
            raw = f.readline(MAX_LINE)
            try:
                obj = loads(raw)
            except (ValueError, UnicodeDecodeError, RecursionError):
                continue
            if isinstance(obj, dict) and obj.get("type") == "session":
                omp_line(state, obj, dedupe)
                return


def _subdirs(path):
    try:
        return [n for n in os.listdir(path)
                if os.path.isdir(os.path.join(path, n)) and not os.path.islink(os.path.join(path, n))]
    except OSError:
        return []


def omp_roots(env=None, platform=None, home=None):
    """The automatic omp roots (METRICS 2, 4.7): the default root, then one per named profile."""
    env = os.environ if env is None else env
    platform = sys.platform if platform is None else platform
    home = home or os.path.expanduser("~")
    cfg = os.path.join(home, (env.get("PI_CONFIG_DIR") or ".omp").lstrip("/\\"))
    xdg = env.get("XDG_DATA_HOME") if platform == "darwin" else None
    xdg_omp = os.path.join(xdg, "omp") if xdg else None
    if env.get("PI_CODING_AGENT_DIR"):
        roots = [os.path.join(env["PI_CODING_AGENT_DIR"], "sessions")]
    elif xdg_omp and os.path.isdir(xdg_omp):
        roots = [os.path.join(xdg_omp, "sessions")]
    else:
        roots = [os.path.join(cfg, "agent", "sessions")]
    names = set(_subdirs(os.path.join(cfg, "profiles")))
    if xdg_omp:
        names |= set(_subdirs(os.path.join(xdg_omp, "profiles")))
    for name in sorted(names):
        xdg_profile = os.path.join(xdg_omp, "profiles", name) if xdg_omp else None
        if xdg_profile and os.path.isdir(xdg_profile):
            roots.append(os.path.join(xdg_profile, "sessions"))
        else:
            roots.append(os.path.join(cfg, "profiles", name, "agent", "sessions"))
    return list(OrderedDict.fromkeys(roots))


def discover_omp(root, limit=20_000):
    found = []
    if not os.path.isdir(root):
        return found
    base_depth = root.rstrip(os.sep).count(os.sep)
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        depth = dirpath.rstrip(os.sep).count(os.sep) - base_depth
        dirnames[:] = [] if depth >= 6 else [d for d in dirnames if not d.startswith(".")
                                              and not os.path.islink(os.path.join(dirpath, d))]
        if depth < 1:
            continue
        for name in filenames:
            path = os.path.join(dirpath, name)
            if name.endswith(".jsonl") and not name.startswith(".") and not os.path.islink(path):
                found.append(path)
    found.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return found[:limit]


# ----------------------------------------------------------------------------- WorkBuddy (METRICS 4.9)

WB_FOLDERS = OrderedDict([("workbuddy", ".workbuddy"), ("workbuddyAi", ".workbuddy-ai")])
WB_USER_PREFIXES = ("custom:", "custom-local:")


def wb_ts(value):
    if finite(value):
        return trunc64(value) if value > 0 else None
    return parse_ts(value)


def wb_first(*values):
    """The first value that is a finite number > 0, truncated (0.5 gives 0 and ends the search); 0 when none. Like the
    CLI's firstPositiveTokenCount."""
    return next((num(v) for v in values if finite(v) and v > 0), 0)


def wb_sum(details, field):
    """Σ field over agents-core's per-request detail entries (a list of objects; one object is accepted too)."""
    entries = details if isinstance(details, list) else [details]
    return cap(sum(num(e.get(field)) for e in entries if isinstance(e, dict)))


def wb_tokens(pd):
    """Normalized usage of one model call (METRICS 4.9 Tokens): agents-core's usage, completed from the raw chunk."""
    usage = pd.get("usage") if isinstance(pd.get("usage"), dict) else {}
    raw = pd.get("rawUsage") if isinstance(pd.get("rawUsage"), dict) else {}
    prompt = raw.get("prompt_tokens_details") if isinstance(raw.get("prompt_tokens_details"), dict) else {}
    completion = raw.get("completion_tokens_details") if isinstance(raw.get("completion_tokens_details"), dict) else {}
    cached = max(wb_sum(usage.get("inputTokensDetails"), "cached_tokens"),
                 wb_first(raw.get("cache_read_input_tokens"), prompt.get("cached_tokens"),
                          raw.get("prompt_cache_hit_tokens")))
    write = wb_first(raw.get("cache_creation_input_tokens"), raw.get("prompt_cache_write_tokens"))
    output = max(num(usage.get("outputTokens")), num(raw.get("completion_tokens")))
    reasoning = max(wb_sum(usage.get("outputTokensDetails"), "reasoning_tokens"),
                    num(completion.get("reasoning_tokens")))
    inp = max(num(usage.get("inputTokens")), num(raw.get("prompt_tokens")), cap(cached + write))
    return dict(input=inp, cachedInput=cached, cacheWriteInput=write, output=output, reasoning=reasoning)


def wb_model(pd):
    """(model, provider): the chunk's model, else the requested id; a user-provider prefix is removed (4.9)."""
    model = next((v.strip() for v in (pd.get("model"), pd.get("requestModelId")) if isinstance(v, str) and v.strip()),
                 None)
    if model and model.lower().startswith(WB_USER_PREFIXES):
        return model.split(":", 1)[1].strip() or None, "custom"
    return model, None


def wb_idle(state):
    state.phase, state.pending, state.in_flight = "idle", None, None
    state.open_calls.clear()


def wb_response(state, key, pd, ts, dedupe):
    """Creates or merges the response of one model call from a line that carries usage (4.9 step 3)."""
    if not isinstance(pd.get("usage"), dict) and not isinstance(pd.get("rawUsage"), dict):
        return
    tokens = wb_tokens(pd)
    if tokens["input"] == 0 and tokens["output"] == 0:
        return
    model, provider = wb_model(pd)
    resp = state.responses.get(key)
    if resp is None:
        dedupe.claim(key, state.path)
        emit(state, key, state.pending, ts, tokens, model, provider=provider)
        state.pending = None
        resp = state.responses[key]
    else:
        resp["endMs"] = max(resp["endMs"], ts)
        for f in TOKEN_FIELDS:
            resp[f] = max(resp[f], tokens.get(f, 0))
        resp["model"] = model or resp["model"]
        resp["provider"] = provider or resp["provider"]
    state.model = resp["model"] or state.model


def workbuddy_line(state, obj, dedupe):
    """One line of a WorkBuddy session file (METRICS 4.9)."""
    ts = wb_ts(obj.get("timestamp"))
    if ts is None:
        return
    state.last_line = ts if state.last_line is None else max(state.last_line, ts)
    if isinstance(obj.get("cwd"), str) and obj["cwd"].strip():
        state.cwd = obj["cwd"]
        state.project = basename(obj["cwd"]) or state.project
    kind, role = obj.get("type"), obj.get("role")
    pd = obj.get("providerData") if isinstance(obj.get("providerData"), dict) else {}
    skip = pd.get("skipRun") is True
    if kind == "message" and role == "user":
        if not skip:
            state.open_calls.clear()
            state.phase, state.pending, state.in_flight = "generating", ts, ts
        return
    call_id = obj.get("callId") if isinstance(obj.get("callId"), str) else None
    if kind == "function_call_result":
        state.open_calls.pop(call_id, None)
        if skip:
            if not state.open_calls:
                wb_idle(state)
        else:
            state.pending = ts
            if not state.open_calls:
                state.phase, state.in_flight = "generating", ts
        return
    assistant = kind == "message" and role == "assistant"
    if not (assistant or kind in ("function_call", "reasoning", "model-usage")):
        return
    if assistant and skip:
        if obj.get("status") == "incomplete" or isinstance(pd.get("error"), dict):
            wb_idle(state)
        return
    if pd.get("isPartialAborted") is True:
        return
    mid = pd.get("messageId")
    key = mid if isinstance(mid, str) and mid else (
        "workbuddy:" + obj["id"] if isinstance(obj.get("id"), str) and obj["id"] else None)
    if key is None or dedupe.owner(key) not in (None, state.path):
        return
    wb_response(state, key, pd, ts, dedupe)
    if kind == "model-usage":
        wb_idle(state)
        return
    for call_id in [c for c, k in state.open_calls.items() if k != key]:
        del state.open_calls[call_id]
    if kind == "function_call":
        if call_id is not None:
            state.open_calls[call_id] = key
        state.phase, state.in_flight = "tools", None
    elif assistant and not state.open_calls:
        if pd.get("agent") == "compact":
            state.phase, state.pending, state.in_flight = "generating", ts, ts
        else:
            state.phase, state.in_flight = "idle", None


def workbuddy_roots(home=None, settings=None):
    """(source, projects folder) of both editions (METRICS 2, 4.9); a setting names the data root or `projects`."""
    home = home or os.path.expanduser("~")
    settings = settings or {}
    roots = []
    for source, folder in WB_FOLDERS.items():
        chosen = (settings.get(source) or "").rstrip("/\\")
        path = chosen or os.path.join(home, folder)
        roots.append((source, path if os.path.basename(path) == "projects" else os.path.join(path, "projects")))
    return roots


def discover_workbuddy(projects, limit=20_000):
    """Main sessions `<slug>/<name>.jsonl` and sub-agents `<slug>/<session>/subagents/<name>.jsonl` (4.9)."""
    found = []
    for slug in sorted(_subdirs(projects)):
        if slug == "cloud" or slug.startswith("."):
            continue
        base = os.path.join(projects, slug)
        candidates = [os.path.join(base, n) for n in os.listdir(base)]
        for session in _subdirs(base):
            agents = os.path.join(base, session, "subagents")
            if not session.startswith(".") and os.path.isdir(agents) and not os.path.islink(agents):
                candidates += [os.path.join(agents, n) for n in os.listdir(agents)]
        for path in candidates:
            name = os.path.basename(path)
            if name.endswith(".jsonl") and not name.startswith(".") and os.path.isfile(path) \
                    and not os.path.islink(path):
                found.append(path)
    found.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return found[:limit]


# ----------------------------------------------------------------------------- Antigravity (METRICS 4.8)

def pb_varint(data, pos):
    result = 0
    for i in range(10):
        if pos >= len(data):
            raise ValueError("truncated varint")
        byte = data[pos]
        pos += 1
        result |= (byte & 0x7F) << (7 * i)
        if not byte & 0x80:
            return result & 0xFFFF_FFFF_FFFF_FFFF, pos
    raise ValueError("varint longer than 10 bytes")


def pb_fields(data):
    """Top-level fields of a protobuf message as (number, wire, value); raises ValueError when malformed."""
    out, pos = [], 0
    while pos < len(data):
        key, pos = pb_varint(data, pos)
        number, wire = key >> 3, key & 7
        if number == 0:
            raise ValueError("field 0")
        if wire == 0:
            value, pos = pb_varint(data, pos)
        elif wire in (1, 5):
            size = 8 if wire == 1 else 4
            if pos + size > len(data):
                raise ValueError("truncated fixed field")
            value, pos = int.from_bytes(data[pos:pos + size], "little"), pos + size
        elif wire == 2:
            size, pos = pb_varint(data, pos)
            if size > len(data) - pos:
                raise ValueError("truncated length-delimited field")
            value, pos = bytes(data[pos:pos + size]), pos + size
        else:
            raise ValueError("wire type %d" % wire)
        out.append((number, wire, value))
    return out


def pb_last(fields, number, wire):
    values = [v for n, w, v in fields if n == number and w == wire]
    return values[-1] if values else None


def pb_first(fields, number, wire):
    values = [v for n, w, v in fields if n == number and w == wire]
    return values[0] if values else None


def pb_int(fields, number):
    value = pb_last(fields, number, 0)
    return 0 if value is None else value


def pb_signed(fields, number):
    value = pb_int(fields, number)
    return value - (1 << 64) if value >= 1 << 63 else value


def pb_str(fields, number, first=False):
    value = (pb_first if first else pb_last)(fields, number, 2)
    return value.decode("utf-8", "replace") if value else ""


def pb_msg(fields, number, first=False):
    value = (pb_first if first else pb_last)(fields, number, 2)
    return None if value is None else pb_fields(value)


def pb_timestamp(fields, number):
    sub = pb_msg(fields, number)
    if sub is None:
        return None
    seconds, nanos = pb_signed(sub, 1), pb_signed(sub, 2)
    if seconds <= 0:
        return None
    return seconds * 1000 + (nanos // 1_000_000 if 0 <= nanos <= 999_999_999 else 0)


def pb_repeated_uint(fields, number):
    values = []
    for n, w, v in fields:
        if n != number:
            continue
        if w == 0:
            values.append(v)
        elif w == 2:
            pos = 0
            while pos < len(v):
                item, pos = pb_varint(v, pos)
                values.append(item)
    return values


def uri_basename(value):
    """Basename of a path or URI; a URI loses its scheme and authority and is percent-decoded (METRICS 4.8)."""
    if not value:
        return None
    m = re.match(r"^[A-Za-z][A-Za-z0-9+.-]+:", value)
    if m:
        rest = value[m.end():]
        if rest.startswith("//"):
            slash = rest.find("/", 2)
            rest = rest[slash:] if slash >= 0 else ""
        value = unquote(rest, encoding="utf-8", errors="replace")
    return basename(value)


def sqlite_readonly(db_path):
    """Opens a database read-only without ever creating a file (METRICS 4.5, 4.8)."""
    with open(db_path, "rb") as f:
        header = f.read(20)
    closed_wal = len(header) == 20 and header[18] == 2 and header[19] == 2 and not os.path.exists(db_path + "-wal")
    try:
        if closed_wal:
            raise sqlite3.OperationalError("closed WAL database")
        db = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True, timeout=2)
        db.execute("select 1 from sqlite_master limit 1")
    except sqlite3.OperationalError:
        if os.path.exists(db_path + "-wal"):
            raise
        db = sqlite3.connect("file:%s?immutable=1" % db_path, uri=True, timeout=2)
    return db


def ag_rows(db, sql):
    try:
        return db.execute(sql).fetchall()
    except sqlite3.DatabaseError:
        return []


def ag_decode(state, blob, decoder):
    if blob is None:
        return None
    try:
        return decoder(bytes(blob))
    except ValueError:
        state.malformed += 1
        return None


def ag_trajectory(data):
    fields = pb_fields(data)
    workspace = pb_msg(fields, 1, first=True)
    uris = [v.decode("utf-8", "replace") for n, w, v in fields if n == 7 and w == 2]
    project = uri_basename(uris[0]) if uris else None
    if project is None and workspace is not None:
        project = uri_basename(pb_str(workspace, 1))
    parent = pb_str(fields, 5)
    return dict(created=pb_timestamp(fields, 2), parent=parent or None, project=project,
                subagent=bool(parent) or pb_signed(fields, 17) > 0 or pb_last(fields, 8, 2) is not None)


def ag_generation(data):
    fields = pb_fields(data)
    chat = pb_msg(fields, 1) or []
    return dict(steps=set(pb_repeated_uint(fields, 2)), model=pb_str(chat, 19) or pb_str(chat, 21) or None)


def ag_executor(data):
    fields = pb_fields(data)
    planner = pb_msg(pb_msg(fields, 10) or [], 1) or []
    return dict(reason=pb_signed(fields, 1), last=pb_signed(fields, 3), model=pb_str(planner, 28) or None)


AG_TIMES = (("created", 1), ("viewable", 6), ("finished", 7), ("completed", 8), ("chunk", 22), ("started", 32))


def ag_step(data):
    fields = pb_fields(data)
    step = {name: pb_timestamp(fields, number) for name, number in AG_TIMES}
    use = pb_msg(fields, 9)
    if use is not None:
        tokens = {name: pb_int(use, number) for name, number in (
            ("input", 2), ("output", 3), ("cache", 5), ("thinking", 9), ("response", 10))}
        if any(v > AG_TOKEN_MAX for v in tokens.values()):
            raise ValueError("implausible token count")
        tokens["key"] = pb_str(use, 11) or pb_str(use, 7) or None
    step["usage"] = None if use is None else tokens
    return step


def antigravity_state(db_path, dedupe):
    """Parses one Antigravity conversation database completely; None when its format is unsupported."""
    db = sqlite_readonly(db_path)
    try:
        columns = {r[1] for r in ag_rows(db, "PRAGMA table_info(steps)")}
        if not {"idx", "step_type", "status", "metadata"} <= columns:
            return None
        st = FileState(db_path, "antigravity")
        conversation = os.path.basename(db_path)[:-3]
        traj = None
        for (blob,) in ag_rows(db, "SELECT CASE WHEN length(data) <= %d THEN data END FROM trajectory_metadata_blob "
                                   "ORDER BY rowid LIMIT 1" % AG_BLOB_MAX):
            traj = ag_decode(st, blob, ag_trajectory)
        created = traj["created"] if traj else None
        if traj:
            st.project, st.is_subagent, st.parent_session = traj["project"], traj["subagent"], traj["parent"]
        st.file_created = created
        gens = [g for _, blob in ag_last_per_idx(ag_rows(
                    db, "SELECT idx, CASE WHEN typeof(size) = 'integer' AND size <= %d AND length(data) <= %d THEN data "
                        "END FROM gen_metadata WHERE idx > -1 ORDER BY idx, rowid" % (AG_BLOB_MAX, AG_BLOB_MAX)))
                for g in [ag_decode(st, blob, ag_generation)] if g]
        execs = [dict(e, idx=idx) for idx, blob in ag_last_per_idx(ag_rows(
                    db, "SELECT idx, CASE WHEN length(data) <= %d THEN data END FROM executor_metadata WHERE idx > -1 "
                        "ORDER BY idx, rowid" % AG_BLOB_MAX))
                 for e in [ag_decode(st, blob, ag_executor)] if e]

        def model_for(idx):
            generation = next((g for g in gens if idx in g["steps"]), None)
            if generation and generation["model"]:
                return generation["model"]
            covering = sorted((e for e in execs if e["last"] >= idx), key=lambda e: (e["last"], e["idx"]))
            return covering[0]["model"] if covering else None

        times = [created] if created is not None else []
        latest = None
        models = {}
        for idx, step_type, status, blob in ag_last_per_idx(ag_rows(
                db, "SELECT idx, step_type, status, CASE WHEN length(metadata) <= %d THEN metadata END FROM steps "
                    "WHERE idx > -1 ORDER BY idx, rowid" % AG_BLOB_MAX)):
            idx, step_type, status = idx or 0, step_type or 0, status or 0
            step = ag_decode(st, blob, ag_step)
            if step is None:
                continue
            if created is not None and step["created"] is not None and step["created"] < created - 2000:
                continue
            row_times = [t for name, t in step.items() if name != "usage" and t is not None]
            times += row_times
            latest = dict(step, idx=idx, type=step_type, status=status)
            use = step["usage"]
            if step_type != 15 or status in AG_OPEN or not use:
                continue
            if not any(use[f] > 0 for f in ("input", "output", "cache", "thinking", "response")):
                continue
            key = use["key"] or "antigravity:%s:%d" % (conversation, idx)
            if dedupe.owner(key) not in (None, st.path):
                continue
            end = step["finished"] or step["chunk"] or step["completed"]
            start = step["created"]
            if end is None:
                if not row_times:
                    continue
                end, start = max(row_times), None
            if status in AG_FAILED:
                start = None
            dedupe.claim(key, st.path)
            models[key] = model_for(idx)
            output = use["output"] or use["thinking"] + use["response"]
            emit(st, key, start, end, dict(input=use["input"] + use["cache"], cachedInput=use["cache"],
                                           cacheWriteInput=0, output=output, reasoning=use["thinking"]), models[key])
            if models[key]:
                st.model = models[key]
        st.last_line = max(times) if times else None
        st.phase, st.in_flight = ag_phase(latest, execs)
        return st
    finally:
        db.close()


def ag_last_per_idx(rows):
    """Rows with the same idx are processed in rowid order, the later one replacing the earlier (METRICS 4.8)."""
    last = OrderedDict()
    for row in rows:
        last[row[0]] = row
    return list(last.values())


def ag_phase(latest, execs):
    if latest is None or any(e["reason"] != 0 and e["last"] >= latest["idx"] for e in execs):
        return "idle", None
    kind, status = latest["type"], latest["status"]
    if kind == 15:
        return ("generating", latest["created"]) if status in AG_OPEN else ("idle", None)
    if kind == 14:
        return ("idle", None) if status in AG_FAILED else ("generating", latest["created"])
    if status in AG_OPEN:
        return "tools", None
    if status == 3:
        return "generating", latest["completed"] if latest["completed"] is not None else latest["created"]
    return "idle", None


def antigravity_stores(home=None, setting=None, gemini_dir=None):
    """The stores to read (METRICS 2, 4.8); a `-backup` store is never read."""
    if setting:
        candidates = [setting]
    else:
        base = gemini_dir or os.path.join(home or os.path.expanduser("~"), ".gemini")
        candidates = [os.path.join(base, n) for n in ("antigravity-cli", "antigravity", "antigravity-ide")]
    stores = []
    for c in candidates:
        c = c.rstrip("/\\")
        store = os.path.dirname(c) if os.path.basename(c) == "conversations" else c
        if not os.path.basename(store).endswith("-backup"):
            stores.append(c)
    return stores


def discover_antigravity(store, limit=20_000):
    folder = store if os.path.basename(store.rstrip("/\\")) == "conversations" else os.path.join(store, "conversations")
    try:
        names = sorted(os.listdir(folder))
    except OSError:
        return []
    found = [os.path.join(folder, n) for n in names if AG_NAME.match(n)
             and os.path.isfile(os.path.join(folder, n)) and not os.path.islink(os.path.join(folder, n))]
    found.sort(key=ag_mtime, reverse=True)
    return found[:limit]


def ag_mtime(path):
    """A database's time for startup order: the newer of the .db and its -wal (METRICS 5.4)."""
    wal = path + "-wal"
    return max(os.path.getmtime(path), os.path.getmtime(wal) if os.path.exists(wal) else 0)


def antigravity_parents(states):
    by_id = {}
    for s in states:
        by_id.setdefault(os.path.basename(s.path)[:-3].lower(), []).append(s.path)
    parents = {}
    for s in states:
        candidates = by_id.get((s.parent_session or "").lower(), []) if s.parent_session else []
        candidates = sorted(candidates, key=lambda p: (os.path.dirname(p) != os.path.dirname(s.path), p))
        parent = candidates[0] if candidates else None
        parents[s.path] = parent if parent != s.path else None
    for path in list(parents):
        seen, cur = set(), path
        while cur is not None and cur not in seen:
            seen.add(cur)
            cur = parents.get(cur)
        if cur is not None:
            parents[path] = None
    return parents


# ----------------------------------------------------------------------------- engine

def interval(resp):
    start, end = resp.get("startMs"), resp["endMs"]
    if start is None or end < start or end - start > 15 * 60_000:
        return None
    return (min(start, end - 500), end)


def overlap(a0, a1, b0, b1):
    return max(0, min(a1, b1) - max(a0, b0))


def speed_of(responses):
    out = tot = dur = 0.0
    for r in responses:
        iv = interval(r)
        out += r["output"]
        tot += r["output"] + r["input"]
        dur += (iv[1] - iv[0]) / 1000
    return (out / dur, tot / dur) if dur > 0 else None


def recent(valid, now, predicate, limit, horizon):
    picked = recent_set(valid, now, predicate, limit, horizon)
    return speed_of(picked) if picked else None


def recent_set(valid, now, predicate, limit, horizon):
    picked = [r for r in valid if predicate(r) and r["endMs"] >= now - horizon]
    picked.sort(key=lambda r: r["endMs"], reverse=True)
    return picked[:limit]


def is_final(resp):
    return resp.get("final", True)


def estimated_speed(valid, now, agent):
    return (recent(valid, now, lambda r: r["agentId"] == agent["id"], 3, 600_000)
            or recent(valid, now, lambda r: r.get("model") == agent.get("model") and agent.get("model"), 10, 1_800_000)
            or recent(valid, now, lambda r: r["source"] == agent["source"], 10, 1_800_000))


def live_rate(responses, agents, now):
    w0 = now - WINDOW_MS
    valid = [r for r in responses if interval(r) is not None and is_final(r)]
    unmeasured = [r for r in responses if interval(r) is not None and not is_final(r)]
    by_id = {a["id"]: a for a in agents}
    measured = [0.0, 0.0]
    for r in valid:
        s, e = interval(r)
        frac = overlap(w0, now, s, e) / (e - s)
        measured[0] += r["output"] * frac
        measured[1] += (r["output"] + r["input"]) * frac
    estimated = [0.0, 0.0]
    for r in unmeasured:
        agent = by_id.get(r["agentId"], {"id": r["agentId"], "model": r.get("model"), "source": r["source"]})
        sp = estimated_speed(valid, now, agent)
        if sp is None:
            continue
        s, e = interval(r)
        secs = overlap(w0, now, s, e) / 1000
        estimated[0] += sp[0] * secs
        estimated[1] += sp[1] * secs
    for a in agents:
        if a["phase"] != "generating" or a.get("inFlightStartMs") is None or a.get("lastLineMs") is None:
            continue
        if now - a["lastLineMs"] > 300_000:
            continue
        sp = estimated_speed(valid, now, a)
        if sp is None:
            continue
        own_ends = [r["endMs"] for r in responses if r["agentId"] == a["id"]]
        start = max([a["inFlightStartMs"]] + own_ends)
        secs = overlap(w0, now, start, now) / 1000
        estimated[0] += sp[0] * secs
        estimated[1] += sp[1] * secs
    out = (measured[0] + estimated[0]) / (WINDOW_MS / 1000)
    tot = (measured[1] + estimated[1]) / (WINDOW_MS / 1000)
    denom = measured[0] + estimated[0]
    return out, tot, (estimated[0] / denom if denom > 0 else 0.0)


def reference_set(valid, now, agent):
    """The measured responses behind estimatedSpeed (6.2): the first non-empty level of the fallback chain."""
    return (recent_set(valid, now, lambda r: r["agentId"] == agent["id"], 3, 600_000)
            or recent_set(valid, now, lambda r: r.get("model") == agent.get("model") and agent.get("model"), 10,
                          1_800_000)
            or recent_set(valid, now, lambda r: r["source"] == agent["source"], 10, 1_800_000))


def cost_rate(refs):
    """micro-USD per second of the reference responses whose cost is known (9.5), or None."""
    known = [r for r in refs if r.get("costMicroUsd") is not None]
    secs = sum((interval(r)[1] - interval(r)[0]) / 1000 for r in known)
    return sum(r["costMicroUsd"] for r in known) / secs if known and secs > 0 else None


def live_cost(responses, agents, now):
    """(live cost in micro-USD per second, share of live output tokens whose cost is known) - METRICS 9.5."""
    w0 = now - WINDOW_MS
    valid = [r for r in responses if interval(r) is not None and is_final(r)]
    unmeasured = [r for r in responses if interval(r) is not None and not is_final(r)]
    by_id = {a["id"]: a for a in agents}
    cost = known_tokens = all_tokens = 0.0
    for r in valid:
        s, e = interval(r)
        frac = overlap(w0, now, s, e) / (e - s)
        all_tokens += r["output"] * frac
        if r.get("costMicroUsd") is not None:
            cost += r["costMicroUsd"] * frac
            known_tokens += r["output"] * frac
    estimates = []
    for r in unmeasured:
        agent = by_id.get(r["agentId"], {"id": r["agentId"], "model": r.get("model"), "source": r["source"]})
        s, e = interval(r)
        estimates.append((agent, overlap(w0, now, s, e) / 1000))
    for a in agents:
        if a["phase"] != "generating" or a.get("inFlightStartMs") is None or a.get("lastLineMs") is None:
            continue
        if now - a["lastLineMs"] > 300_000:
            continue
        start = max([a["inFlightStartMs"]] + [r["endMs"] for r in responses if r["agentId"] == a["id"]])
        estimates.append((a, overlap(w0, now, start, now) / 1000))
    for agent, secs in estimates:
        refs = reference_set(valid, now, agent)
        if not refs:
            continue
        tokens = speed_of(refs)[0] * secs
        all_tokens += tokens
        rate = cost_rate(refs)
        if rate is not None:
            cost += rate * secs
            known_tokens += tokens
    return cost / (WINDOW_MS / 1000), (known_tokens / all_tokens if all_tokens > 0 else 1.0)


def agent_list(responses, agents, now):
    by_id = {a["id"]: dict(a) for a in agents}
    for a in by_id.values():
        if a["phase"] == "generating" and a.get("lastLineMs") is not None and now - a["lastLineMs"] > 300_000:
            a["phase"] = "idle"
    live = {aid: live_rate([r for r in responses if r["agentId"] == aid], [a], now)[0] for aid, a in by_id.items()}
    chosen = {aid for aid, a in by_id.items()
              if a["phase"] == "generating" or (a.get("lastLineMs") is not None and now - a["lastLineMs"] <= 600_000)}
    for aid in list(chosen):
        cur = by_id[aid].get("parentId")
        while cur in by_id and cur not in chosen:
            chosen.add(cur)
            cur = by_id[cur].get("parentId")
    parent = {aid: (by_id[aid].get("parentId") if by_id[aid].get("parentId") in chosen else None) for aid in chosen}
    children = {}
    for aid in chosen:
        children.setdefault(parent[aid], []).append(aid)

    def members(aid):
        out = [aid]
        for c in children.get(aid, []):
            out += members(c)
        return out

    def last(aid):
        return by_id[aid].get("lastLineMs") or 0

    def sibling_key(aid):
        return (0 if by_id[aid]["phase"] == "generating" else 1, -live[aid], -last(aid), aid)

    def group_key(root):
        m = members(root)
        return (0 if any(by_id[x]["phase"] == "generating" for x in m) else 1, -sum(live[x] for x in m),
                -max(last(x) for x in m), root)

    order = []

    def walk(aid):
        order.append(aid)
        for c in sorted(children.get(aid, []), key=sibling_key):
            walk(c)

    for root in sorted(children.get(None, []), key=group_key):
        walk(root)
    return order, {aid: p for aid, p in parent.items() if p is not None}


def buckets(responses, first, last):
    values = {}
    for r in responses:
        iv = interval(r)
        if iv is None or not is_final(r):
            continue
        s, e = iv
        k = (s // 1000) * 1000
        while k < e:
            if first <= k <= last:
                values[k] = values.get(k, 0.0) + r["output"] * overlap(k, k + 1000, s, e) / (e - s)
            k += 1000
    return values


def today_stats(responses, today_start, now):
    today = [r for r in responses if r["endMs"] >= today_start]
    valid = [r for r in today if interval(r) is not None and is_final(r)]
    sp = speed_of(valid)
    b = buckets(today, today_start, now)
    peak = 0.0
    for k in b:
        peak = max(peak, sum(b.get(k - i * 1000, 0.0) for i in range(3)) / 3)
    return dict(requests=sum(r.get("requestCount", 1) for r in today), output=sum(r["output"] for r in today),
                unfinalized=sum(r.get("requestCount", 1) for r in today if not is_final(r)),
                input=sum(r["input"] for r in today), average=sp[0] if sp else None, peak=peak, buckets=b,
                cost=sum(r["costMicroUsd"] for r in today if r.get("costMicroUsd") is not None),
                unpriced=sum(r.get("requestCount", 1) for r in today if r.get("costMicroUsd") is None))


# ----------------------------------------------------------------------------- commands

def check_fixtures():
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "fixtures")
    expected = json.load(open(os.path.join(root, "parser-expected.json"), encoding="utf-8"))
    dedupe = Deduper()
    failures = []
    states = []
    for rel in expected["order"]:
        exp = expected["files"][rel]
        state = fixture_state(root, rel)
        process_file(state, dedupe)
        states.append(state)
        got = dict(source=state.source, project=state.project, model=state.model, isSubagent=state.is_subagent,
                   phase=state.phase, inFlightStartMs=state.in_flight, lastLineMs=state.last_line,
                   malformedLines=state.malformed, responses=list(state.responses.values()))
        for k, v in exp.items():
            if k != "parentFile" and got[k] != v:
                failures.append("%s: %s expected %r got %r" % (rel, k, v, got[k]))
    oc = expected.get("opencode")
    if oc:
        for st in opencode_states(os.path.join(root, oc["database"]), dedupe):
            exp = oc["agents"].get(st.path)
            if exp is None:
                failures.append("opencode: unexpected agent %s" % st.path)
                continue
            got = dict(source=st.source, project=st.project, model=st.model, isSubagent=st.is_subagent,
                       parentId=st.parent_session, phase=st.phase, inFlightStartMs=st.in_flight,
                       lastLineMs=st.last_line, responses=list(st.responses.values()))
            for k, v in exp.items():
                if got[k] != v:
                    failures.append("%s: %s expected %r got %r" % (st.path, k, v, got[k]))
    parents = resolve_parents(states)
    for rel in expected["order"]:
        parent = parents[os.path.join(root, rel)]
        got = os.path.relpath(parent, root) if parent else None
        if got != expected["files"][rel]["parentFile"]:
            failures.append("%s: parentFile expected %r got %r" % (rel, expected["files"][rel]["parentFile"], got))
    gm = expected.get("gemini")
    if gm:
        groot = os.path.join(root, "gemini", "tmp")
        found = sorted(os.path.relpath(p, root).replace(os.sep, "/") for p in discover_gemini(groot))
        if found != gm["discover"]:
            failures.append("gemini discover: expected %r got %r" % (gm["discover"], found))
        failures += check_traces(root, expected, gm["traces"])
        if gemini_roots({"GEMINI_CLI_HOME": "/x"}, "linux") != [os.path.join("/x", ".gemini", "tmp")]:
            failures.append("gemini roots: GEMINI_CLI_HOME not honoured")
        if len(gemini_roots({"GEMINI_CLI_HOME": "/x"}, "darwin")) != 2:
            failures.append("gemini roots: macOS sandbox root missing")
    om = expected.get("omp")
    if om:
        found = sorted(os.path.relpath(p, root).replace(os.sep, "/")
                       for r in fixture_omp_roots(root) for p in discover_omp(r))
        if found != om["discover"]:
            failures.append("omp discover: expected %r got %r" % (om["discover"], found))
        failures += check_traces(root, expected, om["traces"])
        failures += check_tail_reads(root, expected, om.get("tailReads", []))
        failures += check_omp_roots()
    ag = expected.get("antigravity")
    if ag:
        failures += check_antigravity(root, ag, dedupe)
    wb = expected.get("workbuddy")
    if wb:
        found = sorted(os.path.relpath(p, root).replace(os.sep, "/")
                       for _, r in fixture_wb_roots(root) for p in discover_workbuddy(r))
        if found != wb["discover"]:
            failures.append("workbuddy discover: expected %r got %r" % (wb["discover"], found))
        failures += check_traces(root, expected, wb["traces"])
        failures += check_workbuddy_roots()
    hist_path = os.path.join(root, "history-expected.json")
    if os.path.exists(hist_path):
        hist = json.load(open(hist_path, encoding="utf-8"))
        got = fixture_history(root, expected, hist["prices"])
        want = hist["days"]
        if json.loads(json.dumps(got)) != want:
            failures.append("history: expected %s got %s" % (json.dumps(want)[:300], json.dumps(got)[:300]))
    cases = json.load(open(os.path.join(root, "engine-cases.json"), encoding="utf-8"))["cases"]
    for case in cases:
        for q in case["queries"]:
            out, tot, share = live_rate(case["responses"], case["agents"], q["nowMs"])
            for name, val in (("liveOutput", out), ("liveTotal", tot), ("estimatedShare", share)):
                if abs(val - q[name]) > 1e-6:
                    failures.append("%s @%d: %s expected %r got %r" % (case["name"], q["nowMs"], name, q[name], val))
            if "agentsOrder" in q:
                order, parent_map = agent_list(case["responses"], case["agents"], q["nowMs"])
                if order != q["agentsOrder"] or parent_map != q["agentParents"]:
                    failures.append("%s: agents %r %r" % (case["name"], order, parent_map))
            if "liveCost" in q:
                cost, share = live_cost(case["responses"], case["agents"], q["nowMs"])
                for name, val in (("liveCost", cost), ("liveCostKnownShare", share)):
                    if abs(val - q[name]) > 1e-6:
                        failures.append("%s @%d: %s expected %r got %r" % (case["name"], q["nowMs"], name, q[name],
                                                                           val))
            if "todayCostMicroUsd" in q:
                st = today_stats(case["responses"], case.get("todayStartMs", 0), q["nowMs"])
                for name, val in (("todayCostMicroUsd", st["cost"]), ("todayUnpricedRequests", st["unpriced"])):
                    if val != q[name]:
                        failures.append("%s: %s expected %r got %r" % (case["name"], name, q[name], val))
            for sub in q.get("subsets", []):
                chosen = set(sub["sources"])
                resp = [r for r in case["responses"] if r["source"] in chosen]
                ags = [a for a in case["agents"] if a["source"] in chosen]
                got = (live_rate(resp, ags, q["nowMs"])[0],
                       today_stats(resp, case.get("todayStartMs", 0), q["nowMs"])["peak"],
                       live_cost(resp, ags, q["nowMs"])[0])
                for name, val in zip(("liveOutput", "peakTodayOutput", "liveCost"), got):
                    if name not in sub:
                        continue
                    if abs(val - sub[name]) > 1e-6:
                        failures.append("%s %s: %s expected %r got %r" % (case["name"], sub["sources"], name,
                                                                         sub[name], val))
            if "todayRequests" in q:
                st = today_stats(case["responses"], case.get("todayStartMs", 0), q["nowMs"])
                checks = (("todayRequests", st["requests"]), ("todayOutput", st["output"]),
                          ("todayInput", st["input"]), ("averageToday", st["average"]),
                          ("peakTodayOutput", st["peak"]), ("todayUnfinalized", st["unfinalized"]))
                for name, val in checks:
                    if abs((val or 0) - q[name]) > 1e-6:
                        failures.append("%s: %s expected %r got %r" % (case["name"], name, q[name], val))
                for k, v in q["historyMeasuredOutput"].items():
                    if abs(st["buckets"].get(int(k), 0.0) - v) > 1e-6:
                        failures.append("%s: bucket %s expected %r got %r" % (case["name"], k, v,
                                                                              st["buckets"].get(int(k))))
    failures += ["prices: " + e for e in pricing.check_cases()]
    failures += ["harnesses: " + e for e in harnesses.check_fixtures(root)]
    if failures:
        print("\n".join(failures))
        sys.exit(1)
    print("reference implementation matches all fixtures (%d files, %d Antigravity databases, %d engine cases, "
          "price cases)" % (len(expected["order"]), len((ag or {}).get("order", [])), len(cases)))


def check_traces(root, expected, traces):
    """Phase after feeding a file up to a physical line, after the files before it in `order`."""
    failures = []
    for t in traces:
        trace_dedupe = Deduper()
        for rel in expected["order"]:
            if rel == t["file"]:
                break
            process_file(fixture_state(root, rel), trace_dedupe)
        state = fixture_state(root, t["file"])
        process_file(state, trace_dedupe, max_lines=t["afterLine"])
        if (state.phase, state.in_flight) != (t["phase"], t["inFlightStartMs"]):
            failures.append("%s line %d: expected %s/%r got %s/%r" % (
                t["file"], t["afterLine"], t["phase"], t["inFlightStartMs"], state.phase, state.in_flight))
    return failures


def check_tail_reads(root, expected, reads):
    """Files that start being read at a byte offset (an older file that grows): the header is read first."""
    failures = []
    for t in reads:
        tail_dedupe = Deduper()
        for rel in expected["order"]:
            if rel == t["file"]:
                break
            process_file(fixture_state(root, rel), tail_dedupe)
        state = fixture_state(root, t["file"])
        process_file(state, tail_dedupe, start_offset=t["offset"])
        got = dict(project=state.project, phase=state.phase, inFlightStartMs=state.in_flight,
                   lastLineMs=state.last_line, responseKeys=list(state.responses))
        for k, v in got.items():
            if t[k] != v:
                failures.append("%s from byte %d: %s expected %r got %r" % (t["file"], t["offset"], k, t[k], v))
    return failures


def check_omp_roots():
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        home, xdg = os.path.join(tmp, "home"), os.path.join(tmp, "xdg")
        for d in (".omp/profiles/work", ".omp/profiles/play", ".pi-alt/profiles/solo"):
            os.makedirs(os.path.join(home, d))
        for d in ("omp/profiles/work", "omp/profiles/lab"):
            os.makedirs(os.path.join(xdg, d))
        h, x = os.path.join(home, ".omp"), os.path.join(xdg, "omp")
        cases = [
            ({}, "linux", [h + "/agent/sessions", h + "/profiles/play/agent/sessions", h + "/profiles/work/agent/sessions"]),
            ({"PI_CODING_AGENT_DIR": "/agent"}, "win32",
             ["/agent/sessions", h + "/profiles/play/agent/sessions", h + "/profiles/work/agent/sessions"]),
            ({"PI_CONFIG_DIR": ".pi-alt"}, "linux",
             [home + "/.pi-alt/agent/sessions", home + "/.pi-alt/profiles/solo/agent/sessions"]),
            ({"XDG_DATA_HOME": xdg}, "darwin",
             [x + "/sessions", x + "/profiles/lab/sessions", h + "/profiles/play/agent/sessions",
              x + "/profiles/work/sessions"]),
            ({"XDG_DATA_HOME": xdg}, "win32",
             [h + "/agent/sessions", h + "/profiles/play/agent/sessions", h + "/profiles/work/agent/sessions"]),
        ]
        for env, platform, want in cases:
            got = omp_roots(env, platform, home)
            if [os.path.normpath(p) for p in got] != [os.path.normpath(p) for p in want]:
                failures.append("omp roots %r %s: expected %r got %r" % (env, platform, want, got))
    return failures


def check_antigravity(root, ag, dedupe):
    failures = []
    tree = os.path.join(root, "antigravity")
    before = sorted(os.path.relpath(os.path.join(d, n), tree) for d, _, ns in os.walk(tree) for n in ns)
    stores = antigravity_stores(gemini_dir=tree)
    found = sorted(os.path.relpath(p, root).replace(os.sep, "/") for s in stores for p in discover_antigravity(s))
    if found != ag["discover"]:
        failures.append("antigravity discover: expected %r got %r" % (ag["discover"], found))
    backup = os.path.join(tree, "antigravity-backup")
    if antigravity_stores(setting=backup) or antigravity_stores(setting=os.path.join(backup, "conversations")):
        failures.append("antigravity: a -backup store chosen in the setting must not be read")
    for store in stores:
        via_folder = [p for s in antigravity_stores(setting=os.path.join(store, "conversations"))
                      for p in discover_antigravity(s)]
        if sorted(via_folder) != sorted(discover_antigravity(store)):
            failures.append("antigravity: a `conversations` folder chosen in the setting must be used directly")
    states = []
    for rel in ag["order"]:
        exp = ag["databases"][rel]
        st = antigravity_state(os.path.join(root, rel), dedupe)
        if st is None:
            if exp != {"unsupported": True}:
                failures.append("%s: unexpectedly unsupported" % rel)
            continue
        if exp.get("unsupported"):
            failures.append("%s: expected unsupported" % rel)
            continue
        states.append(st)
        got = dict(source=st.source, project=st.project, model=st.model, isSubagent=st.is_subagent,
                   phase=st.phase, inFlightStartMs=st.in_flight, lastLineMs=st.last_line, malformedLines=st.malformed,
                   responses=list(st.responses.values()))
        for k, v in exp.items():
            if k != "parentFile" and got[k] != v:
                failures.append("%s: %s expected %r got %r" % (rel, k, v, got[k]))
    parents = antigravity_parents(states)
    for st in states:
        rel = os.path.relpath(st.path, root).replace(os.sep, "/")
        got = os.path.relpath(parents[st.path], root).replace(os.sep, "/") if parents[st.path] else None
        if got != ag["databases"][rel]["parentFile"]:
            failures.append("%s: parentFile expected %r got %r" % (rel, ag["databases"][rel]["parentFile"], got))
    after = sorted(os.path.relpath(os.path.join(d, n), tree) for d, _, ns in os.walk(tree) for n in ns)
    if after != before:
        failures.append("antigravity: reading created files %r" % sorted(set(after) - set(before)))
    return failures


def check_workbuddy_roots():
    """Both data folders under the home folder; a setting names a data folder or its `projects` folder."""
    failures = []
    home = os.path.join(os.sep, "home", "dev")
    cases = [
        ({}, [("workbuddy", os.path.join(home, ".workbuddy", "projects")),
              ("workbuddyAi", os.path.join(home, ".workbuddy-ai", "projects"))]),
        ({"workbuddy": "/data/wb/", "workbuddyAi": "/data/wb-ai/projects"},
         [("workbuddy", "/data/wb/projects"), ("workbuddyAi", "/data/wb-ai/projects")]),
    ]
    for settings, want in cases:
        got = workbuddy_roots(home, settings)
        if [(s, os.path.normpath(p)) for s, p in got] != [(s, os.path.normpath(p)) for s, p in want]:
            failures.append("workbuddy roots %r: expected %r got %r" % (settings, want, got))
    return failures


def fixture_wb_roots(root):
    """The fixture folder `workbuddy` plays the home folder of both WorkBuddy editions."""
    return workbuddy_roots(os.path.join(root, "workbuddy"))


def fixture_source(rel):
    for prefix, source in (("codex/", "codex"), ("dsh/", "deepseek"), ("gemini/", "gemini"), ("omp/", "omp"),
                           ("workbuddy/.workbuddy/", "workbuddy"), ("workbuddy/.workbuddy-ai/", "workbuddyAi")):
        if rel.startswith(prefix):
            return source
    return "claudeCode"


def fixture_omp_roots(root):
    """The fixture folder `omp` plays `~/.omp`: its automatic roots are the default root and every profile."""
    return omp_roots({"PI_CONFIG_DIR": "omp"}, "linux", root)


def fixture_state(root, rel):
    path = os.path.join(root, rel)
    source = fixture_source(rel)
    if source in WB_FOLDERS:
        return FileState(path, source, next((r for _, r in fixture_wb_roots(root) if path.startswith(r + os.sep)), None))
    omp_root = next((r for r in fixture_omp_roots(root) if path.startswith(r + os.sep)), None)
    return FileState(path, source, omp_root if source == "omp" else None)


HISTORY_PRICES = OrderedDict([("tables", ["prices/v1.json", "prices/v2.json"]), ("bindings", {"2026-10-20": 1})])


def fixture_pricing(root, config):
    """The fixture price tables of history-expected.json `prices`; the newest table is the current one."""
    return pricing.DayPricing([pricing.load(os.path.join(root, rel)) for rel in config["tables"]], config["bindings"])


def fixture_history(root, expected, config=HISTORY_PRICES):
    """Daily history over a copy of the fixtures whose modification times follow `mtimes` (git does not keep them)."""
    with tempfile.TemporaryDirectory() as tmp:
        copy = os.path.join(tmp, "fixtures")
        shutil.copytree(root, copy)
        for rel, ms in expected.get("mtimes", {}).items():
            os.utime(os.path.join(copy, rel), (ms / 1000, ms / 1000))
        return daily_history(collect_all(os.path.join(copy, "codex", "sessions"), os.path.join(copy, "claude", "projects"),
                                         os.path.join(copy, "dsh", "sessions"), os.path.join(copy, "opencode", "opencode.db"),
                                         [os.path.join(copy, "gemini", "tmp")], fixture_omp_roots(copy),
                                         antigravity_stores(gemini_dir=os.path.join(copy, "antigravity")),
                                         fixture_wb_roots(copy)),
                             tz=timezone.utc, day_pricing=fixture_pricing(root, config))


def write_history_fixture():
    root = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "fixtures"))
    expected = json.load(open(os.path.join(root, "parser-expected.json"), encoding="utf-8"))
    with open(os.path.join(root, "history-expected.json"), "w", encoding="utf-8") as f:
        json.dump({"_comment": "Daily history (METRICS 8, 9.7) over all fixtures, grouped in UTC, after setting each "
                               "file's modification time from parser-expected.json `mtimes`. Costs use the fixture "
                               "price tables in `prices.tables` (paths relative to spec/fixtures; the highest version "
                               "is the current table) with the stored day bindings `prices.bindings`; unbound days "
                               "bind to the current table. Generated by spec/tools/reference.py "
                               "--write-history-fixture; platforms must match exactly.",
                   "prices": HISTORY_PRICES,
                   "days": fixture_history(root, expected)}, f, indent=2, ensure_ascii=False)
        f.write("\n")


DSH_NAME = re.compile(r"^session\.v\d+\.jsonl(\.zstd)?$")


def discover(root, limit=20_000, deepseek=False, codex=False):
    found = []
    if not os.path.isdir(root):
        return found
    base_depth = root.rstrip(os.sep).count(os.sep)
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        if dirpath.count(os.sep) - base_depth >= 6:
            dirnames[:] = []
        dirnames[:] = [d for d in dirnames if not os.path.islink(os.path.join(dirpath, d))]
        for name in filenames:
            path = os.path.join(dirpath, name)
            wanted = DSH_NAME.match(name) if deepseek else name.endswith((".jsonl", ".jsonl.zst") if codex else ".jsonl")
            if wanted and not os.path.islink(path):
                found.append(path)
    found.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return found[:limit]


def startup_files(codex_root, claude_root, dsh_root, gemini_dirs=(), omp_dirs=(), ag_stores=(), wb_roots=(),
                  limit=20_000, include_archived=False):
    """(time, path, source, root) of every discovered file and Antigravity database, in startup order (5); the root
    (omp root or WorkBuddy `projects`) decides sub-agents by folder structure."""
    files = [(p, "codex", None) for p in discover(codex_root, limit=limit, codex=True)]
    if include_archived:
        archived = os.path.join(os.path.dirname(codex_root.rstrip(os.sep)), "archived_sessions")
        files += [(p, "codex", None) for p in discover(archived, limit=limit, codex=True)]
    files += [(p, "claudeCode", None) for p in discover(claude_root, limit=limit)]
    files += [(p, "deepseek", None) for p in discover(dsh_root, limit=limit, deepseek=True)]
    files += [(p, "gemini", None) for d in gemini_dirs for p in discover_gemini(d, limit=limit)]
    files += [(p, "omp", r) for r in OrderedDict.fromkeys(omp_dirs) for p in discover_omp(r, limit=limit)]
    files += [(p, "antigravity", None) for s in ag_stores for p in discover_antigravity(s, limit=limit)]
    files += [(p, s, r) for s, r in wb_roots for p in discover_workbuddy(r, limit=limit)]
    timed = {(ag_mtime(p) if s == "antigravity" else os.path.getmtime(p), p, s, r) for p, s, r in files}
    return sorted(timed, key=lambda t: (t[0], t[1]))


def dump_today(codex_root, claude_root, dsh_root, gemini_dirs=(), omp_dirs=(), ag_stores=(), wb_roots=(),
               table=pricing.TABLE, zcode_root=None, kimi_root=None, grok_root=None):
    started = time.time()
    index = pricing.Index(pricing.load(table))
    now = datetime.now().astimezone()
    today_start = int(now.replace(hour=0, minute=0, second=0, microsecond=0).timestamp() * 1000)
    files = startup_files(codex_root, claude_root, dsh_root, gemini_dirs, omp_dirs, ag_stores, wb_roots)
    dedupe = Deduper()
    rows, read_files, read_bytes = [], 0, 0
    for mtime, path, source, root in files:
        if mtime * 1000 < today_start - 15 * 60_000:
            continue
        size = os.path.getsize(path)
        if size > 256 * 1024 * 1024 and path.endswith(".zstd"):
            continue
        if source == "gemini" and path.endswith(".json") and size > GEMINI_LEGACY_MAX:
            continue
        if source == "antigravity":
            state = antigravity_state(path, dedupe)
            if state is None:
                continue
            offset = 0
        else:
            offset = size - 64 * 1024 * 1024 if size > 256 * 1024 * 1024 and not path.endswith(".jsonl.zst") else 0
            state = FileState(path, source, root)
            process_file(state, dedupe, offset)
        read_files += 1
        read_bytes += size - offset
        for r in state.responses.values():
            if r["endMs"] >= today_start:
                rows.append(OrderedDict([("key", r["key"]), ("source", state.source), ("agentId", path),
                                         ("model", r["model"]), ("startMs", r["startMs"]), ("endMs", r["endMs"]),
                                         ("input", r["input"]), ("cachedInput", r["cachedInput"]),
                                         ("cacheWriteInput", r["cacheWriteInput"]),
                                         ("cacheWrite1hInput", r["cacheWrite1hInput"]), ("output", r["output"]),
                                         ("reasoning", r["reasoning"]), ("final", r["final"]),
                                         ("provider", r["provider"]), ("fast", r["fast"]),
                                         ("costMicroUsd", index.price(r) if has_day(r["endMs"]) else None)]))
    for source, agent, record in harnesses.collect(zcode_root, kimi_root, grok_root):
        if record["endMs"] >= today_start:
            rows.append(dict(record, source=source, agentId=agent,
                             costMicroUsd=index.price(record) if has_day(record["endMs"]) else None))
    rows.sort(key=lambda r: (r["endMs"], r["key"]))
    for r in rows:
        print(json.dumps(r, ensure_ascii=False, separators=(",", ":")))
    counts = {}
    for r in rows:
        counts[r["source"]] = counts.get(r["source"], 0) + 1
    print(json.dumps({"summary": {"counts": counts, "output": sum(r["output"] for r in rows),
                                  "costMicroUsd": sum(r["costMicroUsd"] or 0 for r in rows),
                                  "unpricedRequests": sum(r.get("requestCount", 1) for r in rows if r["costMicroUsd"] is None),
                                  "input": sum(r["input"] for r in rows), "filesRead": read_files,
                                  "bytesRead": read_bytes, "seedMs": int((time.time() - started) * 1000)}}))


def collect_all(codex_root, claude_root, dsh_root, opencode_db, gemini_dirs=(), omp_dirs=(), ag_stores=(),
                wb_roots=(), include_archived=True, zcode_root=None, kimi_root=None, grok_root=None):
    """Parses every log completely (METRICS 8) and returns all responses with their source and agent."""
    files = startup_files(codex_root, claude_root, dsh_root, gemini_dirs, omp_dirs, ag_stores, wb_roots,
                          limit=10 ** 9, include_archived=include_archived)
    dedupe = Deduper(limit=10 ** 9)
    out = []
    for _, path, source, root in files:
        if source == "antigravity":
            state = antigravity_state(path, dedupe)
            if state is None:
                continue
        else:
            state = FileState(path, source, root)
            process_file(state, dedupe)
        out += [(state.source, path, r) for r in state.responses.values()]
    if opencode_db and os.path.exists(opencode_db):
        for st in opencode_states(opencode_db, dedupe):
            out += [(st.source, st.path, r) for r in st.responses.values()]
    out += harnesses.collect(zcode_root, kimi_root, grok_root)
    return out


HISTORY_TOKENS = ("input", "cachedInput", "cacheWriteInput", "output", "reasoning")


def daily_history(responses, tz=None, day_pricing=None):
    """Rows per (date, source), METRICS 8 and 9.7. `day_pricing` defaults to the bundled table for every day."""
    day_pricing = day_pricing or pricing.DayPricing([pricing.load(pricing.TABLE)])
    days = {}
    for source, agent, r in responses:
        if not has_day(r["endMs"]):
            continue
        date = datetime.fromtimestamp(r["endMs"] / 1000, tz=tz or datetime.now().astimezone().tzinfo)
        key = (date.strftime("%Y-%m-%d") if tz else datetime.fromtimestamp(r["endMs"] / 1000).strftime("%Y-%m-%d"),
               source)
        d = days.setdefault(key, dict(requests=0, input=0, cachedInput=0, cacheWriteInput=0, output=0, reasoning=0,
                                      measuredOutput=0, measuredMs=0, unfinalized=0, costMicroUsd=0,
                                      unpricedRequests=0, agents=set(), models={}))
        requests = r.get("requestCount", 1)
        d["requests"] += requests
        for f in HISTORY_TOKENS:
            d[f] += r[f]
        iv = interval(r)
        m = d["models"].setdefault(r.get("model") or "", [0, 0, 0, 0, 0, 0])
        m[0] += requests
        m[1] += r["output"]
        if iv is not None and is_final(r):
            d["measuredOutput"] += r["output"]
            d["measuredMs"] += iv[1] - iv[0]
            m[2] += r["output"]
            m[3] += iv[1] - iv[0]
        if not is_final(r):
            d["unfinalized"] += requests
        cost = day_pricing.price(key[0], r)
        if cost is None:
            d["unpricedRequests"] += requests
            m[5] += requests
        else:
            d["costMicroUsd"] += cost
            m[4] += cost
        d["agents"].add(agent)
    rows = []
    for (date, source), d in sorted(days.items()):
        rows.append(OrderedDict([("date", date), ("source", source)] + [(k, d[k]) for k in (
            "requests", "input", "cachedInput", "cacheWriteInput", "output", "reasoning", "measuredOutput",
            "measuredMs", "unfinalized", "costMicroUsd", "unpricedRequests")] + [
            ("priceVersion", day_pricing.version_for(date)), ("agents", len(d["agents"])),
            ("models", {k: {"requests": v[0], "output": v[1], "measuredOutput": v[2], "measuredMs": v[3],
                            "costMicroUsd": v[4], "unpricedRequests": v[5]}
                        for k, v in sorted(d["models"].items())})]))
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check-fixtures", action="store_true")
    parser.add_argument("--dump-today", action="store_true")
    parser.add_argument("--dump-history", action="store_true")
    parser.add_argument("--opencode", default=None)
    parser.add_argument("--utc", action="store_true", help="group days in UTC instead of local time")
    parser.add_argument("--codex", default=None)
    parser.add_argument("--claude", default=None)
    parser.add_argument("--dsh", default=None)
    parser.add_argument("--zcode", default=None, help="ZCode data folder, database folder, or db.sqlite")
    parser.add_argument("--kimi", default=None, help="Kimi Code CLI sessions folder")
    parser.add_argument("--grok", default=None, help="Grok Build sessions folder")
    parser.add_argument("--gemini", action="append", default=None, help="Gemini CLI tmp folder (repeatable)")
    parser.add_argument("--omp", action="append", default=None, help="omp sessions folder (repeatable)")
    parser.add_argument("--antigravity", action="append", default=None,
                        help="Antigravity store folder or its conversations folder (repeatable)")
    parser.add_argument("--workbuddy", default=None, help="WorkBuddy data folder (~/.workbuddy) or its projects folder")
    parser.add_argument("--workbuddy-ai", default=None,
                        help="WorkBuddy AI data folder (~/.workbuddy-ai) or its projects folder")
    parser.add_argument("--write-history-fixture", action="store_true")
    parser.add_argument("--prices", default=pricing.TABLE, help="price table for --dump-history (METRICS 9)")
    args = parser.parse_args()
    home = os.path.expanduser("~")
    codex_root = args.codex or (os.path.join(os.environ["CODEX_HOME"], "sessions") if os.environ.get("CODEX_HOME")
                                else os.path.join(home, ".codex", "sessions"))
    claude_root = args.claude or (os.path.join(os.environ["CLAUDE_CONFIG_DIR"], "projects")
                                  if os.environ.get("CLAUDE_CONFIG_DIR") else os.path.join(home, ".claude", "projects"))
    dsh_root = args.dsh or (os.path.join(os.environ["DSH_HOME"], "sessions") if os.environ.get("DSH_HOME")
                            else os.path.join(home, ".dsh", "sessions"))
    opencode_db = args.opencode or os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.join(home, ".local", "share"),
                                                "opencode", "opencode.db")
    gemini_dirs = args.gemini or gemini_roots()
    omp_dirs = args.omp or omp_roots()
    ag_stores = ([s for a in args.antigravity for s in antigravity_stores(setting=a)] if args.antigravity
                 else antigravity_stores())
    wb_roots = workbuddy_roots(settings={"workbuddy": args.workbuddy, "workbuddyAi": args.workbuddy_ai})
    zcode_root = args.zcode or os.path.join(os.environ.get("ZCODE_DATA_BASE_DIR") or home, ".zcode", "cli", "db")
    kimi_root = args.kimi or os.path.join(os.environ.get("KIMI_CODE_HOME") or os.path.join(home, ".kimi-code"), "sessions")
    grok_root = args.grok or os.path.join(os.environ.get("GROK_HOME") or os.path.join(home, ".grok"), "sessions")
    if args.write_history_fixture:
        write_history_fixture()
        return
    if args.dump_history:
        rows = daily_history(collect_all(codex_root, claude_root, dsh_root, opencode_db, gemini_dirs, omp_dirs,
                                         ag_stores, wb_roots, zcode_root=zcode_root, kimi_root=kimi_root,
                                         grok_root=grok_root), tz=timezone.utc if args.utc else None,
                             day_pricing=pricing.DayPricing([pricing.load(args.prices)]))
        for row in rows:
            print(json.dumps(row, ensure_ascii=False, separators=(",", ":")))
        return
    if args.check_fixtures:
        check_fixtures()
    elif args.dump_today:
        dump_today(codex_root, claude_root, dsh_root, gemini_dirs, omp_dirs, ag_stores, wb_roots, args.prices,
                   zcode_root, kimi_root, grok_root)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
