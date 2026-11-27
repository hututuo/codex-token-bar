#!/usr/bin/env python3
"""Pair real release Apps on one disposable macOS Actions runner, without building.

Only the CLI runs an App. Importing this module and its stdlib tests is safe on
other hosts. The CLI refuses a local/non-Actions host, an existing product data
directory/defaults domain, or existing client source roots. It uses the real
runner account's Foundation directories, never a HOME-based isolation trick.

Protocol v2: cold bootstrap, fully visible dashboard, then warmup and a
120-second main-process sample. A shared native frame preference and a fitting
cloud display control the viewport; no UI actions, hidden/retention workload,
credentialed service, clock injection, whole-family metric, or halving claim.
"""
from __future__ import annotations

import argparse
from contextlib import closing
import ctypes
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import pwd
import shutil
import sqlite3
import subprocess
import sys
import time
import uuid

BUNDLE_ID = "local.codex.token-bar"
VIEWPORT_PROTOCOL = "fixed-native-frame-fully-visible-v2"
DASHBOARD_WINDOW = {"width": 1240, "height": 812}
CLIENTS = ("claudeCode", "claudeDesktop", "deepseek", "gemini", "opencode", "antigravity")
OWNED_PARENTS = (
    "Library/Application Support", "Library/Caches", "Library/HTTPStorages",
    "Library/WebKit", "Library/Containers", "Library/Application Scripts",
    "Library/Saved Application State", "Library/Preferences", "Library/Preferences/ByHost", "Library/Logs",
)
OWNED_PREFIXES = ("CodexTokenBar", "Codex Token Bar", BUNDLE_ID)
SOURCE_ROOTS = (
    ".codex", ".claude", ".claude-official-guarded", ".local/share/claude-adapter",
    ".gemini", ".config/opencode", ".local/share/opencode", ".opencode", ".antigravity", ".deepseek", ".dsh",
    "Library/Application Support/Claude", "Library/Application Support/Antigravity",
)
RU_FIELDS = """user_time system_time pkg_idle_wkups interrupt_wkups pageins
wired_size resident_size phys_footprint proc_start_abstime proc_exit_abstime
child_user_time child_system_time child_pkg_idle_wkups child_interrupt_wkups
child_pageins child_elapsed_abstime diskio_bytesread diskio_byteswritten
cpu_time_qos_default cpu_time_qos_maintenance cpu_time_qos_background
cpu_time_qos_utility cpu_time_qos_legacy cpu_time_qos_user_initiated
cpu_time_qos_user_interactive billed_system_time serviced_system_time
logical_writes lifetime_max_phys_footprint instructions cycles billed_energy
serviced_energy interval_max_phys_footprint runnable_time""".split()
LEDGER_COLUMNS = """client,event_id,session_id,model,CAST(ROUND(timestamp*1000) AS INTEGER),
input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,reasoning_tokens"""


class BenchError(RuntimeError):
    def __init__(self, message, status="FAILED"):
        super().__init__(message)
        self.status = status


def require(value, message, status="FAILED"):
    if not value:
        raise BenchError(message, status)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()


def digest(value):
    return hashlib.sha256(value).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def within(path, root):
    return path == root or root in path.parents


def owned_paths(home):
    """Only named product paths, including system-generated per-bundle data."""
    found = []
    for relative in OWNED_PARENTS:
        parent = home / relative
        if parent.is_dir():
            found.extend(p for p in parent.iterdir() if p.name.startswith(OWNED_PREFIXES))
    return sorted(set(found), key=str)


def command(argv, *, env=None, check=True):
    result = subprocess.run([str(v) for v in argv], env=env, capture_output=True, timeout=30)
    if check:
        require(result.returncode == 0, f"command failed ({result.returncode}): {argv[0]}")
    return result


def product_processes(runtime_app=None, env=None):
    """Return only product executable metadata, never other processes' args."""
    text = command(["/bin/ps", "-axo", "pid=,comm="], env=env).stdout.decode(errors="replace")
    found = []
    for line in text.splitlines():
        fields = line.strip().split(maxsplit=1)
        if len(fields) != 2 or not fields[0].isdigit():
            continue
        executable = fields[1]
        if Path(executable).name in ("CodexTokenBar", "CodexTokenDashboard") or (
                runtime_app and executable.startswith(str(runtime_app) + "/")):
            found.append({"pid": int(fields[0]), "executable": executable})
    return found


def export_defaults(env):
    result = command(["/usr/bin/defaults", "export", BUNDLE_ID, "-"], env=env, check=False)
    if result.returncode != 0:
        return None
    try:
        value = plistlib.loads(result.stdout)
    except (ValueError, plistlib.InvalidFileException) as error:
        raise BenchError("defaults export did not return a plist") from error
    require(isinstance(value, dict), "defaults domain is not a dictionary")
    if not value:
        # macOS can successfully export an absent domain as an empty plist.
        # Keep an existing empty domain distinct so the preflight still refuses it.
        existing = command(["/usr/bin/defaults", "read", BUNDLE_ID], env=env, check=False)
        if existing.returncode != 0:
            return None
    return value


def clean_environment(home, fixture, tmpdir):
    """No inherited GitHub/API/proxy/signing secrets reach the App or helpers."""
    account = pwd.getpwuid(os.getuid()).pw_name
    return {"HOME": str(home), "USER": account, "LOGNAME": account,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/zsh",
            "LANG": "en_US.UTF-8", "TMPDIR": str(tmpdir),
            "CODEX_HOME": str(fixture / "empty-codex"),
            "CODEX_SQLITE_HOME": str(fixture / "empty-codex"),
            "CLAUDE_CONFIG_DIR": str(fixture / "claudeCode")}


def guard_host(output):
    require(platform.system() == "Darwin" and os.environ.get("GITHUB_ACTIONS") == "true"
            and os.environ.get("RUNNER_OS") == "macOS",
            "requires a disposable GitHub Actions macOS runner", "REFUSED")
    require(os.getuid() != 0, "do not run as root", "REFUSED")
    runner_temp = Path(os.environ.get("RUNNER_TEMP", "")).resolve()
    require(os.environ.get("RUNNER_TEMP") and runner_temp.is_dir(), "RUNNER_TEMP missing", "REFUSED")
    allowed = [runner_temp]
    if os.environ.get("GITHUB_WORKSPACE"):
        allowed.append(Path(os.environ["GITHUB_WORKSPACE"]).resolve())
    require(output.is_absolute() and any(within(output.resolve(), p) and output.resolve() != p for p in allowed),
            "output must be a new child of RUNNER_TEMP or GITHUB_WORKSPACE", "REFUSED")
    require(not output.exists(), "output directory already exists", "REFUSED")
    home = Path(pwd.getpwuid(os.getuid()).pw_dir).resolve()
    require(Path(os.environ.get("HOME", "")).resolve() == home,
            "HOME must equal this account's actual home; overrides are not isolation", "REFUSED")
    existing = owned_paths(home)
    require(not existing, "preexisting app-owned paths: " + ", ".join(map(str, existing)), "REFUSED")
    # Check existence only: never inspect an account token or private transcript.
    require(not any((home / relative).exists() or (home / relative).is_symlink() for relative in SOURCE_ROOTS),
            "preexisting client source root; runner is not an empty fixture account", "REFUSED")
    return home, runner_temp


def bundle_manifest(path):
    require(path.is_dir() and path.suffix == ".app", "expected an existing .app bundle")
    info = plistlib.loads((path / "Contents/Info.plist").read_bytes())
    require(info.get("CFBundleIdentifier") == BUNDLE_ID, "benchmark requires the formal bundle ID")
    executable = path / "Contents/MacOS" / info.get("CFBundleExecutable", "")
    require(executable.is_file() and os.access(executable, os.X_OK), "bundle executable unavailable")
    return {"bundleID": BUNDLE_ID, "version": info.get("CFBundleShortVersionString"),
            "build": info.get("CFBundleVersion"), "executable": executable.name,
            "executableSha256": digest(executable.read_bytes()),
            "infoPlistSha256": digest((path / "Contents/Info.plist").read_bytes())}


def source_inventory(root):
    entries = []
    for path in sorted(root.rglob("*")):
        require(not path.is_symlink(), "fixture may not contain symlinks")
        if path.is_file():
            stat = path.stat()
            entries.append({"path": str(path.relative_to(root)), "bytes": stat.st_size,
                            "sha256": digest(path.read_bytes()), "device": stat.st_dev,
                            "inode": stat.st_ino, "mtimeNS": stat.st_mtime_ns})
    return {"files": entries, "sha256": digest(canonical(entries)),
            "bytes": sum(p["bytes"] for p in entries)}


def expected_rows(count, anchor_seconds):
    rows = []
    for i in range(count):
        session = f"fixture-session-{i % 20:02d}"
        message = f"fixture-response-{i:08d}"
        event = "v1:" + digest(session.encode()) + ":id:" + digest(message.encode())
        rows.append(["claudeCode", event, session, "claude-opus-4-6",
                     (anchor_seconds - i % 600) * 1000, 100 + i % 17, 20 + i % 13,
                     None, None, None])
    return sorted(rows, key=lambda row: (row[0], row[1]))


def generate_fixture(root, count, anchor_seconds):
    require(count > 0 and not root.exists(), "fixture must be positive-sized and create-only")
    for client in CLIENTS:
        (root / client).mkdir(parents=True)
    (root / "empty-codex/sessions").mkdir(parents=True)
    files = [(root / "claudeCode" / f"session-{index:02d}.jsonl").open("xb") for index in range(20)]
    try:
        for i in range(count):
            timestamp = dt.datetime.fromtimestamp(anchor_seconds - i % 600, dt.timezone.utc)
            started = timestamp - dt.timedelta(seconds=1)
            user = {"type": "user", "entrypoint": "cli",
                    "sessionId": f"fixture-session-{i % 20:02d}",
                    "timestamp": started.isoformat(timespec="seconds").replace("+00:00", "Z"),
                    "message": {"role": "user", "content": "synthetic benchmark prompt"}}
            row = {"type": "assistant", "entrypoint": "cli",
                   "sessionId": f"fixture-session-{i % 20:02d}",
                   "timestamp": timestamp.isoformat(timespec="seconds").replace("+00:00", "Z"),
                   "message": {"id": f"fixture-response-{i:08d}", "model": "claude-opus-4-6", "stop_reason": "end_turn",
                               "content": [{"type": "text", "text": "fixture response"}],
                               "usage": {"input_tokens": 100 + i % 17, "output_tokens": 20 + i % 13}}}
            files[i % 20].write(canonical(user) + b"\n" + canonical(row) + b"\n")
    finally:
        for handle in files:
            handle.close()
    rows = expected_rows(count, anchor_seconds)
    return {"fixtureSchemaVersion": 2, "responses": count, "anchorUnixSeconds": anchor_seconds,
            "responseDurationSeconds": 1, "completedResponses": count,
            "source": source_inventory(root), "expectedLedgerSha256": digest(canonical(rows)),
            "expectedTotals": {"count": count, "inputTokens": sum(r[5] for r in rows),
                               "outputTokens": sum(r[6] for r in rows)}}


def preference_seed(fixture, dashboard_frame=None):
    preferences = [{"client": client, "enabled": client == "claudeCode",
                    "showQuota": client == "claudeCode", "showSidebar": client == "claudeCode",
                    "showMenuBar": client == "claudeCode", "color": "#B87542", "order": index,
                    "style": "compact", "path": str(fixture / client)}
                   for index, client in enumerate(CLIENTS)]
    home = fixture / "empty-codex"
    stat = home.stat()
    seed = {"multiClientUsage.preferences.v1": canonical(preferences),
            "CodexTokenBar.selectedCodexHome": str(home),
            "CodexTokenBar.selectedCodexHomeDeviceID": str(stat.st_dev),
            "CodexTokenBar.selectedCodexHomeFileID": str(stat.st_ino),
            "setupGuideCompletedV01": True,
            "agentSpeedReporting.enabled.v1": False,
            "agentSpeedReporting.invitationShown.v1": True,
            "CodexTokenBar.autoResume.tasks.v2": canonical({"schemaVersion": 2, "tasks": []})}
    if dashboard_frame is not None:
        seed["NSWindow Frame dashboard"] = dashboard_frame
    return seed


def ledger_truth(path, fixture):
    if not path.is_file():
        return None
    try:
        with closing(sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=0.2)) as connection:
            connection.execute("PRAGMA query_only=ON")
            count = connection.execute("SELECT COUNT(*) FROM client_usage_events").fetchone()[0]
            if count != fixture["responses"]:
                return {"count": count, "complete": False}
            rows = [list(row) for row in connection.execute(
                f"SELECT {LEDGER_COLUMNS} FROM client_usage_events ORDER BY client,event_id")]
            actual = digest(canonical(rows))
            quick = connection.execute("PRAGMA quick_check").fetchall()
            return {"count": count, "sha256": actual, "quickCheck": quick,
                    "inputTokens": sum(r[5] for r in rows), "outputTokens": sum(r[6] for r in rows),
                    "complete": actual == fixture["expectedLedgerSha256"] and quick == [("ok",)]}
    except sqlite3.OperationalError:
        return None  # Opening/schema/bootstrap may still be in progress, outside the sample phase.


class RUsage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_ubyte * 16)] + [(name, ctypes.c_uint64) for name in RU_FIELDS]


class ProcessSampler:
    def __init__(self, pid):
        require(ctypes.sizeof(RUsage) == 296, "unexpected rusage_info_v4 ABI")
        self.pid, self.identity = pid, None
        self.lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self.lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        self.lib.proc_pid_rusage.restype = ctypes.c_int

    def sample(self):
        value = RUsage()
        require(self.lib.proc_pid_rusage(self.pid, 4, ctypes.byref(value)) == 0,
                f"proc_pid_rusage failed: errno={ctypes.get_errno()}")
        identity = value.proc_start_abstime, bytes(value.uuid).hex()
        require(self.identity is None or self.identity == identity, "PID birth/UUID changed")
        self.identity = identity
        return {"pid": self.pid, "birth": identity[0], "uuid": identity[1],
                "monotonicNS": time.monotonic_ns(), "wallNS": time.time_ns(),
                "cpuNS": value.user_time + value.system_time, "rssBytes": value.resident_size,
                "footprintBytes": value.phys_footprint, "pageins": value.pageins,
                "readBytes": value.diskio_bytesread, "writtenBytes": value.diskio_byteswritten,
                "lifetimePeakFootprintBytes": value.lifetime_max_phys_footprint}


class VisibleWindowProbe:
    """Read WindowServer metadata only; no AX, screenshots or UI actions."""
    def __init__(self):
        self.cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
        self.cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        self.cg.CGWindowListCopyWindowInfo.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
        self.cg.CGWindowListCopyWindowInfo.restype = ctypes.c_void_p
        self.cf.CFArrayGetCount.argtypes = [ctypes.c_void_p]
        self.cf.CFArrayGetCount.restype = ctypes.c_long
        self.cf.CFArrayGetValueAtIndex.argtypes = [ctypes.c_void_p, ctypes.c_long]
        self.cf.CFArrayGetValueAtIndex.restype = ctypes.c_void_p
        self.cf.CFDictionaryGetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        self.cf.CFDictionaryGetValue.restype = ctypes.c_void_p
        self.cf.CFNumberGetValue.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
        self.cf.CFNumberGetValue.restype = ctypes.c_bool
        self.cf.CFRelease.argtypes = [ctypes.c_void_p]
        self.cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
        self.cf.CFStringCreateWithCString.restype = ctypes.c_void_p
        self.keys = {name: ctypes.c_void_p.in_dll(self.cg, name).value for name in
                     ("kCGWindowOwnerPID", "kCGWindowLayer", "kCGWindowBounds")}
        for name in ("X", "Y", "Width", "Height"):
            self.keys[name] = self.cf.CFStringCreateWithCString(None, name.encode(), 0x08000100)

    def number(self, dictionary, key):
        pointer = self.cf.CFDictionaryGetValue(dictionary, self.keys[key])
        value = ctypes.c_double()
        return value.value if pointer and self.cf.CFNumberGetValue(pointer, 13, ctypes.byref(value)) else None

    def windows(self, pid):
        array = self.cg.CGWindowListCopyWindowInfo(1, 0)  # on-screen only
        require(array, "WindowServer list unavailable", "NOT_RUN")
        found = []
        try:
            for index in range(self.cf.CFArrayGetCount(array)):
                item = self.cf.CFArrayGetValueAtIndex(array, index)
                if self.number(item, "kCGWindowOwnerPID") != pid or self.number(item, "kCGWindowLayer") != 0:
                    continue
                bounds = self.cf.CFDictionaryGetValue(item, self.keys["kCGWindowBounds"])
                if bounds:
                    width, height = self.number(bounds, "Width"), self.number(bounds, "Height")
                    if width and height and width >= 1000 and height >= 700:
                        found.append({"width": width, "height": height,
                                      "x": self.number(bounds, "X"), "y": self.number(bounds, "Y")})
        finally:
            self.cf.CFRelease(array)
        return sorted(found, key=lambda item: item["width"] * item["height"], reverse=True)


def display_geometry(env):
    # AppKit metadata only. This does not script an app or interact with UI.
    script = '''ObjC.import("AppKit");
    var screen = $.NSScreen.mainScreen;
    var frame = screen.frame, visible = screen.visibleFrame;
    JSON.stringify({frame: {x:frame.origin.x, y:frame.origin.y, width:frame.size.width, height:frame.size.height},
                    visible: {x:visible.origin.x, y:visible.origin.y, width:visible.size.width, height:visible.size.height}});'''
    response = command(["/usr/bin/osascript", "-l", "JavaScript", "-e", script], env=env)
    value = json.loads(response.stdout)
    for name in ("frame", "visible"):
        require(set(value[name]) == {"x", "y", "width", "height"}
                and all(isinstance(v, (int, float)) and math.isfinite(v) for v in value[name].values()),
                "invalid main-screen geometry", "NOT_RUN")
    return value


def dashboard_frame_seed(geometry):
    visible, screen = geometry["visible"], geometry["frame"]
    width, height = DASHBOARD_WINDOW["width"], DASHBOARD_WINDOW["height"]
    require(visible["width"] >= width + 32 and visible["height"] >= height + 32,
            "cloud visible screen cannot contain the benchmark dashboard", "NOT_RUN")
    x = round(visible["x"] + (visible["width"] - width) / 2)
    y = round(visible["y"] + (visible["height"] - height) / 2)
    return " ".join(str(round(v)) for v in
                    (x, y, width, height, screen["x"], screen["y"], screen["width"], screen["height"])) + " "


def dashboard_window_fits(window, geometry):
    visible, screen = geometry["visible"], geometry["frame"]
    # CGWindow bounds use a top-left origin; the main AppKit screen uses bottom-left.
    if screen["x"] != 0 or screen["y"] != 0:
        return False
    top = screen["height"] - visible["y"] - visible["height"]
    return (all(isinstance(window.get(k), (int, float)) and math.isfinite(window[k])
                for k in ("x", "y", "width", "height"))
            and window["x"] >= visible["x"] and window["y"] >= top
            and window["x"] + window["width"] <= visible["x"] + visible["width"]
            and window["y"] + window["height"] <= top + visible["height"])


class BenchmarkDisplay:
    """Hold a fitting existing display mode for this guarded cloud process."""
    def __init__(self, probe, env):
        self.cg, self.cf, self.env = probe.cg, probe.cf, env
        self.original_mode = None
        self.display_id = None
        self.record = {}

    def configure(self):
        cg = self.cg
        cg.CGMainDisplayID.restype = ctypes.c_uint32
        cg.CGDisplayCopyDisplayMode.argtypes = [ctypes.c_uint32]
        cg.CGDisplayCopyDisplayMode.restype = ctypes.c_void_p
        cg.CGDisplayCopyAllDisplayModes.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
        cg.CGDisplayCopyAllDisplayModes.restype = ctypes.c_void_p
        for name in ("CGDisplayModeGetWidth", "CGDisplayModeGetHeight"):
            getattr(cg, name).argtypes = [ctypes.c_void_p]
            getattr(cg, name).restype = ctypes.c_size_t  # Logical points, not backing pixels.
        cg.CGDisplaySetDisplayMode.argtypes = [ctypes.c_uint32, ctypes.c_void_p, ctypes.c_void_p]
        cg.CGDisplaySetDisplayMode.restype = ctypes.c_int32
        cg.CGDisplayModeRelease.argtypes = [ctypes.c_void_p]
        cg.CGDisplayModeRelease.restype = None
        self.display_id = cg.CGMainDisplayID()
        self.original_mode = cg.CGDisplayCopyDisplayMode(self.display_id)
        require(self.original_mode, "main display mode unavailable", "NOT_RUN")
        self.record.update(before=display_geometry(self.env), modeChanged=False)
        try:
            self.frame_seed = dashboard_frame_seed(self.record["before"])
        except BenchError:
            modes = cg.CGDisplayCopyAllDisplayModes(self.display_id, None)
            require(modes, "main display modes unavailable", "NOT_RUN")
            try:
                candidates = []
                available = set()
                for index in range(self.cf.CFArrayGetCount(modes)):
                    mode = self.cf.CFArrayGetValueAtIndex(modes, index)
                    width, height = cg.CGDisplayModeGetWidth(mode), cg.CGDisplayModeGetHeight(mode)
                    available.add((width, height))
                    if width >= 1440 and height >= 1000:
                        candidates.append((width * height, width, height, mode))
                self.record["availableModePoints"] = [{"width": w, "height": h} for w, h in sorted(available)]
                require(candidates, "no fitting existing cloud display mode", "NOT_RUN")
                _, width, height, selected = min(candidates)
                require(cg.CGDisplaySetDisplayMode(self.display_id, selected, None) == 0,
                        "cloud display mode change refused", "NOT_RUN")
                self.record.update(modeChanged=True, requestedMode={"width": width, "height": height})
            finally:
                self.cf.CFRelease(modes)
            self.record["after"] = display_geometry(self.env)
            self.frame_seed = dashboard_frame_seed(self.record["after"])
        else:
            self.record["after"] = self.record["before"]
        self.record.update(dashboardWindow=DASHBOARD_WINDOW, framePreference=self.frame_seed,
                           units="logical points", scope="disposable Actions GUI session only")
        return self.record

    def restore(self):
        if self.original_mode:
            try:
                if self.record.get("modeChanged"):
                    code = self.cg.CGDisplaySetDisplayMode(self.display_id, self.original_mode, None)
                    self.record["restoreReturnCode"] = code
                    require(code == 0, "could not restore cloud display mode")
            finally:
                self.cg.CGDisplayModeRelease(self.original_mode)
                self.original_mode = None


def startup_ready(journal, pid):
    sessions, ready = set(), []
    for path in journal.glob("events-*.jsonl") if journal.is_dir() else []:
        for line in path.read_bytes().splitlines():
            try:
                row = json.loads(line)
            except (json.JSONDecodeError, UnicodeDecodeError):
                continue  # A currently appended final line can be incomplete.
            if row.get("area") == "startup" and row.get("phase") == "started" and row.get("metrics", {}).get("pid") == pid:
                sessions.add(row.get("session"))
            if row.get("area") == "startup" and row.get("phase") == "ready":
                ready.append(row)
    return next((row for row in ready if row.get("session") in sessions), None)


def quantile(values, fraction):
    values = sorted(values)
    return values[max(0, math.ceil(len(values) * fraction) - 1)]


def summarize(rows):
    require(len(rows) >= 2, "too few measurement samples")
    elapsed = (rows[-1]["monotonicNS"] - rows[0]["monotonicNS"]) / 1e9
    require(elapsed > 0, "nonpositive sample interval")
    cpu = (rows[-1]["cpuNS"] - rows[0]["cpuNS"]) / 1e9
    require(cpu >= 0, "CPU counter moved backwards")
    result = {"sampleCount": len(rows), "elapsedSeconds": elapsed, "cpuSeconds": cpu,
              "averageCPUPercentOneCore": 100 * cpu / elapsed,
              "maxGapSeconds": max((b["monotonicNS"] - a["monotonicNS"]) / 1e9
                                   for a, b in zip(rows, rows[1:]))}
    for field in ("rssBytes", "footprintBytes"):
        values = [row[field] for row in rows]
        result[field] = {"median": (quantile(values, 0.5) + quantile(values, (len(values) // 2 + 1) / len(values))) / 2,
                         "p95": quantile(values, 0.95), "max": max(values)}
    return result


def archive_state(home, destination, env):
    destination.mkdir()
    exported = export_defaults(env)
    if exported is not None:
        (destination / "defaults-export.plist").write_bytes(plistlib.dumps(exported, sort_keys=True))
    moves = []
    for path in owned_paths(home):
        target = destination / path.relative_to(home)
        target.parent.mkdir(parents=True, exist_ok=True)
        path.rename(target)
        moves.append(str(path.relative_to(home)))
    # Flush the daemon's domain after preserving its export and original plist.
    command(["/usr/bin/defaults", "delete", BUNDLE_ID], env=env, check=False)
    require(not owned_paths(home) and export_defaults(env) is None,
            "app-owned state/defaults remained after per-run archive")
    return {"renamed": moves, "archive": str(destination)}


def post_measurement_memory_diagnostics(pid, destination, env, *, retained_graph=False):
    """Supplemental cloud-only evidence, after the last resource sample.

    These tools may suspend the target briefly. Their CPU and allocations must
    never enter the paired measurement, and their availability is not a reason
    to turn an otherwise valid resource sample into a performance failure.
    No object contents, stack logging or privileged access is used. The optional
    retained-reference tree includes addresses in this disposable synthetic
    process; it is diagnostic evidence, not a measured allocation saving.
    """
    result = {"outsideMeasurement": True, "startedMonotonicNS": time.monotonic_ns(), "tools": []}
    tools = [("vmmap", ["/usr/bin/vmmap", "-summary", str(pid)]),
             ("heap", ["/usr/bin/heap", "-s", "--noContent", str(pid)])]
    if retained_graph:
        tools.append(("retained-graph", ["/usr/bin/leaks", "--noContent", "--nostacks",
                                         "--groupByType", "--referenceTree", str(pid)]))
    for name, argv in tools:
        path = destination / f"post-measurement-{name}.txt"
        entry = {"tool": name, "file": path.name}
        try:
            completed = command(argv, env=env, check=False)
            payload = completed.stdout + completed.stderr
            path.write_bytes(payload)
            # leaks(1) reports a completed scan that found leaks, not a failed
            # collection. Preserve that separate tool finding explicitly.
            collected = completed.returncode in ((0, 1) if name == "retained-graph" else (0,))
            entry.update(status="PASS" if collected else "UNAVAILABLE",
                         returnCode=completed.returncode, bytes=len(payload), sha256=digest(payload))
            if name == "retained-graph":
                entry["relationshipModel"] = "one guessed parent per allocation, not all retaining references"
                if collected:
                    entry["leaksDetectedByTool"] = completed.returncode == 1
        except (OSError, subprocess.SubprocessError) as error:
            def bytes_(value):
                return value if isinstance(value, bytes) else (value or "").encode()
            payload = bytes_(getattr(error, "stdout", None)) + bytes_(getattr(error, "stderr", None))
            payload += (str(error) + "\n").encode()
            path.write_bytes(payload)
            entry.update(status="UNAVAILABLE", bytes=len(payload), sha256=digest(payload))
        result["tools"].append(entry)
    result["finishedMonotonicNS"] = time.monotonic_ns()
    return result


def run_trial(role, trial, app, runtime_app, home, fixture_root, fixture, env, args, out, windows, display):
    run = out / f"{fixture['responses']}-{trial}-{role}"
    run.mkdir()
    require(not owned_paths(home) and export_defaults(env) is None,
            "next round must start without prior app-owned state")
    require(not product_processes(runtime_app, env), "prior product/helper process remains")
    if runtime_app.exists():
        shutil.rmtree(runtime_app)  # This is only our own disposable runtime copy.
    shutil.copytree(app, runtime_app, symlinks=True)
    seed = preference_seed(fixture_root, dashboard_frame=display.frame_seed)
    seed_bytes = plistlib.dumps(seed, sort_keys=True)
    (run / "settings-seed.plist").write_bytes(seed_bytes)
    command(["/usr/bin/defaults", "import", BUNDLE_ID, run / "settings-seed.plist"], env=env)
    require(export_defaults(env) == seed, "actual prelaunch defaults differ from fixture seed")
    require(source_inventory(fixture_root) == fixture["source"], "source fixture changed before launch")
    info = bundle_manifest(runtime_app)
    executable = runtime_app / "Contents/MacOS" / info["executable"]
    result = {"role": role, "trial": trial, "responses": fixture["responses"], "status": "FAILED",
              "bundle": info, "sameRuntimeAppPath": str(runtime_app), "supportSeed": "absent/empty",
              "settingsSeedSha256": digest(seed_bytes), "sourceSha256": fixture["source"]["sha256"],
              "viewportProtocol": VIEWPORT_PROTOCOL,
              "scope": "cold bootstrap + fixed fully visible dashboard; main process only",
              "stopMethod": "SIGTERM to exact child PID after measurements; not a graceful-shutdown test"}
    process = None
    rows, measured = [], []
    started = time.monotonic()
    gate = None
    try:
        with (run / "app.stdout.log").open("wb") as stdout, (run / "app.stderr.log").open("wb") as stderr, (run / "metrics.jsonl").open("w") as metrics:
            process = subprocess.Popen([str(executable)], cwd=runtime_app.parent, env=env,
                                       stdout=stdout, stderr=stderr, start_new_session=True)
            result["pid"] = process.pid
            sampler = ProcessSampler(process.pid)
            journal = home / "Library/Application Support/CodexTokenBar/diagnostics/v1"
            ledger = home / "Library/Application Support/CodexTokenBar/multi-client-usage.sqlite"
            slot = 0
            while True:
                require(process.poll() is None, f"App exited early: {process.returncode}")
                sample = sampler.sample()
                elapsed = time.monotonic() - started
                visible = windows.windows(process.pid)
                sample.update(elapsedSeconds=elapsed, visibleDashboard=bool(visible), dashboardWindows=visible)
                sample["phase"] = ("bootstrap" if gate is None else
                                   "measure" if time.monotonic() - gate >= args.warmup else "warmup")
                # Preserve even the first rejected window before a gate can
                # raise; a failure must retain its actual x/y/width/height.
                rows.append(sample)
                metrics.write(json.dumps(sample, sort_keys=True) + "\n")
                metrics.flush()
                if gate is None:
                    ready = startup_ready(journal, process.pid)
                    truth = ledger_truth(ledger, fixture) if ready and visible else None
                    if ready and visible and truth and truth["complete"]:
                        dimensions = {key: visible[0][key] for key in ("width", "height")}
                        require(dimensions == DASHBOARD_WINDOW,
                                "actual dashboard dimensions differ from the shared frame seed", "NOT_RUN")
                        require(dashboard_window_fits(visible[0], display.record["after"]),
                                "actual dashboard is clipped by the cloud visible screen", "NOT_RUN")
                        gate = time.monotonic()
                        result.update(startupReady=ready, initialLedger=truth,
                                      bootstrapElapsedSeconds=elapsed, bootstrapCPUSeconds=sample["cpuNS"] / 1e9,
                                      dashboardWindow=dimensions)
                    require(elapsed <= args.startup_timeout,
                            "startup-ready + visible dashboard + exact fixture ledger gate timed out", "NOT_RUN")
                else:
                    require(visible, "dashboard ceased to be naturally visible", "NOT_RUN")
                    require({key: visible[0][key] for key in ("width", "height")} == result["dashboardWindow"],
                            "dashboard dimensions changed", "NOT_RUN")
                    require(dashboard_window_fits(visible[0], display.record["after"]),
                            "dashboard moved outside the cloud visible screen", "NOT_RUN")
                    if sample["phase"] == "measure":
                        measured.append(sample)
                if measured and (measured[-1]["monotonicNS"] - measured[0]["monotonicNS"]) / 1e9 >= args.duration:
                    break
                slot += 1
                time.sleep(max(0, started + slot - time.monotonic()))
            result["measurement"] = summarize(measured)
            result["observedBootstrapPeakFootprintBytes"] = max(
                row["footprintBytes"] for row in rows if row["phase"] == "bootstrap")
            result["observedRunPeakFootprintBytes"] = max(row["footprintBytes"] for row in rows)
            result["lifetimePeakFootprintBytes"] = max(row["lifetimePeakFootprintBytes"] for row in rows)
            # No sampler call or additional metrics row is allowed after this
            # boundary: native heap inspection is deliberately out of band.
            result["measurementEndedMonotonicNS"] = measured[-1]["monotonicNS"]
            result["postMeasurementMemoryDiagnostics"] = post_measurement_memory_diagnostics(
                process.pid, run, env, retained_graph=args.retained_graph)
            result["status"] = "PASS"
    except (BenchError, OSError, ValueError, subprocess.SubprocessError) as error:
        result.update(status=getattr(error, "status", "FAILED"), reason=str(error))
    finally:
        safe_to_archive = True
        try:
            if process is not None:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=15)
                        result["requiredSIGKILL"] = True
                result["exitCodeAfterMeasurement"] = process.returncode
                deadline = time.monotonic() + 10
                remaining = product_processes(runtime_app, env)
                while remaining and time.monotonic() < deadline:
                    time.sleep(0.2)
                    remaining = product_processes(runtime_app, env)
                require(not remaining, "product/bundled helper remains after stopping exact child PID")
        except (BenchError, OSError, subprocess.SubprocessError) as error:
            safe_to_archive = False
            result.update(status="FAILED", reason=f"stop incomplete; state retained in place: {error}")
        # All of these inputs are generated in this disposable runner account.
        try:
            if process is not None and safe_to_archive:
                ledger = home / "Library/Application Support/CodexTokenBar/multi-client-usage.sqlite"
                result["finalLedger"] = ledger_truth(ledger, fixture)
                if result["status"] == "PASS":
                    require(result["finalLedger"] and result["finalLedger"]["complete"], "final ledger differs from fixture truth")
            require(source_inventory(fixture_root) == fixture["source"], "source fixture changed during run")
        except BenchError as error:
            result.update(status="FAILED", reason=str(error))
        try:
            if safe_to_archive:
                result["state"] = archive_state(home, run / "state", env)
            else:
                result["state"] = {"retainedInPlace": True, "paths": list(map(str, owned_paths(home)))}
        except (BenchError, OSError, subprocess.SubprocessError) as error:
            result.update(status="FAILED", reason=f"state archive failed: {error}")
        finally:
            write_json(run / "result.json", result)
    require(result["status"] == "PASS", result.get("reason", "trial did not pass"), result["status"])
    return result


def paired_summary(results):
    pairs = []
    for count, trial in sorted({(row["responses"], row["trial"]) for row in results}):
        pair = {row["role"]: row for row in results if row["responses"] == count and row["trial"] == trial}
        require(set(pair) == {"baseline", "candidate"}, "incomplete pair")
        for field in ("settingsSeedSha256", "sourceSha256", "dashboardWindow"):
            require(pair["baseline"][field] == pair["candidate"][field], f"pair differs in {field}")
        baseline, candidate = pair["baseline"]["measurement"], pair["candidate"]["measurement"]
        ratio = lambda a, b: a / b if b > 0 else None
        pairs.append({"responses": count, "trial": trial,
                      "cpuSecondsRatio": ratio(candidate["cpuSeconds"], baseline["cpuSeconds"]),
                      "medianFootprintRatio": ratio(candidate["footprintBytes"]["median"], baseline["footprintBytes"]["median"]),
                      "medianRSSRatio": ratio(candidate["rssBytes"]["median"], baseline["rssBytes"]["median"])})
    return pairs


def parse_arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-app", required=True, type=Path)
    parser.add_argument("--candidate-app", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--responses", nargs="+", type=int, choices=(2000, 20000), default=[2000, 20000])
    parser.add_argument("--trials", type=int, choices=(3,), default=3)
    parser.add_argument("--warmup", type=int, default=120)
    parser.add_argument("--duration", type=int, default=120)
    parser.add_argument("--startup-timeout", type=int, default=300)
    parser.add_argument("--retained-graph", action="store_true",
                        help="Capture a no-content reference tree only after each trial's final sample")
    args = parser.parse_args(argv)
    require(args.warmup >= 120 and args.duration >= 120 and 30 <= args.startup_timeout <= 1800,
            "warmup/duration must be at least 120s; startup timeout must be 30..1800s", "REFUSED")
    require(len(args.responses) == len(set(args.responses)), "duplicate response case", "REFUSED")
    return args


def main(argv=None):
    args = parse_arguments(argv)
    output = args.output_dir.absolute()
    summary = {"schemaVersion": 2, "viewportProtocol": VIEWPORT_PROTOCOL, "status": "NOT_RUN", "results": [],
               "limitations": ["main-process metrics only; helpers and shared-page family accounting are not covered",
                               "fixed native visible dashboard frame; no hidden/sidebar/retention or credentialed workload",
                               "startup-ready is separately gated on visible window and exact synthetic ledger",
                               "updater and other normal runtime owners are retained; external network timing is uncontrolled",
                               "sequential cold app-state runs share OS filesystem caches; this is not cold disk-cache measurement",
                               "no App clock injection; fixture timestamps are fixed once and real wall-clock advances",
                               "native memory diagnostics run only after the last resource sample"]}
    created_output = False
    display = None
    try:
        home, runner_temp = guard_host(output)
        root = runner_temp / ("tokenbar-whole-app-" + uuid.uuid4().hex)
        output.mkdir(parents=True)
        created_output = True
        root.mkdir()
        gui = command(["/bin/launchctl", "print", f"gui/{os.getuid()}"], check=False)
        require(gui.returncode == 0, "no logged-in GUI bootstrap session", "NOT_RUN")
        runtime_app = root / "runtime/Codex Token Bar.app"
        runtime_app.parent.mkdir()
        # These are copied, never modified in their source build locations.
        bundles = {"baseline": args.baseline_app.resolve(), "candidate": args.candidate_app.resolve()}
        summary["bundles"] = {role: bundle_manifest(app) for role, app in bundles.items()}
        summary.update(actualAccountHome=str(home), runtimeRoot=str(root),
                       actualOS=platform.platform(), architecture=platform.machine(),
                       warmupSeconds=args.warmup, durationSeconds=args.duration,
                       retainedGraphRequested=args.retained_graph,
                       staticFixture=True, productionBuildsPerformed=False,
                       order=["baseline/candidate", "candidate/baseline", "baseline/candidate"])
        # The original account home is passed unchanged; only source locations vary.
        env = clean_environment(home, root / "unused", Path(os.environ.get("TMPDIR", "/tmp")))
        initial_defaults = export_defaults(env)
        summary["initialDefaultsDomain"] = {"present": initial_defaults is not None,
                                             "keyCount": len(initial_defaults or {})}
        require(initial_defaults is None, "preexisting product defaults domain", "REFUSED")
        require(not product_processes(env=env),
                "another product process is running", "REFUSED")
        try:
            windows = VisibleWindowProbe()
        except (OSError, ValueError) as error:
            raise BenchError(f"CoreGraphics window observation unavailable: {error}", "NOT_RUN") from error
        display = BenchmarkDisplay(windows, env)
        summary["benchmarkDisplay"] = display.record
        display.configure()
        # Older than recent-response and active-session windows before the first
        # run; no late pair silently measures 30-minute row expiry instead.
        anchor = int(time.time()) - 3600
        local_day = dt.date.today()
        day_start = dt.datetime.combine(local_day, dt.time.min).timestamp()
        require(anchor - 600 >= day_start, "historical fixture would cross the local day boundary", "NOT_RUN")
        for count in args.responses:
            fixture_root = root / f"fixture-{count}"
            fixture = generate_fixture(fixture_root, count, anchor)
            write_json(output / f"fixture-{count}.json", fixture)
            env = clean_environment(home, fixture_root, Path(os.environ.get("TMPDIR", "/tmp")))
            for trial in range(1, args.trials + 1):
                order = ("candidate", "baseline") if trial == 2 else ("baseline", "candidate")
                for role in order:
                    require(dt.date.today() == local_day, "local calendar day changed across paired runs", "NOT_RUN")
                    summary["results"].append(run_trial(role, trial, bundles[role], runtime_app, home,
                                                         fixture_root, fixture, env, args, output, windows, display))
                    require(dt.date.today() == local_day, "local calendar day changed during run", "NOT_RUN")
                    write_json(output / "summary.json", summary)
        summary["pairs"] = paired_summary(summary["results"])
        summary["status"] = "PASS"
    except (BenchError, OSError, ValueError, subprocess.SubprocessError) as error:
        summary.update(status=getattr(error, "status", "FAILED"), reason=str(error))
    finally:
        if display is not None:
            try:
                display.restore()
            except (BenchError, OSError) as error:
                summary.update(status="FAILED", reason=str(error))
    if created_output:
        write_json(output / "summary.json", summary)
    print(json.dumps({"status": summary["status"], "reason": summary.get("reason"), "evidence": str(output)}, sort_keys=True))
    return 0 if summary["status"] == "PASS" else (2 if summary["status"] in ("NOT_RUN", "REFUSED") else 1)


if __name__ == "__main__":
    raise SystemExit(main())
