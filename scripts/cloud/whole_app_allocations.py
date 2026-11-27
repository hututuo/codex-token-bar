#!/usr/bin/env python3
"""Collect bounded allocation stacks on a disposable cloud runner.

This single instrumented candidate trial attributes selected live allocations.
Its CPU, RSS and footprint observations cannot be used for performance acceptance.
Importing the module never starts a process or loads a native framework.
"""
from __future__ import annotations

import argparse
import datetime as dt
from functools import partial
import os
from pathlib import Path
import platform
import re
import selectors
import subprocess
import time
import uuid

import whole_app_benchmark as bench

PURPOSE = "allocation-diagnostic"
HEAP_PATTERN = ".*[65536+]"
MAX_ADDRESSES = 4
HEAP_BYTES = 8 * 1024 * 1024
HISTORY_BYTES = 64 * 1024
HEAP_SECONDS = 60
HISTORY_SECONDS = 10
COLLECTION_SECONDS = 120
SELECTION_PROFILE = "data-string-float-v1"
SELECTION_ROLES = ("data-largest", "data-exact-98304", "string-array-largest", "float-array-largest")
SELECTION_STRATEGY = ("largest Data, another exact 98304-byte Data, largest String array, largest Float array; "
                      "fill missing roles from remaining largest blocks")
EXACT_64K_PROFILE = "exact-64k-spread-v1"
SELECTION_PROFILES = {
    SELECTION_PROFILE: (SELECTION_ROLES, SELECTION_STRATEGY),
    EXACT_64K_PROFILE: (
        tuple(f"exact-64k-spread-{index}" for index in range(1, MAX_ADDRESSES + 1)),
        "exact 65536-byte candidates sorted by numeric address; up to four evenly spread ranks "
        "including endpoints, without heap-label filtering or other-size fallback; "
        "ranks describe only complete records in the captured heap output, not ownership or statistical coverage",
    ),
}


def selection_configuration(profile):
    if profile not in SELECTION_PROFILES:
        raise ValueError(f"unknown allocation selection profile: {profile}")
    return SELECTION_PROFILES[profile]


def complete_lines(text):
    return [line.rstrip("\r\n") for line in text.splitlines(keepends=True) if line.endswith("\n")]


def parse_heap_addresses(text, limit=MAX_ADDRESSES):
    """Use complete address records only; never interpret truncated text as argv."""
    found = {}
    for line in complete_lines(text):
        match = re.fullmatch(r"\s*(0x[0-9A-Fa-f]+):\s+(.+)\s+\((\d+) bytes\)\s*", line)
        if match and int(match[1], 16) > 0:
            address = hex(int(match[1], 16))
            found.setdefault(address, {"address": address, "heapType": match[2].strip(),
                                       "heapAllocatedBytes": int(match[3])})
    return sorted(found.values(), key=lambda row: (-row["heapAllocatedBytes"], row["address"]))[:max(0, min(limit, MAX_ADDRESSES))]


def select_heap_addresses(text, profile=SELECTION_PROFILE):
    """Sample complete records under an explicit profile; labels do not prove owners."""
    roles, _ = selection_configuration(profile)
    # Reuse strict parsing, but collect each line so selection sees more than four.
    rows = {}
    for line in complete_lines(text):
        for row in parse_heap_addresses(line + "\n", limit=1):
            rows.setdefault(row["address"], row)
    if profile == EXACT_64K_PROFILE:
        pool = sorted((row for row in rows.values() if row["heapAllocatedBytes"] == 65536),
                      key=lambda row: int(row["address"], 16))
        count = min(MAX_ADDRESSES, len(pool))
        ranks = ([index * (len(pool) - 1) // (count - 1) for index in range(count)]
                 if count > 1 else [0] if count else [])
        return [dict(pool[rank], selectionRole=roles[index], selectionPoolCount=len(pool),
                     selectionPoolRank=rank) for index, rank in enumerate(ranks)]
    ordered = sorted(rows.values(), key=lambda row: (-row["heapAllocatedBytes"], row["address"]))
    selected, seen = [], set()
    targets = (("data-largest", "__DataStorage._bytes (malloc)", None),
               ("data-exact-98304", "__DataStorage._bytes (malloc)", 98304),
               ("string-array-largest", "Swift._ContiguousArrayStorage<Swift.String>", None),
               ("float-array-largest", "Swift._ContiguousArrayStorage<Swift.Float>", None))
    for role, heap_type, size in targets:
        row = next((row for row in ordered if row["address"] not in seen
                    and row["heapType"] == heap_type
                    and (size is None or row["heapAllocatedBytes"] == size)), None)
        if row is not None:
            selected.append(dict(row, selectionRole=role))
            seen.add(row["address"])
    for row in ordered:
        if len(selected) >= MAX_ADDRESSES:
            break
        if row["address"] not in seen:
            selected.append(dict(row, selectionRole="fallback-largest"))
            seen.add(row["address"])
    return selected


def parse_history_groups(text):
    groups = []
    for line in complete_lines(text):
        match = re.fullmatch(r"\s*(\d+) calls? for (\d+) bytes:\s*(.*)", line)
        if match:
            groups.append({"allocationCount": int(match[1]), "totalBytes": int(match[2]),
                           "frameLines": [match[3]] if match[3] else []})
        elif groups:
            groups[-1]["frameLines"].append(line)
    return groups


def has_stack(group):
    """Require frame-shaped evidence, not an address inside an error message."""
    if group["allocationCount"] <= 0 or group["totalBytes"] <= 0:
        return False
    for line in group["frameLines"]:
        if re.search(r"no (?:stack|allocation)|not (?:live|found)|denied|unable|error|usage:", line, re.I):
            continue
        if re.search(r"^\s*\d+\s+\S+\s+0x[0-9a-f]+\b|\S+\s+\(in [^)]+\)|0x[0-9a-f]+\s+(?:\S+\s+)?\+\s*\d+", line, re.I):
            return True
    return False


def bounded_capture(argv, env, destination, timeout, max_bytes):
    """Stream merged stdout/stderr under one byte cap and reap this exact helper."""
    bench.require(timeout > 0 and max_bytes > 0, "capture bounds must be positive")
    result = {"argv": list(map(str, argv)), "file": destination.name,
              "startedMonotonicNS": time.monotonic_ns(), "returnCode": None,
              "timedOut": False, "truncated": False, "status": "UNAVAILABLE"}
    payload = bytearray()
    process = None
    deadline = time.monotonic() + timeout
    try:
        with selectors.DefaultSelector() as selector:
            process = subprocess.Popen(result["argv"], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            os.set_blocking(process.stdout.fileno(), False)
            selector.register(process.stdout, selectors.EVENT_READ)
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    result["timedOut"] = True
                    break
                for key, _ in selector.select(min(remaining, 0.1)):
                    chunk = os.read(key.fileobj.fileno(), min(65536, max_bytes - len(payload) + 1))
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    room = max_bytes - len(payload)
                    payload.extend(chunk[:room])
                    if len(chunk) > room:
                        result["truncated"] = True
                        break
                if result["truncated"]:
                    break
            if result["timedOut"] or result["truncated"]:
                process.kill()
            try:
                process.wait(timeout=max(0.01, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                result["timedOut"] = True
                process.kill()
                process.wait(timeout=1)
            result["returnCode"] = process.returncode
    except (OSError, subprocess.SubprocessError) as error:
        result["reason"] = str(error)
    finally:
        try:
            if process is not None and process.poll() is None:
                process.kill()
                process.wait(timeout=1)
        except (OSError, subprocess.SubprocessError) as error:
            result.update(cleanupFailed=True, cleanupReason=str(error))
        finally:
            if process is not None:
                for stream in (process.stdout, process.stderr):
                    if stream is not None:
                        try:
                            stream.close()
                        except OSError as error:
                            result.update(cleanupFailed=True, cleanupReason=str(error))
            destination.write_bytes(payload)
            result.update(bytes=len(payload), sha256=bench.digest(payload), finishedMonotonicNS=time.monotonic_ns())
    if result["returnCode"] == 0 and not result["timedOut"] and not result["truncated"] and not result.get("cleanupFailed"):
        result["status"] = "COLLECTED"
    return result


def collect_allocations(process, destination, env, profile=SELECTION_PROFILE, class_summary=False):
    """Inspect selected live blocks after sampling; selection is not ownership proof."""
    roles, strategy = selection_configuration(profile)
    started = time.monotonic_ns()
    deadline = time.monotonic() + COLLECTION_SECONDS
    result = {"purpose": PURPOSE, "outsideMeasurement": True, "startedMonotonicNS": started,
              "status": "UNAVAILABLE", "tools": [], "allocations": [],
              "selectionPattern": HEAP_PATTERN, "maxAddresses": MAX_ADDRESSES,
              "selectionProfile": profile, "selectionStrategy": strategy,
              "missingSelectionRoles": list(roles),
              "classSummaryRequested": class_summary,
              "selectedLiveAddressesOnly": True,
              "limits": {"seconds": COLLECTION_SECONDS, "heapBytes": HEAP_BYTES,
                         "heapSeconds": HEAP_SECONDS,
                         "historyBytesPerAddress": HISTORY_BYTES,
                         "historySecondsPerAddress": HISTORY_SECONDS},
              "limitations": ["sampled allocation stacks are not retaining paths or complete heap coverage",
                              "a selected address can be released or reused before stack capture",
                              "requested stack logging is only confirmed where recorded frames are obtained"]}
    if class_summary:
        result["limits"].update(classSummarySeconds=HEAP_SECONDS, classSummaryBytes=HEAP_BYTES)
        result["classSummary"] = {"status": "SKIPPED",
                                  "reason": "exact App child exited or collection deadline reached"}
    bench.write_json(destination / "allocation-diagnostics.json", result)
    if process.poll() is not None:
        result["reason"] = "exact App child exited before collection"
    else:
        heap_path = destination / "allocation-heap-addresses.txt"
        heap = bounded_capture(["/usr/bin/heap", "-s", "--noContent", "--addresses=" + HEAP_PATTERN,
                                str(process.pid)], env, heap_path,
                               min(HEAP_SECONDS, max(0.01, deadline - time.monotonic())), HEAP_BYTES)
        heap["tool"] = "heap"
        result["tools"].append(heap)
        bench.write_json(destination / "allocation-diagnostics.json", result)
        addresses = select_heap_addresses(heap_path.read_text(errors="replace"), profile=profile) if (
            heap["returnCode"] == 0 or heap["truncated"] or heap["timedOut"]) else []
        result["missingSelectionRoles"] = [role for role in roles if not any(
            row["selectionRole"] == role for row in addresses)]
        result["incompleteCoverage"] = heap["truncated"] or heap["timedOut"]
        selected_at = time.monotonic_ns()
        for row in addresses:
            entry = {**row, "selectedAtMonotonicNS": selected_at, "status": "UNAVAILABLE", "groups": []}
            result["allocations"].append(entry)
            if process.poll() is not None or time.monotonic() >= deadline:
                entry.update(status="SKIPPED", reason="App child exited or collection deadline reached")
                continue
            path = destination / f"allocation-history-{row['address']}.txt"
            captured = bounded_capture(["/usr/bin/malloc_history", str(process.pid), "-allBySize", "-fullStacks",
                                        row["address"]], env, path,
                                       min(HISTORY_SECONDS, max(0.01, deadline - time.monotonic())), HISTORY_BYTES)
            captured.update(tool="malloc_history", address=row["address"])
            result["tools"].append(captured)
            bench.write_json(destination / "allocation-diagnostics.json", result)
            groups = parse_history_groups(path.read_text(errors="replace"))
            recorded = any(has_stack(group) for group in groups) and (
                captured["returnCode"] == 0 or captured["truncated"] or captured["timedOut"])
            entry.update(groups=groups, capturedAtMonotonicNS=captured["finishedMonotonicNS"],
                         rawFile=path.name, capturedBytes=captured["bytes"], sha256=captured["sha256"],
                         returnCode=captured["returnCode"],
                         truncated=captured["truncated"], timedOut=captured["timedOut"],
                         status="COLLECTED" if recorded else "UNAVAILABLE")
            if not recorded:
                entry["reason"] = "address not live, no recorded frames, or tool unavailable"
        # A full class summary can expose aggregates of small allocations excluded
        # by the address filter. It gets only the time left after stack capture.
        if class_summary and process.poll() is None:
            remaining = deadline - time.monotonic()
            if remaining > 0:
                captured = bounded_capture(["/usr/bin/heap", "-s", "--noContent", str(process.pid)],
                                           env, destination / "allocation-heap-summary.txt",
                                           min(HEAP_SECONDS, remaining), HEAP_BYTES)
                captured["tool"] = "heap-summary"
                result["classSummary"] = captured
                result["tools"].append(captured)
        count = sum(row["status"] == "COLLECTED" for row in result["allocations"])
        result["recordedStackAddresses"] = count
        if count:
            result["status"] = ("COLLECTED" if count == len(addresses) and
                                all(tool["status"] == "COLLECTED" for tool in result["tools"]) and
                                (not class_summary or result["classSummary"]["status"] == "COLLECTED")
                                else "PARTIAL")
    result["finishedMonotonicNS"] = time.monotonic_ns()
    bench.write_json(destination / "allocation-diagnostics.json", result)
    return result


def parse_arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate-app", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--selection-profile", choices=tuple(SELECTION_PROFILES), default=SELECTION_PROFILE)
    parser.add_argument("--class-summary", action="store_true",
                        help="capture a full class summary using the time left after selected stack queries")
    args = parser.parse_args(argv)
    args.responses, args.trials = [20000], 1
    args.warmup, args.duration, args.startup_timeout, args.retained_graph = 120, 120, 300, False
    return args


def main(argv=None):
    args = parse_arguments(argv)
    output = args.output_dir.absolute()
    summary = {"schemaVersion": 1, "purpose": PURPOSE, "performanceComparable": False,
               "selectionProfile": args.selection_profile,
               "classSummaryRequested": args.class_summary,
               "performanceVerdict": "NOT_EVALUATED", "metricsEligibleForHalvingAcceptance": False,
               "instrumentation": {"MallocStackLogging": "1"}, "loggingEnabledAt": "process-start",
               "status": "NOT_RUN", "results": [], "staticFixture": True,
               "limitations": ["all resource observations include stack-logging overhead",
                               "one candidate, one 20k synthetic trial; no performance pairs or ratios",
                               "selected allocation stacks do not prove retaining ownership or leaks"]}
    created_output, display = False, None
    try:
        home, runner_temp = bench.guard_host(output)
        output.mkdir(parents=True)
        created_output = True
        root = runner_temp / ("tokenbar-allocations-" + uuid.uuid4().hex)
        root.mkdir()
        env = bench.clean_environment(home, root / "unused", Path(os.environ.get("TMPDIR", "/tmp")))
        gui = bench.command(["/bin/launchctl", "print", f"gui/{os.getuid()}"], env=env, check=False)
        bench.require(gui.returncode == 0, "no logged-in GUI bootstrap session", "NOT_RUN")
        app = args.candidate_app.resolve()
        summary.update(bundle=bench.bundle_manifest(app), actualOS=platform.platform(),
                       architecture=platform.machine(), actualAccountHome=str(home), runtimeRoot=str(root),
                       viewportProtocol=bench.VIEWPORT_PROTOCOL, warmupSeconds=120, durationSeconds=120,
                       productionBuildsPerformed=False)
        bench.require(bench.export_defaults(env) is None, "preexisting product defaults domain", "REFUSED")
        bench.require(not bench.product_processes(env=env), "another product process is running", "REFUSED")
        try:
            windows = bench.VisibleWindowProbe()
        except (OSError, ValueError) as error:
            raise bench.BenchError(f"CoreGraphics window observation unavailable: {error}", "NOT_RUN") from error
        display = bench.BenchmarkDisplay(windows, env)
        summary["benchmarkDisplay"] = display.record
        display.configure()
        anchor, local_day = int(time.time()) - 3600, dt.date.today()
        day_start = dt.datetime.combine(local_day, dt.time.min).timestamp()
        bench.require(anchor - 600 >= day_start, "historical fixture would cross local day boundary", "NOT_RUN")
        fixture_root = root / "fixture-20000"
        fixture = bench.generate_fixture(fixture_root, 20000, anchor)
        bench.write_json(output / "fixture-20000.json", fixture)
        env = bench.clean_environment(home, fixture_root, Path(os.environ.get("TMPDIR", "/tmp")))
        runtime_app = root / "runtime/Codex Token Bar.app"
        runtime_app.parent.mkdir()
        bench.require(dt.date.today() == local_day, "local day changed before diagnostic", "NOT_RUN")
        result = bench.run_trial("candidate", 1, app, runtime_app, home, fixture_root, fixture, env, args,
                                 output, windows, display, app_env=dict(env, MallocStackLogging="1"),
                                 post_sample=partial(collect_allocations, profile=args.selection_profile,
                                                     class_summary=args.class_summary), purpose=PURPOSE)
        summary["results"].append(result)
        bench.require(dt.date.today() == local_day, "local day changed during diagnostic", "NOT_RUN")
        summary["status"] = result["postMeasurementMemoryDiagnostics"]["status"]
    except (bench.BenchError, OSError, ValueError, subprocess.SubprocessError) as error:
        summary.update(status=getattr(error, "status", "FAILED"), reason=str(error))
    finally:
        if display is not None:
            try:
                display.restore()
            except (bench.BenchError, OSError) as error:
                summary.update(status="FAILED", reason=str(error))
    if created_output:
        bench.write_json(output / "summary.json", summary)
    print(bench.canonical({"status": summary["status"], "evidence": str(output),
                           "performanceVerdict": "NOT_EVALUATED", "reason": summary.get("reason")}).decode())
    return 0 if summary["status"] == "COLLECTED" else (2 if summary["status"] in ("NOT_RUN", "REFUSED") else 1)


if __name__ == "__main__":
    raise SystemExit(main())
