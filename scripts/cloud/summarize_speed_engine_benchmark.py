#!/usr/bin/env python3
"""Fail closed on incomplete paired evidence; report only SpeedEngine measurements."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import statistics
import sys

SIZES = (2000, 20000)
SHAPES = ("day", "dense")
TRIALS = (1, 2, 3)
PHASES = ("warmed", "after-unchanged")
TRACE_PHASES = (
    "equal-end-key-order", "invalid-interval-still-limits-inflight", "same-key-end-moves-backward",
    "same-key-agent-changes", "nonfinal", "late-final-enrichment", "remove-agent-keeps-responses",
    "rollover-retention-equality", "one-millisecond-past-retention",
    "clock-moves-back-without-resurrection", "fresh-engine-reset",
)
MEASUREMENT_FIELDS = (
    "milliseconds", "cpuMilliseconds", "userMilliseconds", "systemMilliseconds",
    "processPeakRSSBytesBeforeFixture", "processPeakRSSBytesBeforeLoop", "processPeakRSSBytesAfterLoop",
    "processCurrentRSSBytesBeforeFixture", "processCurrentRSSBytesBeforeLoop", "processCurrentRSSBytesAfterLoop",
)
FLOAT_CONTAINERS = frozenset(("average", "live", "estimated", "liveCost", "recent", "peak",
                              "estimatedShare", "speed", "duration", "models", "history", "subsets"))
LIMITATIONS = [
    "Synthetic SpeedEngine unchanged-publish measurements only; no whole-app or installed-runtime CPU/RSS claim.",
    "CPU is process user+system time during the explicit advance loop; wall time uses a monotonic clock.",
    "Darwin ru_maxrss is lifetime process peak RSS in bytes, including XCTest and fixture setup; its growth is not allocation.",
    "Current task resident_size is endpoint process RSS, not phys_footprint, and endpoints miss transient peaks.",
    "Warmup/setup are outside the measured loop; retained caches can trade CPU for additional memory.",
    "An empty ledger is initialized before indexed seed upserts; unchanged cases do not test unordered bulk ledger initialization.",
    "Three trials describe this runner/toolchain/workload; reduction percentages are observations, not a 50% performance gate.",
]


class EvidenceError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise EvidenceError(message)


def reject_constant(value):
    raise ValueError("Non-finite JSON constant: " + value)


def read_json(path):
    try:
        return json.loads(path.read_text(), parse_constant=reject_constant)
    except (OSError, ValueError) as error:
        raise EvidenceError(f"{path.name}: cannot read valid finite JSON: {error}") from error


def is_float_path(path):
    # JSONSerialization may render an integral Double as an integer token. Use
    # this fixed fixture schema, not Python token types, to choose tolerance.
    if "history" in path and path[-1] == 0:
        return False  # millisecond bucket timestamp
    if "subsets" in path and path[-1] == 0:
        return False  # source bit mask
    return any(part in FLOAT_CONTAINERS for part in path if isinstance(part, str))


def compare_semantics(expected, actual, path=(), tolerance=1e-6):
    label = ".".join(map(str, path)) or "<root>"
    if isinstance(expected, bool) or isinstance(actual, bool):
        require(type(expected) is type(actual) and expected == actual, f"{label}: boolean mismatch")
    elif isinstance(expected, (int, float)) and isinstance(actual, (int, float)):
        require(math.isfinite(expected) and math.isfinite(actual), f"{label}: non-finite number")
        if is_float_path(path):
            require(abs(expected - actual) <= tolerance, f"{label}: floating mismatch {expected} != {actual}")
        else:
            require(expected == int(expected) and actual == int(actual) and expected == actual,
                    f"{label}: integer mismatch {expected} != {actual}")
    elif isinstance(expected, dict) and isinstance(actual, dict):
        require(expected.keys() == actual.keys(), f"{label}: dictionary keys differ")
        for key in sorted(expected):
            compare_semantics(expected[key], actual[key], path + (key,), tolerance)
    elif isinstance(expected, list) and isinstance(actual, list):
        require(len(expected) == len(actual), f"{label}: array lengths differ")
        for index, (left, right) in enumerate(zip(expected, actual)):
            compare_semantics(left, right, path + (index,), tolerance)
    else:
        require(type(expected) is type(actual) and expected == actual, f"{label}: value mismatch {expected!r} != {actual!r}")


def check_exit(root, label, required_argv=()):
    status = read_json(root / f"{label}.exit.json")
    require(isinstance(status, dict), f"{label}: command status must be an object")
    require(status.get("commandExitCode") == 0 and type(status.get("commandExitCode")) is int,
            f"{label}: command did not exit successfully")
    require(status.get("logExitCode") == 0 and type(status.get("logExitCode")) is int,
            f"{label}: evidence logging failed")
    argv = status.get("argv")
    require(isinstance(argv, list) and argv and all(isinstance(arg, str) for arg in argv), f"{label}: missing command argv")
    for argument in required_argv:
        require(argument in argv, f"{label}: required command argument absent: {argument}")
    require((root / f"{label}.log").is_file(), f"{label}: missing command log")


def read_records(root, label, source, trial, required_filter):
    check_exit(root, label, ("swift", "test", "release", "-enable-testing", "--skip-build", required_filter,
                             f"SPEED_BENCHMARK_SOURCE={source}", f"SPEED_BENCHMARK_TRIAL={trial}"))
    status = read_json(root / f"{label}.exit.json")
    destinations = [argument.split("=", 1)[1] for argument in status["argv"]
                    if argument.startswith("SPEED_BENCHMARK_OUTPUT=")]
    require(len(destinations) == 1 and Path(destinations[0]).name == f"{label}.records.jsonl",
            f"{label}: missing/wrong per-case JSONL output argument")
    path = root / f"{label}.records.jsonl"
    require(path.is_file(), f"{label}: missing benchmark JSONL (console logs are diagnostics only)")
    text = path.read_text()
    require(not text or text.endswith("\n"), f"{label}: incomplete benchmark JSONL record")
    records = []
    for line_number, line in enumerate(text.splitlines(), 1):
        try:
            record = json.loads(line, parse_constant=reject_constant)
        except ValueError as error:
            raise EvidenceError(f"{label}:{line_number}: invalid benchmark JSON") from error
        require(isinstance(record, dict), f"{label}:{line_number}: record must be an object")
        require(record.get("source") == source and type(record.get("trial")) is int and record.get("trial") == trial,
                f"{label}: source/trial identity mismatch")
        records.append(record)
    require(records, f"{label}: no executed benchmark records (zero-test success is insufficient)")
    return records


def independent_totals(size):
    return {
        "input": sum(100 + index % 17 for index in range(size)),
        "output": sum(40 + index for index in range(size)),
        "unfinalized": sum(index % 19 == 0 for index in range(size)),
        "cost": sum(0 if index % 7 == 0 else 100 + index % 29 for index in range(size)),
        "unpriced": sum(index % 7 == 0 for index in range(size)),
    }


def check_totals(output, size, label):
    expected = independent_totals(size)
    require(output.get("today") == [size, expected["input"], 0, 0, expected["output"], 0], f"{label}: independent token totals differ")
    require(output.get("unfinalized") == expected["unfinalized"], f"{label}: independent nonfinal count differs")
    require(output.get("todayCost") == [expected["cost"], expected["unpriced"]], f"{label}: independent cost totals differ")
    require(len(output.get("history", [])) == 300, f"{label}: expected 300 history buckets")


def load_case(root, role, source, size, shape, trial):
    label = f"{role}-{size}-{shape}-{trial}"
    records = read_records(root, label, source, trial, "SpeedEngineBenchmarkTests.testUnchangedSyntheticPublishes")
    check_exit(root, label, (f"SPEED_BENCHMARK_RESPONSES={size}", f"SPEED_BENCHMARK_SHAPE={shape}", "SPEED_BENCHMARK_TICKS=200"))
    require(len(records) == 3, f"{label}: expected exactly one measurement and two correctness records")
    measurements = [record for record in records if record.get("kind") == "measurement"]
    correctness = [record for record in records if record.get("kind") == "correctness"]
    require(len(measurements) == 1 and len(correctness) == 2, f"{label}: incorrect record kinds")
    require([record.get("phase") for record in correctness] == list(PHASES), f"{label}: missing/reordered correctness phases")
    for record in records:
        require(record.get("fixtureResponses") == size and record.get("shape") == shape, f"{label}: workload identity differs")
    measurement = measurements[0]
    require(measurement.get("phase") == "unchanged" and measurement.get("ticks") == 200, f"{label}: incorrect measured phase/ticks")
    for field in MEASUREMENT_FIELDS:
        value = measurement.get(field)
        if field.startswith("processCurrent") and value is None:
            require(field in measurement, f"{label}: missing optional memory field {field}")
            continue
        require(type(value) in (int, float) and math.isfinite(value) and value >= 0, f"{label}: invalid measurement {field}")
    require(measurement["milliseconds"] > 0 and measurement["cpuMilliseconds"] > 0, f"{label}: nonpositive loop duration")
    require(abs(measurement["cpuMilliseconds"] - measurement["userMilliseconds"] - measurement["systemMilliseconds"]) <= 1e-6,
            f"{label}: CPU total does not equal user+system")
    require(0 < measurement["processPeakRSSBytesBeforeFixture"] <= measurement["processPeakRSSBytesBeforeLoop"] <= measurement["processPeakRSSBytesAfterLoop"],
            f"{label}: lifetime peak RSS is not positive and monotonic")
    for status_suffix, field_suffix in (("BeforeFixture", "BeforeFixture"), ("Before", "BeforeLoop"), ("After", "AfterLoop")):
        status = measurement.get("currentRSSStatus" + status_suffix)
        field = "processCurrentRSSBytes" + field_suffix
        require(type(status) is int, f"{label}: missing current RSS kernel status")
        require((status == 0) == (measurement[field] is not None), f"{label}: current RSS status/value disagree")
    require(type(measurement.get("checksum")) in (int, float) and math.isfinite(measurement["checksum"]) and measurement["checksum"] > 0,
            f"{label}: invalid loop checksum")
    outputs = {}
    for record in correctness:
        require(isinstance(record.get("output"), dict), f"{label}: missing semantic output")
        check_totals(record["output"], size, label)
        outputs[record["phase"]] = record["output"]
    require(outputs["after-unchanged"]["nowMs"] - outputs["warmed"]["nowMs"] == 100_000,
            f"{label}: elapsed synthetic time differs")
    return {"role": role, "source": source, "size": size, "shape": shape, "trial": trial,
            "measurement": measurement, "outputs": outputs}


def load_trace(root, role, source, trial):
    label = f"{role}-compatibility-{trial}"
    records = read_records(root, label, source, trial, "SpeedEngineBenchmarkTests.testReplacementAndBoundaryCompatibilityTrace")
    require([record.get("phase") for record in records] == list(TRACE_PHASES), f"{label}: trace phases missing, duplicate, or reordered")
    require(all(record.get("kind") == "compatibility" for record in records), f"{label}: unexpected trace record kind")
    payload = []
    for record in records:
        require(isinstance(record.get("output"), dict) and isinstance(record.get("storedKeys"), list), f"{label}: incomplete trace payload")
        require(record["storedKeys"] == sorted(set(record["storedKeys"])), f"{label}: stored keys are not unique/sorted")
        payload.append({"phase": record["phase"], "output": record["output"], "storedKeys": record["storedKeys"]})
    return payload


def metrics_for(cases):
    result = {}
    for field in MEASUREMENT_FIELDS:
        values = [case["measurement"][field] for case in cases]
        known = [value for value in values if value is not None]
        result[field] = {
            "median": statistics.median(known) if len(known) == len(values) else None,
            "minimum": min(known) if known else None, "maximum": max(known) if known else None,
            "availableTrials": len(known), "trials": len(values),
        }
    return result


def validate_and_summarize(root, baseline, candidate, fixture):
    require(re.fullmatch(r"[0-9a-f]{40}", baseline) is not None, "Exact 40-character baseline SHA required")
    require(re.fullmatch(r"[0-9a-f]{40}", candidate) is not None, "Exact 40-character candidate SHA required")
    manifest = read_json(root / "manifest.json")
    require(isinstance(manifest, dict), "manifest: expected an object")
    expected = {"schemaVersion": 1, "baseline": baseline, "candidate": candidate,
                "actualSources": {"baseline": baseline, "candidate": candidate},
                "configuration": "release", "swiftFlags": ["-Xswiftc", "-enable-testing"],
                "responses": list(SIZES), "shapes": list(SHAPES), "trials": list(TRIALS), "ticks": 200,
                "freshProcessPerCase": True, "singleHostedRunner": True, "recordTransport": "per-case-jsonl-v1",
                "seedOrder": "empty-ledger-then-indexed-upserts-v1"}
    for field, value in expected.items():
        require(type(manifest.get(field)) is type(value) and manifest.get(field) == value, f"manifest: wrong {field}")
    require(re.fullmatch(r"[0-9a-f]{40}", manifest.get("harness", "")) is not None, "manifest: exact harness SHA required")
    require(manifest.get("fixtureSha256") == hashlib.sha256(fixture.read_bytes()).hexdigest(), "manifest: fixture SHA-256 differs from harness fixture")
    require((root / "toolchain.txt").is_file(), "Missing hosted toolchain record")
    for role in ("baseline", "candidate"):
        for phase in ("provenance-before", "prepare-lfs", "build", "provenance-after"):
            arguments = ("--build-tests", "release", "-enable-testing") if phase == "build" else ()
            check_exit(root, f"{role}-{phase}", arguments)

    cases = {}
    traces = {}
    comparisons = 0
    for role, source in (("baseline", baseline), ("candidate", candidate)):
        for trial in TRIALS:
            traces[(role, trial)] = load_trace(root, role, source, trial)
            if trial != 1:
                compare_semantics(traces[(role, 1)], traces[(role, trial)], (role, "trace", trial))
                comparisons += 1
        for size in SIZES:
            for shape in SHAPES:
                for trial in TRIALS:
                    key = (role, size, shape, trial)
                    cases[key] = load_case(root, role, source, size, shape, trial)
                    if trial != 1:
                        compare_semantics(cases[(role, size, shape, 1)]["outputs"], cases[key]["outputs"],
                                          (role, size, shape, "self-consistency", trial))
                        comparisons += 1
    for trial in TRIALS:
        compare_semantics(traces[("baseline", trial)], traces[("candidate", trial)], ("paired-trace", trial))
        comparisons += 1
        for size in SIZES:
            for shape in SHAPES:
                left, right = (cases[(role, size, shape, trial)] for role in ("baseline", "candidate"))
                compare_semantics(left["outputs"], right["outputs"], ("paired", size, shape, trial))
                require(abs(left["measurement"]["checksum"] - right["measurement"]["checksum"]) <= 1e-6,
                        f"paired {size}/{shape}/{trial}: loop checksum differs")
                comparisons += 1
    summary = []
    for size in SIZES:
        for shape in SHAPES:
            by_role = {role: metrics_for([cases[(role, size, shape, trial)] for trial in TRIALS])
                       for role in ("baseline", "candidate")}
            reductions = {}
            for field in ("cpuMilliseconds", "milliseconds", "processPeakRSSBytesAfterLoop", "processCurrentRSSBytesAfterLoop"):
                first, second = (by_role[role][field]["median"] for role in ("baseline", "candidate"))
                reductions[field] = 100 * (1 - second / first) if first is not None and second is not None and first > 0 else None
            summary.append({"fixtureResponses": size, "shape": shape, "byRole": by_role,
                            "observedMedianReductionPercent": reductions})
    return {"schemaVersion": 1, "status": "PASS", "baseline": baseline, "candidate": candidate,
            "manifest": manifest, "semanticComparisons": comparisons, "absoluteFloatTolerance": 1e-6,
            "performanceGate": "No speed or RSS threshold; PASS means complete evidence and compatible semantics.",
            "summary": summary, "records": list(cases.values()), "limitations": LIMITATIONS}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--fixture", type=Path, default=Path(__file__).with_name("fixtures") / "SpeedEngineBenchmarkTests.swift")
    args = parser.parse_args(argv)
    args.evidence.mkdir(parents=True, exist_ok=True)
    try:
        result = validate_and_summarize(args.evidence, args.baseline, args.candidate, args.fixture)
    except (EvidenceError, OSError, KeyError, TypeError) as error:
        result = {"schemaVersion": 1, "status": "FAIL", "baseline": args.baseline, "candidate": args.candidate,
                  "errors": [str(error)], "limitations": LIMITATIONS}
    (args.evidence / "comparison.json").write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
    print(json.dumps({key: value for key, value in result.items() if key != "records"}, indent=2, allow_nan=False))
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
