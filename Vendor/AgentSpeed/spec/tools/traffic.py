#!/usr/bin/env python3
"""Reference implementation of METRICS 10 (network traffic).

Covers byte formatting (10.11), process attribution (10.5, 10.6), deltas (10.4), live rates (10.7), today totals
(10.8) and daily history rows (10.9), and checks every case in spec/fixtures/traffic-cases.json.

Usage: python3 spec/tools/traffic.py [--fixtures PATH] [--verbose]
"""

from __future__ import annotations

import argparse
import json
import sys
from decimal import ROUND_HALF_UP, Decimal
from pathlib import Path

DEFAULT_FIXTURES = Path(__file__).resolve().parent.parent / "fixtures" / "traffic-cases.json"
DAY_MS = 86_400_000
RATE_WINDOW_MS = 3_000
GAP_MS = 15_000
FORGET_AFTER = 3
MAX_BYTES_PER_SECOND = 12_500_000_000
SCRIPT_HOSTS = {"node", "nodejs", "bun", "deno"}
SOURCES = ("codex", "claudeCode", "claudeDesktop", "deepseek", "opencode", "gemini", "omp", "antigravity", "workbuddy",
           "workbuddyAi", "zcode", "kimi", "grokBuild")


# ---------------------------------------------------------------------------------------------------- formatting

def _format(value: float, units: list[str]) -> str:
    """Three significant digits; a value that rounds to 1000 moves to the next unit (METRICS 10.11)."""
    x = Decimal(str(max(0.0, value)))
    unit = 0
    while True:
        if unit == 0:
            shown = x.quantize(Decimal(1), rounding=ROUND_HALF_UP)
            if shown < 1000 or unit == len(units) - 1:
                return f"{shown} {units[unit]}"
        else:
            if x < Decimal("9.995"):
                shown = x.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
            elif x < Decimal("99.95"):
                shown = x.quantize(Decimal("0.1"), rounding=ROUND_HALF_UP)
            else:
                shown = x.quantize(Decimal(1), rounding=ROUND_HALF_UP)
            if shown < 1000 or unit == len(units) - 1:
                return f"{shown} {units[unit]}"
        x = x / 1000
        unit += 1


def format_rate(bytes_per_second: float, bits: bool = False) -> str:
    if bits:
        return _format(bytes_per_second * 8, ["b/s", "Kb/s", "Mb/s", "Gb/s"])
    return _format(bytes_per_second, ["B/s", "KB/s", "MB/s", "GB/s"])


def format_total(total: float) -> str:
    return _format(total, ["B", "KB", "MB", "GB", "TB"])


# ---------------------------------------------------------------------------------------------------- attribution

class Env:
    def __init__(self, case: dict):
        self.platform = case.get("platform", "macos")
        self.home = case.get("home", "/Users/dev")
        self.vars = case.get("env", {})

    def norm(self, path: str | None) -> str:
        if not path:
            return ""
        p = path.replace("\\", "/")
        if p.startswith("~/"):
            p = self.home.replace("\\", "/") + p[1:]
        for key, value in self.vars.items():
            p = p.replace(f"%{key}%", value.replace("\\", "/"))
        p = p.rstrip("/")
        return p.lower() if self.platform == "windows" else p

    def name(self, exe: str | None) -> str:
        """File name without `.exe`; case is kept (CLI binaries are lower-case, desktop apps capitalized)."""
        base = (exe or "").replace("\\", "/").rsplit("/", 1)[-1]
        if self.platform == "windows" and base.lower().endswith(".exe"):
            base = base[:-4]
        return base


CLAUDE_DESKTOP_CODE = {
    "macos": ["~/Library/Application Support/Claude/claude-code/"],
    "windows": ["%LOCALAPPDATA%/Claude/claude-code/", "%LOCALAPPDATA%/Claude-3p/claude-code/", "%APPDATA%/Claude/claude-code/"],
}
CLAUDE_DESKTOP_APP = {
    "macos": ["/Applications/Claude.app/Contents/MacOS/Claude"],
    "windows": ["%LOCALAPPDATA%/AnthropicClaude/"],
}
# Desktop apps' own executables, never agent processes (METRICS 10.5); Windows paths also by package folder.
DESKTOP_APPS = {
    "macos": ["/Applications/Claude.app/Contents/MacOS/Claude", "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
              "/Applications/Codex.app/Contents/MacOS/Codex", "/Applications/OpenCode.app/Contents/MacOS/OpenCode",
              "/Applications/Antigravity.app/Contents/MacOS/Antigravity"],
    "windows": ["%LOCALAPPDATA%/AnthropicClaude/"],
}
DESKTOP_PACKAGES = ("/windowsapps/claude_", "/windowsapps/openai.codex_", "/windowsapps/openai.chatgpt")
# WorkBuddy runs its embedded CLI on the app's own executable (Electron as Node): macOS by the bundle id of the .app
# whose Contents/MacOS holds the executable, Windows by the executable's name.
WORKBUDDY_APPS = {
    "macos": {"com.tencent.workbuddy.mac": "workbuddy", "com.workbuddy.workbuddy-ai": "workbuddyAi"},
    "windows": {"WorkBuddy": "workbuddy", "WorkBuddyAI": "workbuddyAi"},
}
WORKBUDDY_CLI = "/app.asar.unpacked/cli/"
DEEPSEEK_APP = {
    "macos": ["/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness"],
    "windows": [],
}


def _under(env: Env, path: str, prefixes: list[str]) -> bool:
    p = env.norm(path) + "/"
    return any(p.startswith(env.norm(prefix) + "/") or p == env.norm(prefix) + "/" for prefix in prefixes)


def _is_claude_desktop_app(env: Env, proc: dict) -> bool:
    exe = proc.get("exe") or ""
    if _under(env, exe, CLAUDE_DESKTOP_APP[env.platform]):
        return True
    return env.platform == "windows" and env.name(exe) == "Claude" and "/windowsapps/claude_" in env.norm(exe)


def _is_desktop_app(env: Env, proc: dict) -> bool:
    exe = proc.get("exe") or ""
    if _under(env, exe, DESKTOP_APPS[env.platform]):
        return True
    return env.platform == "windows" and any(k in env.norm(exe) for k in DESKTOP_PACKAGES) and env.name(exe)[:1].isupper()


def _script_args(env: Env, proc: dict) -> str:
    if env.name(proc.get("exe")).lower() not in SCRIPT_HOSTS:
        return ""
    return " ".join(env.norm(a) if ("/" in a or "\\" in a) else a for a in (proc.get("args") or [])[1:])


def match_source(env: Env, proc: dict, ancestors: list[dict]) -> str | None:
    """The source whose agent-process row (METRICS 10.5) matches, or None."""
    exe = proc.get("exe") or ""
    if _is_desktop_app(env, proc):
        return None
    name = env.name(exe)
    args = proc.get("args") or []
    script = _script_args(env, proc)
    if name == "claude":
        if _under(env, exe, CLAUDE_DESKTOP_CODE[env.platform]) or any(_is_claude_desktop_app(env, a) for a in ancestors):
            return "claudeDesktop"
        if "--chrome-native-host" in args:
            return None
        return "claudeCode"
    if _under(env, exe, ["~/.local/share/claude/versions"]):
        return None if "--chrome-native-host" in args else "claudeCode"
    if "@anthropic-ai/claude-code/" in script:
        return "claudeCode"
    if name == "codex" or (name.startswith("codex-") and any(k in name for k in ("x86_64", "aarch64", "apple-darwin", "linux", "windows"))):
        return "codex"
    if "@openai/codex/bin/codex.js" in script:
        return "codex"
    if name == "dsh" or _under(env, exe, DEEPSEEK_APP[env.platform]) or (env.platform == "windows" and name == "deepseek harness"):
        return "deepseek"
    if name in ("opencode", "opencode-cli") or (name.startswith("opencode-") and any(k in name for k in ("darwin", "linux", "windows"))):
        return "opencode"
    if "opencode-ai/bin/opencode" in script:
        return "opencode"
    if "/@google/gemini-cli/" in script or name == "gemini":
        return "gemini"
    if name == "omp" or "/@oh-my-pi/" in script or "/oh-my-pi/" in script:
        return "omp"
    if name == "agy" or name.startswith("language_server_"):
        return "antigravity"
    if name in ("zcode", "zcode-cli") or "/@zcode/cli/" in script:
        return "zcode"
    if name in ("kimi", "kimi-code") or "/@moonshot-ai/kimi-code/" in script:
        return "kimi"
    if name in ("grok", "grok-build", "xai-grok-pager"):
        return "grokBuild"
    edition = WORKBUDDY_APPS[env.platform].get(proc.get("bundle") if env.platform == "macos" else name)
    if edition and any(WORKBUDDY_CLI in env.norm(a) for a in args[1:]):
        return edition
    return None


class ProcessTable:
    """Sticky classification of process identities (pid, start) as METRICS 10.5 describes."""

    def __init__(self, env: Env):
        self.env = env
        self.known: dict[tuple, dict] = {}
        self.procs: dict[tuple, dict] = {}

    def refresh(self, processes: list[dict]) -> None:
        by_pid = {p["pid"]: p for p in processes}
        for p in processes:
            self.procs[(p["pid"], p["start"])] = p

        def parent(p: dict) -> dict | None:
            q = by_pid.get(p.get("ppid"))
            if q is None or q is p or q["start"] > p["start"]:
                return None
            return q

        for p in sorted(processes, key=lambda x: (x["start"], x["pid"])):
            key = (p["pid"], p["start"])
            if key in self.known:
                continue
            ancestors, cursor, seen = [], parent(p), {key}
            while cursor is not None and (cursor["pid"], cursor["start"]) not in seen:
                seen.add((cursor["pid"], cursor["start"]))
                ancestors.append(cursor)
                cursor = parent(cursor)
            nearest = None
            for a in ancestors:
                c = self.known.get((a["pid"], a["start"]))
                if c and c["role"] in ("agent", "self"):
                    nearest = c
                    break
            source = match_source(self.env, p, ancestors)
            if source and (nearest is None or nearest["source"] != source):
                c = {"role": "agent", "source": source, "root": key}
            elif source:
                c = {"role": "self", "source": source, "root": nearest["root"]}
            elif nearest:
                c = {"role": "tool", "source": nearest["source"], "root": nearest["root"]}
            else:
                c = {"role": None, "source": None, "root": None}
            self.known[key] = c

    def classify(self, key: tuple) -> dict | None:
        return self.known.get(key)


# ---------------------------------------------------------------------------------------------------- engine

class Series:
    """Deltas of one counter series with sample times, for live rates (METRICS 10.7)."""

    def __init__(self):
        self.points: list[tuple[int, int, int]] = []  # (t, rx, tx); a gap restarts the list

    def add(self, t: int, rx: int, tx: int, gap: bool) -> None:
        if gap:
            self.points = [(t, 0, 0)]
            return
        self.points.append((t, rx, tx))
        while len(self.points) > 2 and self.points[1][0] <= t - RATE_WINDOW_MS:
            self.points.pop(0)

    def rate(self) -> tuple[float, float] | None:
        if len(self.points) < 2:
            return None
        t = self.points[-1][0]
        start = 0
        for i, p in enumerate(self.points):
            if p[0] <= t - RATE_WINDOW_MS:
                start = i
        t0 = self.points[start][0]
        rx = sum(p[1] for p in self.points[start + 1:])
        tx = sum(p[2] for p in self.points[start + 1:])
        seconds = (t - t0) / 1000
        return (rx / seconds, tx / seconds)


def _zero_source() -> dict:
    return {"rxSelf": 0, "txSelf": 0, "rxTools": 0, "txTools": 0, "unassignedRx": 0, "unassignedTx": 0}


class Engine:
    def __init__(self, case: dict):
        self.env = Env(case)
        self.table = ProcessTable(self.env)
        self.tz = case.get("tzOffsetMs", 0)
        self.agents = {a["id"]: a for a in case.get("agents", [])}
        self.prev_t: int | None = None
        self.ifaces: dict[str, tuple[int, int]] = {}
        self.stream: str | None = None
        self.counters: dict[tuple, tuple[int, int]] = {}
        self.missing: dict[tuple, int] = {}
        self.prev_counter_t: int | None = None
        self.machine_series = Series()
        self.source_series: dict[str, Series] = {}
        self.agent_series: dict[str, Series] = {}
        self.days: dict[str, dict] = {}
        self.agent_days: dict[str, dict[str, dict]] = {}
        self.rates: dict[int, dict] = {}

    # -- helpers
    def date(self, t: int) -> str:
        import datetime
        d = datetime.datetime.fromtimestamp((t + self.tz) / 1000, tz=datetime.timezone.utc)
        return d.strftime("%Y-%m-%d")

    def day(self, t: int) -> dict:
        key = self.date(t)
        if key not in self.days:
            self.days[key] = {"machine": {"rx": 0, "tx": 0, "sampledMs": 0}, "sources": {}, "processSampledMs": 0}
        return self.days[key]

    def root_of(self, agent_id: str) -> str:
        seen = set()
        a = self.agents[agent_id]
        while a.get("parent") and a["parent"] in self.agents and a["id"] not in seen:
            seen.add(a["id"])
            a = self.agents[a["parent"]]
        return a["id"]

    def tree_active(self, root: str, start: int, end: int) -> bool:
        for a in self.agents.values():
            if self.root_of(a["id"]) != root:
                continue
            for lo, hi in a.get("active", []):
                if lo <= end and hi >= start - 2000:
                    return True
        return False

    def candidates(self, source: str, root_key: tuple, start: int, end: int) -> list[str]:
        roots = sorted({self.root_of(a["id"]) for a in self.agents.values() if a["source"] == source})
        cands = [r for r in roots if self.tree_active(r, start, end)]
        if not cands:
            return []
        proc = self.table.procs.get(root_key, {})
        members = [k for k, c in self.table.known.items() if c["root"] == root_key and c["role"] in ("agent", "self")]
        open_files = set()
        for k in members:
            for f in self.table.procs.get(k, {}).get("openFiles", []) or []:
                open_files.add(self.env.norm(f))
        if open_files:
            owned = [r for r in cands if any(self.env.norm(a.get("transcript")) in open_files
                                             for a in self.agents.values() if self.root_of(a["id"]) == r)]
            if owned:
                cands = owned
        cwd = proc.get("cwd")
        if cwd:
            same = [r for r in cands if self.env.norm(self.agents[r].get("cwdPath")) == self.env.norm(cwd)]
            if same:
                cands = same
        return cands

    # -- one tick
    def tick(self, sample: dict) -> None:
        t = sample["t"]
        dt = None if self.prev_t is None else t - self.prev_t
        gap = dt is None or dt > GAP_MS
        self.prev_t = t
        if "processes" in sample:
            self.table.refresh(sample["processes"])
        day = self.day(t)

        # machine counters (10.2, 10.4)
        if sample.get("interfaces") is not None:
            mrx = mtx = 0
            current = {name: tuple(v) for name, v in sample["interfaces"].items()}
            for name, (rx, tx) in current.items():
                if name in self.ifaces:
                    prx, ptx = self.ifaces[name]
                    mrx += self._delta(prx, rx, dt)
                    mtx += self._delta(ptx, tx, dt)
            self.ifaces = current
            day["machine"]["rx"] += mrx
            day["machine"]["tx"] += mtx
            if dt is not None and dt <= GAP_MS:
                day["machine"]["sampledMs"] += dt
            self.machine_series.add(t, mrx, mtx, gap)

        # process counters (10.3, 10.4)
        counters = sample.get("counters")
        if counters is not None:
            cdt = None if self.prev_counter_t is None else t - self.prev_counter_t
            cgap = cdt is None or cdt > GAP_MS
            self.prev_counter_t = t
            new_stream = counters["stream"] != self.stream and not counters.get("continues", False)
            self.stream = counters["stream"]
            if new_stream:
                self.counters, self.missing = {}, {}
            if cdt is not None and cdt <= GAP_MS and not new_stream:
                day["processSampledMs"] += cdt
            per_root: dict[tuple, dict] = {}
            seen = set()
            for row in counters["rows"]:
                key = (row["pid"], row["start"])
                proc = self.table.procs.get(key)
                if proc is None:
                    continue
                seen.add(key)
                if new_stream:
                    d_rx = d_tx = 0
                elif key in self.counters:
                    prx, ptx = self.counters[key]
                    d_rx, d_tx = self._delta(prx, row["rx"], cdt), self._delta(ptx, row["tx"], cdt)
                else:
                    d_rx, d_tx = row["rx"], row["tx"]
                self.counters[key] = (row["rx"], row["tx"])
                c = self.table.classify(key)
                if not c or not c["role"] or (d_rx == 0 and d_tx == 0):
                    continue
                kind = "tools" if c["role"] == "tool" else "self"
                acc = per_root.setdefault(c["root"], {"source": c["source"], "self": [0, 0], "tools": [0, 0]})
                acc[kind][0] += d_rx
                acc[kind][1] += d_tx
            for key in list(self.counters):
                if key not in seen:
                    self.missing[key] = self.missing.get(key, 0) + 1
                    if self.missing[key] >= FORGET_AFTER:
                        del self.counters[key]
                        del self.missing[key]
                else:
                    self.missing.pop(key, None)

            totals: dict[str, list[int]] = {}
            agent_totals: dict[str, list[int]] = {}
            start = (t - cdt) if cdt is not None else t
            for root_key, acc in per_root.items():
                s = acc["source"]
                src = day["sources"].setdefault(s, _zero_source())
                src["rxSelf"] += acc["self"][0]
                src["txSelf"] += acc["self"][1]
                src["rxTools"] += acc["tools"][0]
                src["txTools"] += acc["tools"][1]
                rx = acc["self"][0] + acc["tools"][0]
                tx = acc["self"][1] + acc["tools"][1]
                tot = totals.setdefault(s, [0, 0, 0, 0])
                tot[0] += acc["self"][0]
                tot[1] += acc["self"][1]
                tot[2] += acc["tools"][0]
                tot[3] += acc["tools"][1]
                cands = self.candidates(s, root_key, start, t)
                if len(cands) == 1:
                    a = self.agent_days.setdefault(self.date(t), {}).setdefault(cands[0], {"rxSelf": 0, "txSelf": 0, "rxTools": 0, "txTools": 0})
                    a["rxSelf"] += acc["self"][0]
                    a["txSelf"] += acc["self"][1]
                    a["rxTools"] += acc["tools"][0]
                    a["txTools"] += acc["tools"][1]
                    at = agent_totals.setdefault(cands[0], [0, 0, 0, 0])
                    for i, v in enumerate((acc["self"][0], acc["self"][1], acc["tools"][0], acc["tools"][1])):
                        at[i] += v
                else:
                    src["unassignedRx"] += rx
                    src["unassignedTx"] += tx
            for s in SOURCES:
                self.source_series.setdefault(s, SeriesPair()).add(t, totals.get(s, [0, 0, 0, 0]), cgap)
            for a in sorted({self.root_of(i) for i in self.agents}):
                self.agent_series.setdefault(a, SeriesPair()).add(t, agent_totals.get(a, [0, 0, 0, 0]), cgap)

        self.rates[t] = self.snapshot_rates()

    @staticmethod
    def _delta(prev: int, cur: int, dt: int | None) -> int:
        if cur < prev:
            return 0
        d = cur - prev
        if dt is not None and d > MAX_BYTES_PER_SECOND * max(dt, 1) / 1000:
            return 0
        return d

    def snapshot_rates(self) -> dict:
        def fmt(r):
            return None if r is None else [round(r[0], 3), round(r[1], 3)]
        return {
            "machine": fmt(self.machine_series.rate()),
            "sources": {s: series.rates() for s, series in sorted(self.source_series.items())},
            "agents": {a: series.rates() for a, series in sorted(self.agent_series.items())},
        }

    def history(self) -> list[dict]:
        rows = []
        for date in sorted(self.days):
            d = self.days[date]
            rows.append({"day": date, "key": "machine", "rx": d["machine"]["rx"], "tx": d["machine"]["tx"],
                         "rxTools": 0, "txTools": 0, "sampledMs": d["machine"]["sampledMs"]})
            for s in SOURCES:
                if s in d["sources"]:
                    v = d["sources"][s]
                    rows.append({"day": date, "key": s, "rx": v["rxSelf"], "tx": v["txSelf"], "rxTools": v["rxTools"],
                                 "txTools": v["txTools"], "sampledMs": d["processSampledMs"]})
        return rows


class SeriesPair:
    """Self and tools series of a source or agent; rates with and without tools (includeTools)."""

    def __init__(self):
        self.self_ = Series()
        self.all_ = Series()

    def add(self, t: int, v: list[int], gap: bool) -> None:
        self.self_.add(t, v[0], v[1], gap)
        self.all_.add(t, v[0] + v[2], v[1] + v[3], gap)

    def rates(self) -> dict:
        def fmt(r):
            return None if r is None else [round(r[0], 3), round(r[1], 3)]
        return {"withTools": fmt(self.all_.rate()), "selfOnly": fmt(self.self_.rate())}


# ---------------------------------------------------------------------------------------------------- checks

def run_case(case: dict) -> dict:
    engine = Engine(case)
    for sample in case["samples"]:
        engine.tick(sample)
    today_date = engine.date(case["samples"][-1]["t"])
    today = engine.days.get(today_date, {"machine": {}, "sources": {}})
    return {
        "classes": {f"{k[0]}": (c["source"] and f"{c['source']}/{c['role']}") for k, c in sorted(engine.table.known.items())},
        "today": {"machine": today["machine"], "sources": today["sources"],
                  "agents": engine.agent_days.get(today_date, {})},
        "rates": {str(t): engine.rates[t] for t in case.get("rateTimes", [])},
        "history": engine.history(),
    }


def _diff(path: str, want, got, out: list) -> None:
    if isinstance(want, dict) and isinstance(got, dict):
        for k in want:
            _diff(f"{path}.{k}", want[k], got.get(k), out)
        return
    if isinstance(want, list) and isinstance(got, list) and len(want) == len(got):
        for i, (w, g) in enumerate(zip(want, got)):
            _diff(f"{path}[{i}]", w, g, out)
        return
    if isinstance(want, float) or isinstance(got, float):
        if want is None or got is None or abs(want - got) > 0.001:
            out.append(f"{path}: want {want!r}, got {got!r}")
        return
    if want != got:
        out.append(f"{path}: want {want!r}, got {got!r}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--fixtures", type=Path, default=DEFAULT_FIXTURES)
    parser.add_argument("--verbose", action="store_true", help="print each case's computed result")
    args = parser.parse_args()
    data = json.loads(args.fixtures.read_text(encoding="utf-8"))
    failures: list[str] = []
    checked = 0

    for row in data["format"]:
        got = format_total(row["value"]) if row["kind"] == "total" else format_rate(row["value"], row["kind"] == "bits")
        checked += 1
        if got != row["text"].replace(" ", " "):
            failures.append(f"format {row}: got {got!r}")

    for case in data["cases"]:
        result = run_case(case)
        if args.verbose:
            print(case["name"], json.dumps(result, ensure_ascii=False, indent=1))
        out: list[str] = []
        _diff("", case["expected"], result, out)
        checked += 1
        failures.extend(f"{case['name']}{line}" for line in out)

    if failures:
        print("\n".join(failures))
        print(f"traffic: {len(failures)} failure(s) in {checked} checks")
        return 1
    print(f"traffic: {checked} checks passed ({len(data['format'])} formats, {len(data['cases'])} cases)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
