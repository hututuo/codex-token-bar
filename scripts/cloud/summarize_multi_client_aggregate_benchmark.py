#!/usr/bin/env python3
"""Validate real paired Rust aggregate evidence before presenting measurements."""
import argparse
from collections import defaultdict
import hashlib
import json
import math
from pathlib import Path
import re
import statistics

PREFIX = "MULTI_CLIENT_AGGREGATE_BENCHMARK "
TEST = "core::multi_client_usage::cloud_aggregate_benchmark::production_aggregate_pair"
NOW = 1_800_003_600
CLIENTS = ("claudeCode", "claudeDesktop", "deepseek", "gemini", "opencode", "antigravity")
MODELS = (("claude-opus-5", "claude-opus-5-fast", "synthetic-unknown"),
          ("claude-sonnet-5", "claude-sonnet-5-fast", "synthetic-unknown"),
          ("deepseek-chat", "deepseek-reasoner", "synthetic-unknown"),
          ("gemini-2.5-pro", "gemini-2.5-flash", "synthetic-unknown"),
          ("gpt-5", "gpt-5.1", "synthetic-unknown"),
          ("claude-opus-5", "gemini-2.5-pro", "synthetic-unknown"))
PHASES = ("cold", "cache-hit")
METRICS = ("wallMilliseconds", "cpuMilliseconds", "userMilliseconds", "systemMilliseconds",
           "processPeakRSSBytesBeforeFixture", "processPeakRSSBytesBeforeLoop", "processPeakRSSBytesAfterLoop")
COUNTERS = ("inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens", "reasoningTokens")
SUMMARY_ARRAYS = ("summaries", "todaySummaries", "sevenDaySummaries")
ARRAYS = (*SUMMARY_ARRAYS, "trendBuckets", "dailyBuckets")
LIMITATIONS = [
    "Synthetic schema2 aggregate subsystem only; no whole-app, installed-runtime, or private-ledger performance claim.",
    "Cold means application aggregate, scoped-summary and price-tally caches cleared; OS/SQLite pages and bundled price parsing are warm.",
    "Wall and process user+system CPU cover production entry-point calls; fixture generation, cache resets, JSON checks and tracing are outside timers.",
    "RSS is lifetime process peak including the test harness, priming and fixture read/hash, not query allocation or physical footprint.",
    "SQLite VM/statement witnesses are from one additional untimed call, not the timed loop.",
    "Paired results describe the same hosted runner/toolchain and synthetic workload; no universal speed or memory threshold is asserted.",
]


class EvidenceError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise EvidenceError(message)


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read_json(path):
    def invalid(value):
        raise ValueError("nonfinite constant " + value)
    try:
        return json.loads(Path(path).read_text(), parse_constant=invalid)
    except (OSError, ValueError) as error:
        raise EvidenceError(f"{path}: invalid/missing JSON: {error}") from error


def compare(expected, actual, path="root"):
    if isinstance(expected, dict) and isinstance(actual, dict):
        require(expected.keys() == actual.keys(), f"{path}: object keys differ")
        for key in sorted(expected):
            compare(expected[key], actual[key], f"{path}.{key}")
    elif isinstance(expected, list) and isinstance(actual, list):
        require(len(expected) == len(actual), f"{path}: array lengths differ")
        for index, (left, right) in enumerate(zip(expected, actual)):
            compare(left, right, f"{path}[{index}]")
    elif type(expected) in (int, float) and type(actual) in (int, float):
        require(math.isfinite(expected) and math.isfinite(actual) and expected == actual,
                f"{path}: numeric values differ: {expected!r} != {actual!r}")
    else:
        require(type(expected) is type(actual) and expected == actual, f"{path}: values differ")


def logical_rows(size, changed=False):
    """Independent arithmetic fixture oracle, never used to time an aggregate."""
    ages = (0, 1, 6, 7, 29, 30, 364, 365)
    for index in range(size):
        client_index = index % len(CLIENTS)
        yield {"index": index, "client": CLIENTS[client_index],
               "model": MODELS[client_index][index // 6 % 3],
               "timestamp": NOW - ages[index % len(ages)] * 86_400 - index % 300,
               "inputTokens": 1_000 + index % 101,
               "outputTokens": 100 + index % 37 + (77 if changed and index == 2 else 0),
               "cacheReadTokens": None if index % 11 == 0 else 100 + index % 97,
               "cacheWriteTokens": None if index % 13 == 0 else 40 + index % 19,
               "reasoningTokens": None if index % 17 == 0 else index % 23}


def expected_groups(size, array, changed=False):
    groups = defaultdict(list)
    day = NOW // 86_400 * 86_400
    for row in logical_rows(size, changed):
        timestamp = row["timestamp"]
        if array == "todaySummaries" and timestamp < day:
            continue
        if array == "sevenDaySummaries" and timestamp < NOW // 300 * 300 - 7 * 86_400:
            continue
        if array == "trendBuckets" and timestamp < NOW - 30 * 86_400:
            continue
        if array == "dailyBuckets" and timestamp < day - 364 * 86_400:
            continue
        key = (row["client"], row["model"])
        if array not in SUMMARY_ARRAYS:
            width = 300 if array == "trendBuckets" else 86_400
            key = (row["client"], timestamp // width * width, row["model"])
        groups[key].append(row)
    result = {}
    for key, rows in groups.items():
        values = {"requests": len(rows)}
        for field in COUNTERS:
            known = [row[field] for row in rows if row[field] is not None]
            values[field] = sum(known) if known else None
        values["cacheReadComplete"] = all(row["cacheReadTokens"] is not None for row in rows)
        if array in SUMMARY_ARRAYS:
            values["incompleteFields"] = any(row[field] is None for row in rows for field in COUNTERS[2:])
        else:
            values["cacheWriteComplete"] = all(row["cacheWriteTokens"] is not None for row in rows)
        result[key] = values
    return result


def validate_output(value, size, changed=False):
    require(isinstance(value, dict) and set(value) == {*ARRAYS, "updatedAt"}, "complete aggregate JSON fields missing")
    require(isinstance(value["updatedAt"], str) and value["updatedAt"], "updatedAt missing")
    for array in ARRAYS:
        rows = value[array]
        require(isinstance(rows, list) and rows, f"{array}: empty/stub output")
        expected = expected_groups(size, array, changed)
        actual = {}
        for row in rows:
            require(isinstance(row, dict), f"{array}: invalid row")
            required = {"client", "model", *COUNTERS, "requests", "unpricedRequests", "cacheReadComplete"}
            required.update({"presentation", "lastSeen", "incompleteFields", "apiCostUSD"} if array in SUMMARY_ARRAYS
                            else {"startUnix", "apiCostMicroUSD", "cacheWriteComplete"})
            require(required <= row.keys(), f"{array}: complete row fields missing")
            key = (row.get("client"), row.get("model")) if array in SUMMARY_ARRAYS else (
                row.get("client"), row.get("startUnix"), row.get("model"))
            require(key not in actual, f"{array}: duplicate key")
            actual[key] = {field: row.get(field) for field in expected.get(key, {})}
            cost_field = "apiCostUSD" if array in SUMMARY_ARRAYS else "apiCostMicroUSD"
            require(cost_field in row and "unpricedRequests" in row, f"{array}: price semantics omitted")
        compare(expected, actual, array + " independent oracle")
    require(any(row.get("apiCostUSD", 0) not in (None, 0) for row in value["summaries"]), "all pricing is empty/stub")
    require(any(row.get("unpricedRequests", 0) > 0 for row in value["summaries"]), "unknown-model pricing branch absent")


def command(root, label, required=()):
    status = read_json(root / (label + ".exit.json"))
    require(type(status.get("commandExitCode")) is int and status["commandExitCode"] == 0,
            f"{label}: command failed")
    require(type(status.get("logExitCode")) is int and status["logExitCode"] == 0, f"{label}: logging failed")
    argv = status.get("argv")
    require(isinstance(argv, list) and argv, f"{label}: argv missing")
    require(all(item in argv for item in required), f"{label}: required argv missing")
    log = root / (label + ".log")
    require(log.is_file(), f"{label}: log missing")
    return log.read_text()


def validate_and_summarize(root, fixture):
    root, fixture = Path(root), Path(fixture)
    manifest = read_json(root / "manifest.json")
    require(manifest.get("schemaVersion") == 1 and manifest.get("status") == "COMPLETE", "manifest incomplete")
    require(manifest.get("singleHostedRunner") is True and manifest.get("freshProcessPerCase") is True,
            "same-host/fresh-process contract missing")
    require(manifest.get("fixtureSha256") == sha256(fixture), "fixture SHA-256 drift")
    inputs = [Path(__file__), Path(__file__).with_name("run_multi_client_aggregate_benchmark.py"), fixture]
    require(manifest.get("harnessInputs") == {path.name: sha256(path) for path in inputs}, "harness input identity drift")
    require(manifest.get("nowUnix") == NOW and manifest.get("timezone") == "UTC", "clock/timezone differs")
    require(manifest.get("sizes") and all(type(size) is int and size >= 24 for size in manifest["sizes"]), "invalid sizes")
    require(type(manifest.get("trials")) is int and manifest["trials"] >= 2, "at least two trials required")
    require(manifest.get("witnessExpectations") == {"baseline": "canonical", "candidate": "staged"}, "mechanism expectations missing")
    for role in ("baseline", "candidate"):
        provenance = manifest["sources"][role]
        require(re.fullmatch(r"[0-9a-f]{40}", provenance.get("sha", "")) is not None, "exact source SHA required")
        for field in ("sourceSha256", "injectedSourceSha256", "sqlSha256", "pricesSha256", "binarySha256", "fixtureSha256"):
            require(re.fullmatch(r"[0-9a-f]{64}", provenance.get(field, "")) is not None, f"{role}: missing {field}")
        require(provenance["fixtureSha256"] == manifest["fixtureSha256"], "injected fixture identity differs")
        binary = (root / provenance.get("binaryArtifact", "")).resolve()
        require(binary.is_relative_to(root.resolve()) and binary.is_file() and sha256(binary) == provenance["binarySha256"],
                f"{role}: retained binary missing/drifted")
        require(provenance.get("restoredSourceSha256") == provenance["sourceSha256"] and provenance.get("cleanAfter") is True,
                f"{role}: production checkout not restored/clean")
        command(root, role + "-build", ("test", "--lib", "--release", "--locked", "--no-run", "--message-format=json"))
        command(root, role + "-list", ("--list", "--exact", TEST))
        require(f"{TEST}: test" in (root / (role + "-list.log")).read_text(), "test binary lacks exact production test")
    for field in ("sqlSha256", "pricesSha256"):
        require(manifest["sources"]["baseline"][field] == manifest["sources"]["candidate"][field], f"paired {field} differs")
    records = {}
    order = []
    for size in manifest["sizes"]:
        seed = manifest["seeds"][str(size)]
        seed_path = (root / seed["file"]).resolve()
        require(seed_path.is_relative_to(root.resolve()), "synthetic seed must stay inside evidence")
        require(sha256(seed_path) == seed["sha256"], "synthetic seed artifact drift")
        for phase in PHASES:
            iterations = manifest["iterations"][phase]
            require(type(iterations) is int and iterations > 0, "invalid iterations")
            for trial in range(1, manifest["trials"] + 1):
                roles = ("baseline", "candidate") if trial % 2 else ("candidate", "baseline")
                for role in roles:
                    label = f"{role}-{size}-{phase}-{trial}"
                    order.append(label)
                    text = command(root, label, ("--exact", TEST, "--nocapture", "--test-threads=1"))
                    require(re.search(r"test result: ok\. 1 passed; 0 failed; 0 ignored;", text), f"{label}: missing exact one-test success (zero/skipped tests rejected)")
                    lines = [line.split(PREFIX, 1)[1] for line in text.splitlines() if PREFIX in line]
                    require(len(lines) == 1, f"{label}: expected exactly one benchmark record")
                    record = json.loads(lines[0])
                    expected_identity = {"schemaVersion": 1, "source": manifest["sources"][role]["sha"], "logicalRows": size,
                                         "physicalRows": seed["physicalRows"], "databaseSha256": seed["sha256"],
                                         "phase": phase, "trial": trial, "iterations": iterations,
                                         "productionEntryPoint": "read_cached_multi_client_aggregates"}
                    provenance = manifest["sources"][role]
                    expected_identity.update({"fixtureSha256": provenance["fixtureSha256"],
                                              "productionSourceSha256": provenance["injectedSourceSha256"],
                                              "sqlSha256": provenance["sqlSha256"], "pricesSha256": provenance["pricesSha256"]})
                    for field, expected in expected_identity.items():
                        require(type(record.get(field)) is type(expected) and record[field] == expected, f"{label}: identity {field} differs")
                    require(type(record.get("cacheHitDelta")) is int and record["cacheHitDelta"] == (iterations if phase == "cache-hit" else 0), f"{label}: cache-hit proof differs")
                    checksums = record.get("checksums", [])
                    serialized = record.get("outputJSON")
                    require(isinstance(serialized, str), f"{label}: serialized semantic bytes missing")
                    compare(json.loads(serialized), record["output"], f"{label} serialized output")
                    require(checksums == [hashlib.sha256(serialized.encode()).hexdigest()] * iterations, f"{label}: repeat checksum differs")
                    validate_output(record["output"], size)
                    validate_output(record["afterMutation"], size, True)
                    require(record["output"]["updatedAt"] != record["afterMutation"]["updatedAt"], f"{label}: metadata mutation ignored")
                    measurement = record["measurement"]
                    for field in METRICS:
                        require(type(measurement.get(field)) in (int, float) and math.isfinite(measurement[field]) and measurement[field] >= 0,
                                f"{label}: invalid {field}")
                    require(measurement["wallMilliseconds"] > 0 and measurement["cpuMilliseconds"] > 0, f"{label}: nonpositive duration")
                    require(abs(measurement["cpuMilliseconds"] - measurement["userMilliseconds"] - measurement["systemMilliseconds"]) < 1e-8, f"{label}: CPU sum differs")
                    require(0 < measurement[METRICS[-3]] <= measurement[METRICS[-2]] <= measurement[METRICS[-1]], f"{label}: nonmonotonic peak RSS")
                    witness = record["witness"]
                    require(isinstance(witness, dict) and all(type(witness.get(field)) is int and witness[field] >= 0
                        for field in ("statements", "profiles", "canonicalStatements", "stagingCreates", "stagedReads", "vmSteps")),
                        f"{label}: incomplete/invalid SQLite witness")
                    require(witness.get("profiles", 0) > 0 and witness.get("vmSteps", 0) > 0, f"{label}: no real SQLite witness")
                    if phase == "cache-hit":
                        require(all(witness.get(field) == 0 for field in ("canonicalStatements", "stagingCreates", "stagedReads")), f"{label}: cache hit rebuilt aggregate")
                    elif role == "baseline":
                        require(witness.get("canonicalStatements", 0) >= 8 and witness.get("stagingCreates") == 0 and witness.get("stagedReads") == 0, f"{label}: baseline production mechanism absent")
                    else:
                        require(witness.get("canonicalStatements") == 1 and witness.get("stagingCreates") == 1 and witness.get("stagedReads", 0) >= 8, f"{label}: candidate production staging absent")
                    records[(role, size, phase, trial)] = record
    require(manifest.get("executionOrder") == order, "paired alternating execution order differs")
    comparisons = 0
    for size in manifest["sizes"]:
        reference = records[("baseline", size, "cold", 1)]
        for key, record in records.items():
            if key[1] != size:
                continue
            for field in ("output", "afterMutation"):
                compare(reference[field], record[field], f"paired {key} {field}")
                comparisons += 1
    summaries = []
    for size in manifest["sizes"]:
        for phase in PHASES:
            by_role = {}
            for role in ("baseline", "candidate"):
                rows = [records[(role, size, phase, trial)] for trial in range(1, manifest["trials"] + 1)]
                by_role[role] = {field: statistics.median(row["measurement"][field] / row["iterations"]
                    if field.endswith("Milliseconds") else row["measurement"][field] for row in rows) for field in METRICS}
            ratios = {field: by_role["candidate"][field] / by_role["baseline"][field]
                      if by_role["baseline"][field] else None for field in METRICS}
            summaries.append({"logicalRows": size, "phase": phase, "medianPerCallByRole": by_role,
                              "candidateToBaselineRatio": ratios})
    return {"status": "PASS", "actualMeasurement": True, "scope": "real Rust production aggregate; synthetic schema2",
            "semanticComparisons": comparisons, "cases": len(records), "summary": summaries,
            "limitations": LIMITATIONS, "performanceGate": "No speed or RSS threshold; correctness/provenance/mechanism gates only."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--fixture", type=Path, default=Path(__file__).with_name("fixtures") / "MultiClientAggregateBenchmark.rs")
    arguments = parser.parse_args()
    try:
        result = validate_and_summarize(arguments.evidence, arguments.fixture)
    except (EvidenceError, KeyError, TypeError, ValueError) as error:
        result = {"status": "FAIL", "actualMeasurement": False, "error": str(error), "limitations": LIMITATIONS}
    (arguments.evidence / "summary.json").write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
