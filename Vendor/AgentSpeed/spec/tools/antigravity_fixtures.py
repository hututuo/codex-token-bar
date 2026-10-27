#!/usr/bin/env python3
"""Antigravity conversation database fixtures (METRICS 4.8), used by generate_fixtures.py.

  python3 spec/tools/antigravity_fixtures.py OUT_DIR

Databases are written under OUT_DIR/antigravity/, which plays the role of `~/.gemini`: the stores
`antigravity-cli`, `antigravity` and `antigravity-ide` each hold `conversations/<uuid>.db`, plus decoys that discovery
must ignore (a `-backup` store, `.pb` files, sidecars, a summaries database, a non-UUID database, a nested folder).
Every blob is protobuf built by the small encoder below, with field numbers from the agy 1.4.4 descriptors and
realistic unknown fields that readers must skip. Expected values are written by hand, independently of reference.py.
"""
import hashlib
import json
import os
import shutil
import sqlite3
import struct
import sys
from datetime import datetime, timezone

DAY = "2026-10-21"

SCHEMA = """PRAGMA user_version=1;
CREATE TABLE trajectory_meta(trajectory_id TEXT,cascade_id TEXT,trajectory_type INTEGER,source INTEGER);
CREATE TABLE steps(idx INTEGER,step_type INTEGER,status INTEGER,has_subtrajectory INTEGER,metadata BLOB,error_details BLOB,permissions BLOB,task_details BLOB,render_info BLOB,step_payload BLOB,step_format INTEGER);
CREATE TABLE gen_metadata(idx INTEGER,data BLOB,size INTEGER);
CREATE TABLE executor_metadata(idx INTEGER,data BLOB);
CREATE TABLE parent_references(idx INTEGER,data BLOB);
CREATE TABLE trajectory_metadata_blob(id TEXT,data BLOB);
CREATE TABLE battle_mode_infos(idx INTEGER,data BLOB);
"""

# Step types and statuses (cortex.proto CortexStepType / CortexStepStatus).
VIEW_FILE, LIST_DIRECTORY, USER_INPUT, PLANNER_RESPONSE, RUN_COMMAND, CHECKPOINT, INVOKE_SUBAGENT = 8, 9, 14, 15, 21, 23, 127
RUNNING, DONE, CANCELED, ERROR, GENERATING, INTERRUPTED = 2, 3, 6, 7, 8, 12
SOURCE_APP, SOURCE_CLI = 1, 17

MAIN = "3f6c2a10-8b4d-4e5f-9a1b-2c3d4e5f6a7b"
SUB = "9b1e7d42-6c5a-4f3e-8d2b-1a0f9e8d7c6b"
UNSUPPORTED = "0d4f6e8a-2b1c-4d3e-9f5a-6b7c8d9e0f1a"
INFLIGHT = "5e2d1c0b-9a8f-4e7d-8c6b-5a4f3e2d1c0b"
BROWSER = "c7a9e1f3-5b2d-4c6e-8a0b-2d4f6a8c0e1f"
FORK = "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"
NESTED = "E4D3C2B1-A0F9-4E8D-B7C6-A5F4E3D2C1B0"
IMAGE = "7c8d9e0f-1a2b-4c3d-9e4f-5a6b7c8d9e0f"
IDE_SUB = "2c4e6a8b-0d1f-4a3c-9e5b-7d9f1b3d5f7a"
CANCELLED = "6d8f0a2c-4e6b-4d8f-a0c2-e4f6a8b0c2d4"


def conv(store, conversation):
    return "antigravity/%s/conversations/%s.db" % (store, conversation)


MAIN_DB, SUB_DB, UNSUPPORTED_DB = conv("antigravity-cli", MAIN), conv("antigravity-cli", SUB), conv("antigravity-cli", UNSUPPORTED)
INFLIGHT_DB, BROWSER_DB, FORK_DB = conv("antigravity", INFLIGHT), conv("antigravity", BROWSER), conv("antigravity", FORK)
NESTED_DB, IMAGE_DB, COPY_DB = conv("antigravity-ide", NESTED), conv("antigravity-ide", IMAGE), conv("antigravity-ide", MAIN)
IDE_SUB_DB, CANCELLED_DB = conv("antigravity-ide", IDE_SUB), conv("antigravity", CANCELLED)
BACKUP_DB = conv("antigravity-backup", MAIN)


def ms(clock):
    dt = datetime.strptime("%s %s" % (DAY, clock), "%Y-%m-%d %H:%M:%S.%f").replace(tzinfo=timezone.utc)
    return int(dt.timestamp() * 1000)


# ---------------------------------------------------------------------------- protobuf encoder

def varint(n):
    if n < 0:
        n += 1 << 64  # negative int32/int64: ten-byte two's complement
    out = bytearray()
    while True:
        byte = n & 0x7F
        n >>= 7
        if n:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def key(field, wire):
    return varint(field << 3 | wire)


def pb_int(field, n):
    return key(field, 0) + varint(n) if n else b""


def pb_bytes(field, data):
    return key(field, 2) + varint(len(data)) + data


def pb_str(field, text):
    return pb_bytes(field, text.encode("utf-8")) if text else b""


def pb_msg(field, *parts):
    return pb_bytes(field, b"".join(parts))


def pb_float(field, value):
    return key(field, 5) + struct.pack("<f", value)


def pb_fixed64(field, value):
    return key(field, 1) + struct.pack("<Q", value)


def pb_packed(field, values):
    return pb_bytes(field, b"".join(varint(v) for v in values))


INVALID = object()  # a Timestamp message that is present but empty (seconds 0): not valid


def stamp(field, clock, extra_nanos=0, nanos=None):
    """A google.protobuf.Timestamp; sub-millisecond nanos must be floored away by readers."""
    if clock is INVALID:
        return pb_msg(field)
    value = ms(clock)
    if nanos is None:
        nanos = (value % 1000) * 1_000_000 + extra_nanos
    return pb_msg(field, pb_int(1, value // 1000), pb_int(2, nanos))


def duration(field, millis):
    return pb_msg(field, pb_int(1, millis // 1000), pb_int(2, (millis % 1000) * 1_000_000))


def usage(inp=0, out=0, cache=0, thinking=0, response=0, response_id=None, message_id=None):
    """ModelUsageStats with the unknown fields a real row carries (model enum, provider, response header)."""
    return b"".join([
        pb_int(1, 1026), pb_int(2, inp), pb_int(3, out), pb_int(5, cache), pb_int(6, 24), pb_str(7, message_id or ""),
        pb_msg(8, pb_str(1, "sessionID"), pb_str(2, "f00dfeed")), pb_int(9, thinking), pb_int(10, response),
        pb_str(11, response_id or ""), pb_str(13, "standard"),
    ])


def meta(created=None, viewable=None, finished=None, completed=None, model_usage=None, last_chunk=None, started=None,
         source=2, tool=None, extra=b""):
    """CortexStepMetadata. Unknown fields: source 3, tool_call 4, model_cost 10, execution_id 12, version 21."""
    parts = []
    if created is not None:
        parts.append(stamp(1, created, 123_456))
    parts.append(pb_int(3, source))
    if tool:
        parts.append(pb_msg(4, pb_str(1, tool[0]), pb_str(2, tool[1]), pb_str(3, '{"path":"src/main.ts"}')))
    for field, clock in ((6, viewable), (7, finished), (8, completed)):
        if clock is not None:
            parts.append(stamp(field, clock, 987_654))
    if model_usage is not None:
        parts.append(pb_msg(9, model_usage))
        parts.append(pb_float(10, 0.0125))
    parts.append(pb_str(12, "exec-7f21"))
    parts.append(pb_int(21, 1))
    if last_chunk is not None:
        parts.append(stamp(22, last_chunk, 5_000))
    if started is not None:
        parts.append(stamp(32, started, 1))
    return b"".join(parts) + extra


def trajectory(created, uris=(), workspace=None, parent=None, nesting=0, subagent=None, root=None):
    """CortexTrajectoryMetadata. Unknown fields: root_conversation_id 6, mendel_experiment_ids 15 (packed)."""
    parts = []
    if workspace:
        parts.append(pb_msg(1, pb_str(1, workspace), pb_str(2, workspace)))
    parts.append(stamp(2, created))
    parts.append(pb_str(5, parent or ""))
    parts.append(pb_str(6, root or ""))
    parts += [pb_str(7, uri) for uri in uris]
    if subagent:
        parts.append(pb_msg(8, pb_str(1, subagent[0]), pb_str(2, subagent[1]), pb_str(3, "(prompt omitted)")))
    parts.append(pb_packed(15, [101, 202, 30303]))
    parts.append(pb_int(17, nesting))
    return b"".join(parts)


def generation(steps, response_model=None, display=None, packed=True, ttft=700, streaming=2500):
    """CortexStepGeneratorMetadata with its ChatModelMetadata (system prompt, model enum and durations unused)."""
    chat = b"".join([
        pb_str(1, "(system prompt omitted)"), pb_int(3, 1026), pb_msg(4, usage(inp=1, out=1)), pb_float(5, 0.01),
        duration(11, ttft), duration(12, streaming), pb_int(14, 0), pb_str(19, response_model or ""),
        pb_str(21, display or ""),
    ])
    indices = pb_packed(2, steps) if packed else b"".join(pb_int(2, s) if s else key(2, 0) + b"\x00" for s in steps)
    return pb_msg(1, chat) + indices + pb_str(4, "exec-7f21")


def executor(reason, last_step, model_name):
    """ExecutorMetadata: termination_reason 1, last_step_idx 3, cascade_config 10 -> planner_config 1 -> model_name 28."""
    planner = pb_int(1, 1026) + pb_str(28, model_name)
    return b"".join([pb_int(1, reason), pb_int(2, 4), key(3, 0) + varint(last_step), pb_str(9, "exec-7f21"),
                     pb_msg(10, pb_msg(1, planner))])


PAYLOAD = pb_str(1, "(content omitted)")


# ---------------------------------------------------------------------------- database writer

class Conversation:
    def __init__(self, conversation_id, source, trajectory_blob):
        self.id = conversation_id
        self.source = source
        self.trajectory = trajectory_blob
        self.steps, self.generations, self.executors = [], [], []

    def step(self, step_type, status, metadata):
        self.steps.append((len(self.steps), step_type, status, metadata))
        return self

    def write(self, path, wal=True):
        db = sqlite3.connect(path)
        db.execute("PRAGMA page_size=1024")  # keeps the fixtures small; agy itself uses the default 4096
        if wal:
            db.execute("PRAGMA journal_mode=WAL")
        db.executescript(SCHEMA)
        db.execute("INSERT INTO trajectory_meta VALUES (?,?,?,?)", ("traj-" + self.id[:8], self.id, 1, self.source))
        db.execute("INSERT INTO trajectory_metadata_blob VALUES (?,?)", (self.id, self.trajectory))
        for idx, step_type, status, metadata in self.steps:
            db.execute("INSERT INTO steps VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                       (idx, step_type, status, 1 if step_type == INVOKE_SUBAGENT else 0, metadata, None, None, None,
                        None, PAYLOAD, 1))
        for idx, (data, size) in enumerate(self.generations):
            db.execute("INSERT INTO gen_metadata VALUES (?,?,?)", (idx, data, len(data) if size is None else size))
        for idx, data in enumerate(self.executors):
            db.execute("INSERT INTO executor_metadata VALUES (?,?)", (idx, data))
        db.commit()
        close_cleanly(db, path)
        with open(path, "rb") as f:
            header = f.read(20)
        assert (header[18], header[19]) == ((2, 2) if wal else (1, 1)), path


def close_cleanly(db, path):
    """Close like an exiting language server: everything checkpointed, no -wal or -shm left behind.

    Apple's system SQLite keeps an empty -wal and the -shm after the last connection closes (persistent WAL); both are
    removed once the checkpoint has emptied the WAL.
    """
    db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    db.close()
    if os.path.exists(path + "-wal"):
        assert os.path.getsize(path + "-wal") == 0, path
        os.remove(path + "-wal")
    if os.path.exists(path + "-shm"):
        os.remove(path + "-shm")


def tiny_db(path, statements):
    db = sqlite3.connect(path)
    db.executescript(statements)
    db.commit()
    close_cleanly(db, path)


def resp(key_, start, end, inp, cached, out, reasoning, model):
    return {"key": key_, "startMs": None if start is None else ms(start), "endMs": ms(end), "input": inp,
            "cachedInput": cached, "cacheWriteInput": 0, "cacheWrite1hInput": 0, "output": out,
            "reasoning": reasoning, "model": model, "provider": None, "fast": False,
            "final": True}


def expect(project, model, sub, parent, phase, in_flight, last, malformed, responses):
    return {"source": "antigravity", "project": project, "model": model, "isSubagent": sub, "parentFile": parent,
            "phase": phase, "inFlightStartMs": None if in_flight is None else ms(in_flight), "lastLineMs": ms(last),
            "malformedLines": malformed, "responses": responses}


# ---------------------------------------------------------------------------- conversations

def main_conversation():
    """CLI: a finished tool-using turn; the executor ended it after a trailing checkpoint step."""
    c = Conversation(MAIN, SOURCE_CLI, trajectory(
        "09:00:00.000", uris=["file:///Users/dev/projects/star%20map"],
        workspace="file:///Users/dev/projects/old-name", root=MAIN))
    c.step(USER_INPUT, DONE, meta("09:00:01.000", viewable="09:00:01.005", completed="09:00:01.010", source=4))
    c.step(PLANNER_RESPONSE, DONE, meta(
        "09:00:01.050", viewable="09:00:01.800", last_chunk="09:00:04.200", finished="09:00:04.250",
        completed="09:00:04.300", tool=("call-a1", "run_command"),
        model_usage=usage(12000, 480, 0, 300, 180, "resp-ag-main-1", "msg-ag-main-1"),
        extra=pb_fixed64(9001, 0x0123456789ABCDEF)))
    c.step(RUN_COMMAND, DONE, meta("09:00:04.310", viewable="09:00:04.330", completed="09:00:06.000",
                                   started="09:00:04.320", tool=("call-a1", "run_command")))
    c.step(PLANNER_RESPONSE, DONE, meta(
        "09:00:06.020", viewable="09:00:06.700", last_chunk="09:00:08.000", finished="09:00:08.020",
        completed="09:00:08.040", model_usage=usage(1500, 210, 12400, 90, 120, "resp-ag-main-2")))
    c.step(VIEW_FILE, DONE, meta("09:00:08.050", completed="09:00:08.090", tool=("call-a2", "view_file")))
    c.step(PLANNER_RESPONSE, DONE, meta(
        "09:00:08.110", finished="09:00:11.110", completed="09:00:11.150",
        model_usage=usage(2000, 350, 14000, 200, 150, "resp-ag-main-3")))
    c.step(INVOKE_SUBAGENT, DONE, meta("09:00:11.200", completed="09:01:30.000", started="09:00:11.210",
                                       tool=("call-a3", "invoke_subagent")))
    c.step(PLANNER_RESPONSE, DONE, meta(
        "09:01:30.050", viewable="09:01:31.000", finished="09:01:39.050", completed="09:01:39.100",
        model_usage=usage(900, 1200, 16000, 400, 800, "resp-ag-main-4")))
    # Checkpoint after the answer; its viewable_at nanos are out of range and count as 0.
    c.step(CHECKPOINT, DONE, meta("09:01:39.200", completed="09:01:39.400", source=1)
           + stamp(6, "09:01:40.000", nanos=1_999_999_999))
    c.generations = [
        (generation([1], "gemini-3.1-pro-high", "Gemini 3.1 Pro (High)"), None),
        (generation([3], "gemini-3.1-pro-high-exp-b", "Gemini 3.1 Pro (High)", packed=False), None),
        (generation([5], None, "Gemini 3.1 Pro (High)"), None),
        (generation([7], "decoy-oversized-row-must-not-be-read"), 314_572_800),  # embeds the whole prompt in reality
    ]
    c.executors = [executor(4, 8, "gemini-3.1-pro")]  # NO_TOOL_CALL
    return c


def sub_conversation():
    """CLI sub-agent of MAIN (all three sub-agent markers), waiting on a running tool."""
    c = Conversation(SUB, SOURCE_CLI, trajectory(
        "09:00:11.300", uris=["file:///Users/dev/projects/star%20map"], parent=MAIN, nesting=1,
        subagent=("research", "Map the call sites"), root=MAIN))
    c.step(USER_INPUT, DONE, meta("09:00:11.400", completed="09:00:11.410", source=3))
    c.step(PLANNER_RESPONSE, DONE, meta("09:00:11.450", finished="09:00:13.450", completed="09:00:13.470",
                                        model_usage=usage(5000, 150, 0, 100, 50, "resp-ag-sub-1")))
    c.step(RUN_COMMAND, RUNNING, meta("09:00:13.500", started="09:00:13.520", tool=("call-s1", "run_command")))
    c.generations = [(generation([1], "gemini-3.1-flash"), None)]
    return c


def inflight_conversation():
    """App: end-time fallbacks, failed and cancelled calls, key fallbacks, a capped row, a call in flight."""
    c = Conversation(INFLIGHT, SOURCE_APP, trajectory("09:10:00.000", uris=["file:///c%3A/Users/dev/projects/orbit"]))
    c.step(USER_INPUT, DONE, meta("09:10:01.000", completed="09:10:01.010", source=4))
    c.step(PLANNER_RESPONSE, DONE, meta(  # 1: finished_generating_at empty -> last chunk; output from parts
        "09:10:01.050", finished=INVALID, last_chunk="09:10:03.050", completed="09:10:03.200",
        model_usage=usage(3000, 0, 1000, 64, 136, message_id="msg-ag-orbit-1")))
    c.step(VIEW_FILE, DONE, meta("09:10:03.210", completed="09:10:03.260"))
    c.step(PLANNER_RESPONSE, DONE, meta(  # 3: only completed_at
        "09:10:03.300", completed="09:10:05.300", model_usage=usage(200, 90, 4000, 0, 90, "resp-ag-orbit-2")))
    c.step(RUN_COMMAND, DONE, meta("09:10:05.310", completed="09:10:07.000"))
    c.step(PLANNER_RESPONSE, ERROR, meta(  # 5: failed call, totals only
        "09:10:07.050", last_chunk="09:10:08.000", finished="09:10:08.050", completed="09:10:08.060",
        model_usage=usage(300, 12, 4200, 12, 0, "resp-ag-orbit-3")))
    c.step(PLANNER_RESPONSE, DONE, meta(  # 6: no end timestamp, no ids
        "09:10:09.000", viewable="09:10:09.500", model_usage=usage(100, 40, 4400, 0, 40)))
    c.step(PLANNER_RESPONSE, CANCELED, meta(  # 7
        "09:10:10.000", last_chunk="09:10:11.000", model_usage=usage(50, 20, 4500, 0, 20, "resp-ag-orbit-5")))
    c.step(USER_INPUT, DONE, meta("09:10:20.000", completed="09:10:20.010", source=4))
    c.step(PLANNER_RESPONSE, INTERRUPTED, meta(  # 9
        "09:10:20.050", last_chunk="09:10:21.000", completed="09:10:21.020",
        model_usage=usage(80, 30, 4600, 10, 20, "resp-ag-orbit-6")))
    c.step(PLANNER_RESPONSE, DONE, meta(  # 10: usage present but all zero -> no response
        "09:10:21.100", finished="09:10:21.200", model_usage=usage(response_id="resp-ag-orbit-zero")))
    c.step(PLANNER_RESPONSE, DONE, meta(  # 11: implausible token count -> malformed row
        "09:10:21.300", finished="09:10:22.300", model_usage=usage(10_000_001, 50, 0, 0, 50, "resp-ag-orbit-cap")))
    c.step(USER_INPUT, DONE, meta("09:10:30.000", completed="09:10:30.010", source=4))
    c.step(PLANNER_RESPONSE, GENERATING, meta(  # 13: streaming, partial usage already written
        "09:10:30.050", viewable="09:10:30.900", last_chunk="09:10:31.500",
        model_usage=usage(500, 40, 4700, 0, 40, "resp-ag-orbit-live")))
    c.generations = [(generation([1], "gemini-3.1-flash-lite"), None)]
    c.executors = [executor(1, 7, "gemini-3.1-flash"), executor(2, 9, "gemini-3.1-flash-b")]  # ERROR, USER_CANCELED
    return c


def browser_conversation():
    """App: a browser sub-agent known only by its parent id (upper case), project from the deprecated workspaces."""
    c = Conversation(BROWSER, SOURCE_APP, trajectory(
        "09:20:00.000", workspace="file:///Users/dev/projects/orbit-web", parent=INFLIGHT.upper()))
    c.step(USER_INPUT, DONE, meta("09:20:00.100", completed="09:20:00.110", source=3))
    c.step(PLANNER_RESPONSE, DONE, meta("09:20:00.150", finished="09:20:02.150", completed="09:20:02.200",
                                        model_usage=usage(2500, 60, 0, 0, 60, "resp-ag-browser-1")))
    c.step(LIST_DIRECTORY, DONE, meta("09:20:02.250", started="09:20:02.260"))  # done, completed_at missing
    truncated = key(1, 2) + varint(50) + b"abc"  # length runs past the end of the blob
    c.generations = [(truncated, None), (generation([1], "gemini-3.1-flash"), None)]
    return c


def fork_conversation():
    """App: a fork; copied rows keep their old creation times and carry no ids."""
    c = Conversation(FORK, SOURCE_APP, trajectory("09:30:00.000", uris=["file:///Users/dev/projects/nebula"]))
    c.step(USER_INPUT, DONE, meta("09:05:00.000", completed="09:05:00.010", source=4))
    c.step(PLANNER_RESPONSE, DONE, meta("09:05:00.050", finished="09:05:03.000", completed="09:05:03.050",
                                        model_usage=usage(4000, 100, 0, 0, 100)))
    c.step(RUN_COMMAND, DONE, meta("09:05:03.100", completed="09:05:04.000"))
    c.step(PLANNER_RESPONSE, DONE, meta("09:05:04.050", viewable="09:31:00.000", finished="09:05:06.000",
                                        model_usage=usage(4300, 80, 0, 0, 80)))
    c.step(CHECKPOINT, DONE, None)  # no metadata: skipped, not malformed
    c.step(RUN_COMMAND, DONE, stamp(1, "09:30:00.500") + key(2, 7))  # wire type 7: malformed
    c.step(USER_INPUT, DONE, meta("09:30:01.000", completed="09:30:01.010", source=4))
    c.step(PLANNER_RESPONSE, DONE, meta("09:30:01.050", finished="09:30:04.050", completed="09:30:04.100",
                                        model_usage=usage(600, 300, 8000, 120, 180, "resp-ag-fork-1")))
    c.step(RUN_COMMAND, CANCELED, meta("09:30:04.200", viewable="09:30:04.210"))
    c.generations = [(generation([7], "gemini-3.1-pro-low"), None)]
    return c


def nested_conversation():
    """IDE, rollback journal: a fresh conversation (nesting depth only) whose user input slightly precedes it."""
    c = Conversation(NESTED, SOURCE_APP, trajectory("09:40:00.500", uris=["file:///Users/dev/projects/nova"], nesting=2))
    c.step(USER_INPUT, DONE, meta("09:40:00.100", viewable="09:40:00.200", completed="09:40:00.110", source=4))
    return c


def image_conversation():
    """IDE: image generation (sub-agent spec only); a tool finished; an executor row with last_step_idx -1."""
    c = Conversation(IMAGE, SOURCE_APP, trajectory(
        "09:50:00.000", uris=["file:///Users/dev/projects/nova"], subagent=("image_generation", "Render the logo")))
    c.step(USER_INPUT, DONE, meta("09:50:00.100", completed="09:50:00.110", source=3))
    c.step(PLANNER_RESPONSE, DONE, meta("09:50:00.150", last_chunk="09:50:01.640", finished="09:50:01.650",
                                        completed="09:50:01.700",
                                        model_usage=usage(700, 45, 0, 30, 15, "resp-ag-image-1")))
    c.step(RUN_COMMAND, DONE, meta("09:50:01.750", viewable="09:50:04.030", completed="09:50:04.000",
                                   started="09:50:01.760"))
    c.executors = [executor(1, -1, "gemini-3.1-flash-image")]
    return c


def ide_sub_conversation():
    """IDE: a sub-agent of MAIN, whose conversation exists in two stores; the copy in its own store is the parent."""
    c = Conversation(IDE_SUB, SOURCE_APP, trajectory(
        "09:57:00.000", uris=["file:///Users/dev/projects/star%20map"], parent=MAIN, nesting=1, root=MAIN))
    c.step(USER_INPUT, DONE, meta("09:57:00.100", completed="09:57:00.110", source=3))
    c.step(PLANNER_RESPONSE, DONE, meta("09:57:00.150", finished="09:57:02.150", completed="09:57:02.170",
                                        model_usage=usage(3000, 120, 1000, 40, 80, "resp-ag-idesub-1")))
    c.generations = [(generation([1], "gemini-3.1-flash"), None)]
    return c


def cancelled_conversation():
    """App: one answered turn, then a queued user input that was cancelled before any model call."""
    c = Conversation(CANCELLED, SOURCE_APP, trajectory("09:58:00.000", uris=["file:///Users/dev/projects/nebula"]))
    c.step(USER_INPUT, DONE, meta("09:58:00.100", completed="09:58:00.110", source=4))
    c.step(PLANNER_RESPONSE, DONE, meta("09:58:00.150", finished="09:58:01.150", completed="09:58:01.170",
                                        model_usage=usage(800, 50, 0, 0, 50, "resp-ag-cancel-1")))
    c.step(USER_INPUT, CANCELED, meta("09:58:05.000", viewable="09:58:05.010", source=4))
    c.generations = [(generation([1], "gemini-3.1-flash"), None)]
    return c


def write_fixtures(out_dir):
    base = os.path.join(out_dir, "antigravity")
    if os.path.exists(base):
        shutil.rmtree(base)

    def p(rel):
        full = os.path.join(out_dir, *rel.split("/"))
        os.makedirs(os.path.dirname(full), exist_ok=True)
        return full

    main_conversation().write(p(MAIN_DB))
    sub_conversation().write(p(SUB_DB))
    inflight_conversation().write(p(INFLIGHT_DB))
    browser_conversation().write(p(BROWSER_DB))
    fork_conversation().write(p(FORK_DB))
    nested_conversation().write(p(NESTED_DB), wal=False)
    image_conversation().write(p(IMAGE_DB))
    ide_sub_conversation().write(p(IDE_SUB_DB))
    cancelled_conversation().write(p(CANCELLED_DB))
    tiny_db(p(UNSUPPORTED_DB), "PRAGMA journal_mode=WAL; PRAGMA user_version=1;"
            "CREATE TABLE trajectory_meta(trajectory_id TEXT,cascade_id TEXT,trajectory_type INTEGER,source INTEGER);"
            "CREATE TABLE trajectory_metadata_blob(id TEXT,data BLOB);"
            "CREATE TABLE trajectory_steps(idx INTEGER,payload BLOB);")
    shutil.copyfile(p(MAIN_DB), p(COPY_DB))  # some machines hold byte copies in two stores
    shutil.copyfile(p(MAIN_DB), p(BACKUP_DB))

    # Decoys that discovery must ignore.
    noise = hashlib.sha256(b"antigravity legacy conversation").digest() * 8
    with open(p("antigravity/antigravity/conversations/%s.pb" % INFLIGHT), "wb") as f:
        f.write(noise)
    with open(p("antigravity/antigravity/implicit/%s.pb" % BROWSER), "wb") as f:
        f.write(noise[::-1])
    with open(p("antigravity/antigravity/conversations/%s.trajectory.json" % BROWSER), "w", encoding="utf-8") as f:
        json.dump({"trajectoryId": "traj-" + BROWSER[:8], "cascadeId": BROWSER, "steps": []}, f)
    with open(p("antigravity/antigravity/brain/%s/.system_generated/logs/transcript.jsonl" % INFLIGHT), "w",
              encoding="utf-8", newline="\n") as f:
        f.write(json.dumps({"role": "user", "content": "(omitted)"}) + "\n")
    with open(p("antigravity/antigravity-cli/log/cli-20261021-090000.log"), "w", encoding="utf-8", newline="\n") as f:
        f.write("I1021 09:00:00.000000 51 server.go:1631] language server started\n")
    tiny_db(p("antigravity/antigravity/conversation_summaries.db"),
            "CREATE TABLE conversation_summaries(conversation_id TEXT, status INTEGER);")
    tiny_db(p("antigravity/antigravity-cli/conversations/notes.db"), "CREATE TABLE steps(idx INTEGER);")
    tiny_db(p("antigravity/antigravity/conversations/old/%s.db" % FORK), "CREATE TABLE steps(idx INTEGER);")

    mtimes = {rel: ms(clock) for rel, clock in (
        (SUB_DB, "09:00:14.000"), (MAIN_DB, "09:01:41.000"), (UNSUPPORTED_DB, "09:02:00.000"),
        (INFLIGHT_DB, "09:10:32.000"), (BROWSER_DB, "09:20:03.000"), (FORK_DB, "09:31:01.000"),
        (NESTED_DB, "09:40:01.000"), (IMAGE_DB, "09:50:05.000"), (COPY_DB, "09:55:00.000"),
        (IDE_SUB_DB, "09:57:03.000"), (CANCELLED_DB, "09:58:06.000"))}
    for rel, when in mtimes.items():
        os.utime(p(rel), (when / 1000, when / 1000))
    os.utime(p(BACKUP_DB), (ms("09:56:00.000") / 1000,) * 2)
    order = sorted(mtimes, key=lambda rel: (mtimes[rel], rel))

    databases = {
        MAIN_DB: expect("star map", "gemini-3.1-pro", False, None, "idle", None, "09:01:40.000", 0, [
            resp("resp-ag-main-1", "09:00:01.050", "09:00:04.250", 12000, 0, 480, 300, "gemini-3.1-pro-high"),
            resp("resp-ag-main-2", "09:00:06.020", "09:00:08.020", 13900, 12400, 210, 90, "gemini-3.1-pro-high-exp-b"),
            resp("resp-ag-main-3", "09:00:08.110", "09:00:11.110", 16000, 14000, 350, 200, "Gemini 3.1 Pro (High)"),
            resp("resp-ag-main-4", "09:01:30.050", "09:01:39.050", 16900, 16000, 1200, 400, "gemini-3.1-pro"),
        ]),
        SUB_DB: expect("star map", "gemini-3.1-flash", True, MAIN_DB, "tools", None, "09:00:13.520", 0, [
            resp("resp-ag-sub-1", "09:00:11.450", "09:00:13.450", 5000, 0, 150, 100, "gemini-3.1-flash"),
        ]),
        UNSUPPORTED_DB: {"unsupported": True},
        INFLIGHT_DB: expect("orbit", "gemini-3.1-flash-b", False, None, "generating", "09:10:30.050", "09:10:31.500", 1, [
            resp("msg-ag-orbit-1", "09:10:01.050", "09:10:03.050", 4000, 1000, 200, 64, "gemini-3.1-flash-lite"),
            resp("resp-ag-orbit-2", "09:10:03.300", "09:10:05.300", 4200, 4000, 90, 0, "gemini-3.1-flash"),
            resp("resp-ag-orbit-3", None, "09:10:08.050", 4500, 4200, 12, 12, "gemini-3.1-flash"),
            resp("antigravity:%s:6" % INFLIGHT, None, "09:10:09.500", 4500, 4400, 40, 0, "gemini-3.1-flash"),
            resp("resp-ag-orbit-5", None, "09:10:11.000", 4550, 4500, 20, 0, "gemini-3.1-flash"),
            resp("resp-ag-orbit-6", None, "09:10:21.000", 4680, 4600, 30, 10, "gemini-3.1-flash-b"),
        ]),
        BROWSER_DB: expect("orbit-web", "gemini-3.1-flash", True, INFLIGHT_DB, "generating", "09:20:02.250",
                           "09:20:02.260", 1, [
            resp("resp-ag-browser-1", "09:20:00.150", "09:20:02.150", 2500, 0, 60, 0, "gemini-3.1-flash"),
        ]),
        FORK_DB: expect("nebula", "gemini-3.1-pro-low", False, None, "idle", None, "09:30:04.210", 1, [
            resp("resp-ag-fork-1", "09:30:01.050", "09:30:04.050", 8600, 8000, 300, 120, "gemini-3.1-pro-low"),
        ]),
        NESTED_DB: expect("nova", None, True, None, "generating", "09:40:00.100", "09:40:00.500", 0, []),
        IMAGE_DB: expect("nova", None, True, None, "generating", "09:50:04.000", "09:50:04.030", 0, [
            resp("resp-ag-image-1", "09:50:00.150", "09:50:01.650", 700, 0, 45, 30, None),
        ]),
        COPY_DB: expect("star map", None, False, None, "idle", None, "09:01:40.000", 0, []),
        IDE_SUB_DB: expect("star map", "gemini-3.1-flash", True, COPY_DB, "idle", None, "09:57:02.170", 0, [
            resp("resp-ag-idesub-1", "09:57:00.150", "09:57:02.150", 4000, 1000, 120, 40, "gemini-3.1-flash"),
        ]),
        CANCELLED_DB: expect("nebula", "gemini-3.1-flash", False, None, "idle", None, "09:58:05.010", 0, [
            resp("resp-ag-cancel-1", "09:58:00.150", "09:58:01.150", 800, 0, 50, 0, "gemini-3.1-flash"),
        ]),
    }
    return {
        "_comment": "Antigravity databases are processed in `order` after the files of the top-level `order`, with the "
                    "same dedupe set; %s is a byte copy of %s whose keys the original owns, and the parent of %s "
                    "(same store) while %s attaches to the original. The `antigravity` folder plays the role of "
                    "~/.gemini (stores antigravity-cli, antigravity, antigravity-ide)."
                    % (COPY_DB, MAIN_DB, IDE_SUB_DB, SUB_DB),
        "order": order,
        "mtimes": mtimes,
        "discover": sorted(mtimes),
        "databases": databases,
    }


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip())
        sys.exit(2)
    print(json.dumps(write_fixtures(sys.argv[1]), indent=2))


if __name__ == "__main__":
    main()
