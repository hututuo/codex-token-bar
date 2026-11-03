#!/usr/bin/env python3
"""Measure the actual namespaced Swift backfill; never relabel a synthetic DB.

The selected XCTest creates raw rollouts, builds the old standalone index with
production code, imports it into A, removes only the enrichment receipt/model,
then exercises real multi-batch staging and publication. Optional --pressure
adds many events per rollout and empty, synthetic legacy stage catalog entries;
those entries model catalog scan load only and are never historical producers.
Each case has a fresh root, and failures are collected without skipping later
cases so the 4124-file observation remains available after a smaller failure.
"""
from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

TEST = "CodexUsageAnalyzerTests.testNamespacedMultiBatchEnrichmentReportsCumulativeProgressWithoutReparsingOrChangingHistory"
XCTEST_SELECTOR = (
    "CodexTokenBarTests.CodexUsageAnalyzerTests/"
    "testNamespacedMultiBatchEnrichmentReportsCumulativeProgressWithoutReparsingOrChangingHistory"
)
MARKER = "TOKENBAR_BACKFILL_PROFILE "
DEFAULT_SIZES = (13, 128, 512, 4124)
PRESSURE_EVENTS_PER_FILE = 122
PRESSURE_LEGACY_JOBS = 6250
UNCHANGED_SAMPLES = 20


def expected_tokens(files: int, events_per_file: int) -> int:
    return (120 * files + files * (files - 1) // 2) * events_per_file


def scale_cases(sizes: tuple[int, ...], pressure: bool = False) -> list[dict]:
    cases = [
        {
            "name": f"size-{count}",
            "kind": "standard",
            "files": count,
            "eventsPerFile": 1,
            "legacyJobs": 0,
            "expectedEvents": count,
            "expectedTokens": expected_tokens(count, 1),
        }
        for count in sizes
    ]
    if pressure:
        count = 4124
        cases.append({
            "name": f"pressure-{count}x{PRESSURE_EVENTS_PER_FILE}-{PRESSURE_LEGACY_JOBS}",
            "kind": "synthetic-pressure",
            "files": count,
            "eventsPerFile": PRESSURE_EVENTS_PER_FILE,
            "legacyJobs": PRESSURE_LEGACY_JOBS,
            "expectedEvents": count * PRESSURE_EVENTS_PER_FILE,
            "expectedTokens": expected_tokens(count, PRESSURE_EVENTS_PER_FILE),
        })
    return cases


def _nonnegative_number(profile: dict, field: str) -> float:
    value = profile.get(field)
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        raise ValueError(f"Invalid timing {field}: {value}")
    return float(value)


def parse_profile(text: str, count: int, events_per_file: int = 1, legacy_jobs: int = 0) -> dict:
    profiles = [json.loads(line.split(MARKER, 1)[1]) for line in text.splitlines() if MARKER in line]
    if len(profiles) != 1:
        raise ValueError(f"Expected exactly one {count}-file profile, found {len(profiles)}")
    profile = profiles[0]
    expected_event_count = count * events_per_file
    expected_token_count = expected_tokens(count, events_per_file)
    for field in ("files", "parsed"):
        if profile.get(field) != count:
            raise ValueError(f"{field} differs from {count}: {profile.get(field)}")
    for field, expected in (
        ("eventsPerFile", events_per_file),
        ("events", expected_event_count),
        ("expectedEvents", expected_event_count),
        ("tokens", expected_token_count),
        ("expectedTokens", expected_token_count),
        ("legacyJobs", legacy_jobs),
    ):
        if profile.get(field) != expected:
            raise ValueError(f"{field} differs from {expected}: {profile.get(field)}")
    if profile.get("complete") is not True or profile.get("monotonic") is not True:
        raise ValueError("Backfill incomplete or visible progress regressed")
    before = profile.get("rawAccountingDigestBefore")
    after = profile.get("rawAccountingDigestAfter")
    if not isinstance(before, str) or re.fullmatch(r"[0-9a-f]{64}", before) is None or after != before:
        raise ValueError("Typed raw accounting identity/value proof changed or is missing")

    lock_count = profile.get("writeLockCount")
    if isinstance(lock_count, bool) or not isinstance(lock_count, int) or lock_count <= 0:
        raise ValueError(f"Invalid writeLockCount: {lock_count}")

    for name in ("mainObjects", "mainStores"):
        before = profile.get(f"{name}Before")
        after = profile.get(f"{name}After")
        delta = profile.get(f"{name[:-1]}Delta") if name.endswith("s") else profile.get(f"{name}Delta")
        if not isinstance(before, int) or before < 0 or not isinstance(after, int) or after < 0:
            raise ValueError(f"Invalid MAIN {name} counts: {before}, {after}")
        expected_delta = after - before
        if delta != expected_delta or expected_delta != 0:
            raise ValueError(f"MAIN {name} changed: before={before}, after={after}, delta={delta}")
    if profile.get("unchangedSamples") != UNCHANGED_SAMPLES:
        raise ValueError(f"Expected {UNCHANGED_SAMPLES} unchanged samples")
    if profile.get("unchangedParserCalls") != 0:
        raise ValueError("Unchanged synchronizations invoked the parser")
    _nonnegative_number(profile, "unchangedP95Seconds")

    name = TEST.split(".")[1]
    if not any(name in line and "passed" in line for line in text.splitlines()):
        raise ValueError("Profile alone is not evidence that the entire XCTest passed")
    if re.search(r"Test Case .*" + re.escape(name) + r".*(?:skipped|failed)", text):
        raise ValueError("Required scale XCTest did not pass")
    for field in (
        "preparationSeconds", "bootstrapSeconds", "backfillSeconds", "largestProgressGapSeconds",
        "totalSeconds", "maximumWriteLockSeconds", "totalWriteLockSeconds",
    ):
        _nonnegative_number(profile, field)
    return profile


def _record_failure(report: dict, case: dict, message: str) -> None:
    case["status"] = "FAIL"
    case["error"] = message
    report["failures"].append({"case": case["name"], "error": message})


def _is_macos() -> bool:
    return sys.platform == "darwin"


def _resolve_xctest_bundle(repository: Path, timeout: int = 60,
                           env: dict[str, str] | None = None) -> Path:
    """Resolve the unique test bundle SwiftPM just used, constrained to repo .build."""
    repo = repository.resolve(strict=True)
    build_entry = repo / ".build"
    managed_build = build_entry.resolve(strict=True)
    if not managed_build.is_dir() or managed_build != build_entry:
        raise ValueError("Repository .build is missing or resolves through a symlink")

    result = subprocess.run(
        ["swift", "test", "--show-bin-path"],
        cwd=repo,
        check=False,
        capture_output=True,
        text=True,
        timeout=timeout,
        env=env,
    )
    if result.returncode != 0:
        raise ValueError(f"swift test --show-bin-path returned {result.returncode}: {result.stderr.strip()}")
    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    if len(lines) != 1:
        raise ValueError(f"Expected one SwiftPM binary path, found {len(lines)}")

    binary_directory = Path(lines[0]).resolve(strict=True)
    if not binary_directory.is_dir() or not binary_directory.is_relative_to(managed_build):
        raise ValueError("SwiftPM binary path resolves outside repository .build")
    bundles = list(binary_directory.glob("*.xctest"))
    if len(bundles) != 1:
        raise ValueError(f"Expected one XCTest bundle in SwiftPM binary path, found {len(bundles)}")
    bundle = bundles[0].resolve(strict=True)
    if not bundle.is_dir() or not bundle.is_relative_to(managed_build):
        raise ValueError("Resolved XCTest bundle is not a real directory under repository .build")
    return bundle


def _timeout_phase(log_text: str) -> str:
    """Describe the furthest selected-test lifecycle marker seen before timeout."""
    if "Test Suite 'Selected tests' started" not in log_text and re.search(
        r"\b(?:Compiling|Emitting module|Linking)\b", log_text
    ):
        return "swiftpm_build"
    if "Planning build" in log_text and "Build complete!" not in log_text:
        return "swiftpm_build_planning"
    if "Test Suite 'Selected tests' started" not in log_text:
        return "runner_startup"
    test_name = TEST.rsplit(".", 1)[1]
    target_lines = [line for line in log_text.splitlines() if test_name in line and "Test Case" in line]
    if not any("started" in line for line in target_lines):
        return "test_setup"
    if not any(any(result in line for result in (" passed", " failed", " skipped")) for line in target_lines):
        return "test_execution"
    return "test_completion"


def _capture_process_group(process, windows: bool | None = None) -> dict:
    """Capture a bounded snapshot of only this case's isolated process group."""
    if windows is None:
        windows = os.name == "nt"
    if windows:
        return {"processGroup": process.pid, "members": [], "capture": "unavailable-on-windows"}
    try:
        result = subprocess.run(
            ["ps", "-axo", "pid=,ppid=,pgid=,stat=,comm="],
            check=False,
            capture_output=True,
            text=True,
            timeout=3,
        )
        if result.returncode != 0:
            return {"processGroup": process.pid, "members": [], "capture": f"ps-returned-{result.returncode}"}
        members = []
        for line in result.stdout.splitlines():
            fields = line.strip().split(None, 4)
            if len(fields) < 4:
                continue
            try:
                pid, ppid, pgid = (int(fields[index]) for index in range(3))
            except ValueError:
                continue
            if pgid == process.pid:
                members.append({
                    "pid": pid,
                    "ppid": ppid,
                    "state": fields[3],
                    "command": fields[4][:256] if len(fields) > 4 else "",
                })
        return {
            "processGroup": process.pid,
            "members": members[:128],
            "truncated": len(members) > 128,
            "capture": "ok",
        }
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"processGroup": process.pid, "members": [], "capture": f"ps-unavailable: {error}"}


def _terminate_case_process_tree(process, windows: bool | None = None) -> str | None:
    """Stop only the process tree created for this case and always reap its root."""
    if windows is None:
        windows = os.name == "nt"
    if windows:
        try:
            result = subprocess.run(
                ["taskkill", "/PID", str(process.pid), "/T", "/F"],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except OSError as error:
            try:
                process.kill()
            except ProcessLookupError:
                pass
            process.wait()
            return f"Windows taskkill unavailable ({error}); killed only the Swift process, descendant cleanup is unverified"
        if result.returncode != 0 and process.poll() is None:
            try:
                process.kill()
            except ProcessLookupError:
                pass
        process.wait()
        if result.returncode != 0:
            return f"Windows taskkill /T returned {result.returncode}; descendant cleanup could not be confirmed"
        return None

    try:
        # The caller starts a fresh session for each POSIX case, so this group
        # contains only that swift driver and its xctest descendants.
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except OSError as error:
        try:
            process.kill()
        except ProcessLookupError:
            pass
        process.wait()
        return f"Could not kill the isolated process group ({error}); direct-child fallback used"
    process.wait()
    return None


def run_sizes(repository: Path, output: Path, sizes: tuple[int, ...], timeout: int,
              max_gap: float, max_backfill: float, pressure: bool = False,
              max_unchanged_p95: float = 1.0, max_write_lock_seconds: float = 10.0) -> dict:
    output.mkdir(parents=True, exist_ok=False)
    sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository, text=True).strip()
    cases = scale_cases(sizes, pressure)
    report = {
        "schemaVersion": 4,
        "sourceSha": sha,
        "test": TEST,
        "xctestSelector": XCTEST_SELECTOR,
        "status": "RUNNING",
        "cases": [],
        "profiles": [],
        "failures": [],
        "pressureEnabled": pressure,
        "budgets": {"caseTimeoutSeconds": timeout, "maxProgressGapSeconds": max_gap,
                    "maxBackfillSeconds": max_backfill,
                    "maxUnchangedP95Seconds": max_unchanged_p95,
                    "maxWriteLockSeconds": max_write_lock_seconds},
        "scope": "Synthetic scale fixture through actual Swift A routes; not installed-app UX acceptance",
        "runnerStrategy": "macOS: first swift test build, then verified same-build xctest; other platforms: swift test",
    }
    target = output / "report.json"

    def save() -> None:
        target.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    save()
    build_available = False
    xctest_bundle: Path | None = None
    for case in cases:
        result = dict(case, status="RUNNING")
        report["cases"].append(result)
        env = os.environ.copy()
        env["TOKENBAR_BACKFILL_FILE_COUNT"] = str(case["files"])
        env["TOKENBAR_BACKFILL_EVENTS_PER_FILE"] = str(case["eventsPerFile"])
        env["TOKENBAR_BACKFILL_LEGACY_JOBS"] = str(case["legacyJobs"])
        # On macOS, SwiftPM builds/runs the first case. Once that succeeds,
        # subsequent cases invoke that exact package XCTest bundle and avoid
        # re-entering SwiftPM's build planner. Other platforms retain SwiftPM.
        use_xctest = _is_macos() and build_available and xctest_bundle is not None
        if use_xctest:
            command = ["xcrun", "xctest", "-XCTest", XCTEST_SELECTOR, str(xctest_bundle)]
            runner = "xctest"
        else:
            command = ["swift", "test"] + (["--skip-build"] if build_available else []) + ["--filter", TEST]
            runner = "swift"
        result["command"] = command
        result["runner"] = runner
        if xctest_bundle is not None:
            result["xctestBundle"] = str(xctest_bundle)
        started = time.monotonic()
        log = output / f"{case['name']}.log"
        result["log"] = log.name
        timed_out = False
        timeout_process_snapshot = None
        timeout_cleanup_issue = None
        try:
            with log.open("w", encoding="utf-8") as stream:
                popen_options = {}
                if os.name != "nt":
                    popen_options["start_new_session"] = True
                process = subprocess.Popen(
                    command, cwd=repository, env=env, stdout=stream, stderr=subprocess.STDOUT,
                    **popen_options,
                )
                try:
                    code = process.wait(timeout=timeout)
                except subprocess.TimeoutExpired:
                    timeout_process_snapshot = _capture_process_group(process)
                    timeout_cleanup_issue = _terminate_case_process_tree(process)
                    build_available = False
                    xctest_bundle = None
                    timed_out = True
            if timed_out:
                diagnostics = {
                    "phase": _timeout_phase(log.read_text(encoding="utf-8", errors="replace")),
                    "process": timeout_process_snapshot,
                }
                result["timeoutDiagnostics"] = diagnostics
                message = f"Exceeded the {timeout}s execution deadline; see {log.name}"
                message += f"; phase={diagnostics['phase']}"
                if timeout_cleanup_issue:
                    message += f"; process-tree cleanup limitation: {timeout_cleanup_issue}"
                raise RuntimeError(message)
            command_seconds = time.monotonic() - started
            result["commandSeconds"] = command_seconds
            text = log.read_text(encoding="utf-8", errors="replace")
            if code:
                build_available = False
                xctest_bundle = None
                failed_command = "swift test" if runner == "swift" else "xcrun xctest"
                raise RuntimeError(f"{failed_command} returned {code}; compile/test failure; see {log.name}")
            build_available = True
            if _is_macos() and runner == "swift":
                discovery_started = time.monotonic()
                try:
                    xctest_bundle = _resolve_xctest_bundle(repository, env=env)
                except Exception as error:
                    build_available = False
                    xctest_bundle = None
                    raise RuntimeError(
                        f"Swift test passed but its repository .build XCTest bundle could not be resolved: {error}"
                    ) from error
                result["bundleDiscoverySeconds"] = time.monotonic() - discovery_started
                result["xctestBundle"] = str(xctest_bundle)
                report["xctestBundle"] = str(xctest_bundle)
            profile = parse_profile(text, case["files"], case["eventsPerFile"], case["legacyJobs"])
            profile.update({
                "case": case["name"],
                "kind": case["kind"],
                "commandSeconds": command_seconds,
                "log": log.name,
            })
            report["profiles"].append(profile)
            result["profile"] = profile
            if profile["largestProgressGapSeconds"] > max_gap:
                raise RuntimeError(f"Progress silent for {profile['largestProgressGapSeconds']:.2f}s (limit {max_gap:.2f}s)")
            if profile["backfillSeconds"] > max_backfill:
                raise RuntimeError(f"Backfill took {profile['backfillSeconds']:.2f}s (limit {max_backfill:.2f}s)")
            if profile["unchangedP95Seconds"] > max_unchanged_p95:
                raise RuntimeError(
                    f"Unchanged p95 took {profile['unchangedP95Seconds']:.3f}s "
                    f"(limit {max_unchanged_p95:.3f}s)"
                )
            if profile["maximumWriteLockSeconds"] > max_write_lock_seconds:
                raise RuntimeError(
                    f"Maximum write lock took {profile['maximumWriteLockSeconds']:.3f}s "
                    f"(limit {max_write_lock_seconds:.3f}s)"
                )
            result["status"] = "PASS"
        except Exception as error:
            _record_failure(report, result, str(error))
        save()
    report["status"] = "FAIL" if report["failures"] else "PASS"
    save()
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sizes", type=int, nargs="+", default=DEFAULT_SIZES)
    parser.add_argument("--pressure", action="store_true",
                        help="After standard sizes, run 4124 files x 122 events plus 6250 synthetic legacy stage entries")
    parser.add_argument("--timeout", type=int, default=1200)
    parser.add_argument("--max-progress-gap", type=float, default=30)
    parser.add_argument("--max-backfill-seconds", type=float, default=600)
    parser.add_argument("--max-unchanged-p95-seconds", type=float, default=1.0)
    parser.add_argument("--max-write-lock-seconds", type=float, default=10.0)
    parser.add_argument("--output", type=Path, default=Path("backfill-scale-evidence"))
    args = parser.parse_args()
    if any(not 9 <= value <= 8192 for value in args.sizes) or len(set(args.sizes)) != len(args.sizes):
        parser.error("sizes must be unique and in 9...8192")
    if min(args.timeout, args.max_progress_gap, args.max_backfill_seconds,
           args.max_unchanged_p95_seconds, args.max_write_lock_seconds) <= 0:
        parser.error("execution deadline and budgets must be positive")
    repository = Path(__file__).resolve().parents[1]
    report = run_sizes(repository, args.output.resolve(), tuple(args.sizes), args.timeout,
                       args.max_progress_gap, args.max_backfill_seconds, pressure=args.pressure,
                       max_unchanged_p95=args.max_unchanged_p95_seconds,
                       max_write_lock_seconds=args.max_write_lock_seconds)
    print(json.dumps(report, sort_keys=True))
    if report["status"] != "PASS":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
