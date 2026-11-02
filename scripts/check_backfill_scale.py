#!/usr/bin/env python3
"""Measure the actual namespaced Swift backfill; never relabel a synthetic DB.

The selected XCTest creates raw rollouts, builds the old standalone index with
production code, imports it into A, removes only the enrichment receipt/model,
then exercises real multi-batch staging and publication. Each size has a fresh
root. Original bytes, exact totals, no reparse and monotonic progress are asserted
inside the test, not inferred from the profile. This is a CI probe, not an app.
"""
from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import re
import subprocess
import time

TEST = "CodexUsageAnalyzerTests.testNamespacedMultiBatchEnrichmentReportsCumulativeProgressWithoutReparsingOrChangingHistory"
MARKER = "TOKENBAR_BACKFILL_PROFILE "
DEFAULT_SIZES = (13, 128, 512, 4124)


def parse_profile(text: str, count: int) -> dict:
    profiles = [json.loads(line.split(MARKER, 1)[1]) for line in text.splitlines() if MARKER in line]
    if len(profiles) != 1:
        raise ValueError(f"Expected exactly one {count}-file profile, found {len(profiles)}")
    profile = profiles[0]
    for field in ("files", "parsed", "events"):
        if profile.get(field) != count:
            raise ValueError(f"{field} differs from {count}: {profile.get(field)}")
    if profile.get("tokens") != 120 * count + count * (count - 1) // 2:
        raise ValueError("Recorded history no longer equals the original exact token total")
    if profile.get("complete") is not True or profile.get("monotonic") is not True:
        raise ValueError("Backfill incomplete or visible progress regressed")
    name = TEST.split(".")[1]
    if not any(name in line and "passed" in line for line in text.splitlines()):
        raise ValueError("Profile alone is not evidence that the entire XCTest passed")
    if re.search(r"Test Case .*" + re.escape(name) + r".*(?:skipped|failed)", text):
        raise ValueError("Required scale XCTest did not pass")
    for field in ("bootstrapSeconds", "backfillSeconds", "largestProgressGapSeconds", "totalSeconds"):
        value = profile.get(field)
        if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
            raise ValueError(f"Invalid timing {field}: {value}")
    return profile


def validate_options(sizes: tuple[int, ...], timeout: int, max_gap: float, max_backfill: float) -> None:
    if (not sizes or any(type(value) is not int or not 9 <= value <= 8192 for value in sizes)
            or len(set(sizes)) != len(sizes)):
        raise ValueError("sizes must be nonempty, unique and in 9...8192")
    for value in (timeout, max_gap, max_backfill):
        if type(value) not in (int, float) or not math.isfinite(value) or value <= 0:
            raise ValueError("execution deadline and budgets must be positive finite numbers")


def validate_profiles(profiles: list[dict], sizes: tuple[int, ...], max_gap: float, max_backfill: float) -> None:
    if [item.get("files") for item in profiles] != list(sizes):
        raise ValueError("Every requested scale must have one completed profile in execution order")
    for profile in profiles:
        if profile["largestProgressGapSeconds"] > max_gap:
            raise RuntimeError(f"{profile['files']}-file progress silent for {profile['largestProgressGapSeconds']:.2f}s")
        if profile["backfillSeconds"] > max_backfill:
            raise RuntimeError(f"{profile['files']}-file backfill exceeded the configured latency budget")


def run_sizes(repository: Path, output: Path, sizes: tuple[int, ...], timeout: int,
              max_gap: float, max_backfill: float) -> dict:
    validate_options(sizes, timeout, max_gap, max_backfill)
    output.mkdir(parents=True, exist_ok=False)
    sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository, text=True).strip()
    report = {"schemaVersion": 1, "sourceSha": sha, "test": TEST, "status": "RUNNING", "profiles": [],
              "requestedSizes": list(sizes),
              "budgets": {"executionTimeoutSeconds": timeout,
                          "maxProgressGapSeconds": max_gap, "maxBackfillSeconds": max_backfill},
              "scope": "Synthetic source-count scale through actual Swift A routes; one event per file, not real-history byte-volume or installed-app UX acceptance"}
    target = output / "report.json"
    def save() -> None:
        target.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    save()
    try:
        for number, count in enumerate(sizes):
            report["runningSize"] = count
            save()
            env = os.environ.copy()
            env["TOKENBAR_BACKFILL_FILE_COUNT"] = str(count)
            # The XCTest owns fresh temporary database roots and all routing.
            command = ["swift", "test"] + (["--skip-build"] if number else []) + ["--filter", TEST]
            started = time.monotonic()
            log = output / f"backfill-{count}.log"
            with log.open("w", encoding="utf-8") as stream:
                process = subprocess.Popen(command, cwd=repository, env=env, stdout=stream, stderr=subprocess.STDOUT)
                try:
                    code = process.wait(timeout=timeout)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait()
                    raise RuntimeError(f"{count}-file probe exceeded the {timeout}s execution deadline; see {log.name}")
            text = log.read_text(encoding="utf-8", errors="replace")
            if code:
                raise RuntimeError(f"{count}-file XCTest returned {code}; see {log.name}")
            profile = parse_profile(text, count)
            profile["commandSeconds"] = time.monotonic() - started
            profile["log"] = log.name
            report["profiles"].append(profile)
            save()
            validate_profiles(report["profiles"], sizes[:number + 1], max_gap, max_backfill)
        validate_profiles(report["profiles"], sizes, max_gap, max_backfill)
        report["status"] = "PASS"
        report.pop("runningSize", None)
    except Exception as error:
        report["status"] = "FAIL"
        report["error"] = str(error)
        raise
    finally:
        save()
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sizes", type=int, nargs="+", default=DEFAULT_SIZES)
    parser.add_argument("--timeout", type=int, default=1200)
    parser.add_argument("--max-progress-gap", type=float, default=30)
    parser.add_argument("--max-backfill-seconds", type=float, default=600)
    parser.add_argument("--output", type=Path, default=Path("backfill-scale-evidence"))
    args = parser.parse_args()
    try:
        validate_options(tuple(args.sizes), args.timeout, args.max_progress_gap, args.max_backfill_seconds)
    except ValueError as error:
        parser.error(str(error))
    repository = Path(__file__).resolve().parents[1]
    report = run_sizes(repository, args.output.resolve(), tuple(args.sizes), args.timeout,
                       args.max_progress_gap, args.max_backfill_seconds)
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
