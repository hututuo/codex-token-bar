#!/usr/bin/env python3
"""Run the production-path fixture inside a retained, isolated hosted temp root."""

import argparse
import json
import math
import re
import os
from pathlib import Path
import subprocess
import sys
import tempfile


REQUIRED_CHECKS = {
    "bootstrap": {},
    "concurrent-a-write-probe": {},
    "public-read-only-routing": dict.fromkeys(("startupReadRefused", "concurrentPublisherRead",
        "uncommittedValueHidden", "mainWriteRefused", "unknownPartitionNotRegistered"), True),
    "quota": {"activeRows": 1, "legacyFacts": [1, 2]},
    "modeltrace": {"runs": 2},
    "body-speed": {"samples": 2, "trendPoints": 1},
    "ledger-b": {"rows": 1},
    "exact-import-stage-and-home-scope": {"homeOneTokens": 175, "homeTwoTokens": 240},
    "exact-concurrent-a-write-observed": {},
    "runtime-recovery-production-path": {
        "tokensAfterReplay": 175,
        **dict.fromkeys(("externalStateReadOnly", "invalidCandidateRejected", "legacyCheckpointMismatch",
            "legacyStateColumnsReadWithoutImport", "liveStateRefreshed", "namespaceCandidateResumed",
            "oldStagePreserved"), True),
        "fixedPool": {"catalogGrowth": 0, "storeGrowth": 0, "jobs": 13,
            **dict.fromkeys(("idempotentCleanup", "publicationRollback", "readOnly", "typedTempAlias"), True),
            "legacy": {"buildingKept": True, "changedEvidenceKept": True, "idempotent": True,
                "publishedTokens": 134, "rollback": True}},
    },
    "legacy-backfill-indexed-reconciliation": {"preservedEventIds": True, "legacyRows": 4096,
        "legacyCountCalls": 4096, "tokensAfterReplay": 20480},
    "pool-process-crash-recovery": {},
    "published-recovery-reads": {"oldAndNewFacts": [123, 789], "tokensWithoutRawSessions": 175,
        "aUnchanged": True, "retryReadOnly": True},
    "legacy-source-preservation": {"count": 4},
    "rerun-and-fail-closed": {},
}
CRASH_PHASES = ("initialize-before-commit", "chunk-committed", "seal-before-commit", "seal-committed",
                "publication-before-commit", "publication-committed", "cleanup-before-commit", "cleanup-committed")
SCALE_CHECK = "exact-rust-production-scale-fixture"


def require_fields(actual, expected, context):
    """Compare typed proofs; in Python True must not stand in for one row."""
    if type(actual) is not type(expected):
        raise ValueError(f"Invalid production proof type: {context}")
    if isinstance(expected, dict):
        for key, value in expected.items():
            if key not in actual:
                raise ValueError(f"Missing production proof: {context}.{key}")
            require_fields(actual[key], value, f"{context}.{key}")
    elif isinstance(expected, list):
        if len(actual) != len(expected):
            raise ValueError(f"Invalid production proof length: {context}")
        for index, (value, wanted) in enumerate(zip(actual, expected)):
            require_fields(value, wanted, f"{context}[{index}]")
    elif actual != expected:
        raise ValueError(f"Invalid production proof: {context}")


def validate_production_report(result, scale_required):
    require_fields(result, {"status": "PASS"}, "report")
    checks = result.get("checks")
    if not isinstance(checks, list) or any(not isinstance(c, dict) for c in checks):
        raise ValueError("Missing or invalid production checks")
    names = [c.get("name") for c in checks]
    if any(not isinstance(name, str) for name in names) or len(set(names)) != len(names):
        raise ValueError("Invalid or duplicate production check names")
    expected_names = set(REQUIRED_CHECKS) | ({SCALE_CHECK} if scale_required else set())
    if set(names) != expected_names:
        raise ValueError(f"Production check set mismatch: missing={sorted(expected_names - set(names))}, "
                         f"unexpected={sorted(set(names) - expected_names)}")
    by_name = {c["name"]: c for c in checks}
    for name, proof in REQUIRED_CHECKS.items():
        require_fields(by_name[name], {"status": "PASS", **proof}, name)
    stage = by_name["exact-import-stage-and-home-scope"]
    before, after = stage.get("stageObjectsBefore"), stage.get("stageObjectsAfter")
    if type(before) is not int or type(after) is not int or before <= 0 or after < before:
        raise ValueError("Legacy stage recovery evidence was removed")
    phases = by_name["pool-process-crash-recovery"].get("phases")
    if not isinstance(phases, list) or len(phases) != len(CRASH_PHASES):
        raise ValueError("Missing crash recovery phases")
    seen = set()
    for case in phases:
        if not isinstance(case, dict) or case.get("phase") not in CRASH_PHASES or case["phase"] in seen:
            raise ValueError("Invalid or duplicate crash recovery phase")
        phase = case["phase"]
        seen.add(phase)
        require_fields(case, {"forcedExit": 86}, phase)
        resumes = case.get("resumes")
        if not isinstance(resumes, list) or len(resumes) != 3:
            raise ValueError(f"Expected three independent reopens: {phase}")
        for index, proof in enumerate(resumes):
            require_fields(proof, {"status": "PASS", "phase": phase, "oldTokens": 123,
                "publishedTokens": 134, "publicationReceipts": 1, "reclaimIdempotent": True,
                "repeatedStartupChecks": 3}, f"{phase}.resume[{index}]")
            if type(proof.get("alreadyRecovered")) is not bool or (index > 0 and not proof["alreadyRecovered"]):
                raise ValueError(f"Repeated reopen was not already recovered: {phase}")
    validate_concurrent_probe(result)
    if scale_required:
        require_fields(by_name[SCALE_CHECK], {"status": "PROFILED"}, SCALE_CHECK)
    validate_native_scale(result, scale_required)


def validate_concurrent_probe(result):
    checks = result.get("checks", [])
    probes = [check for check in checks if check.get("name") == "concurrent-a-write-probe"]
    observed = [check for check in checks if check.get("name") == "exact-concurrent-a-write-observed"]
    if len(probes) != 1 or len(observed) != 1:
        raise ValueError("Required concurrent A write probe was not executed exactly once")
    probe, observation = probes[0], observed[0]
    negative = probe.get("negativeControl", {})
    if (probe.get("status") != "PASS" or probe.get("timeoutMilliseconds") != 250
            or probe.get("serializedProbeConnection") is not True
            or probe.get("parallelProbeRows") != 4 or probe.get("catalogStable") is not True
            or not isinstance(negative, dict) or negative.get("heldByBeginImmediate") is not True
            or negative.get("writeResumedAfterRollback") is not True
            or negative.get("sqliteCode") not in ("Some(DatabaseBusy)", "Some(DatabaseLocked)")):
        raise ValueError("Concurrent probe lacks its original deadline, lock negative control or catalog proof")
    count = observation.get("probeWrites")
    if observation.get("status") != "PASS" or type(count) is not int or count <= 0:
        raise ValueError("Actual Exact scans did not execute the concurrent A write probe")


def validate_native_scale(result, required):
    if not required:
        return
    profiles = [check for check in result.get("checks", [])
                if check.get("name") == "exact-rust-production-scale-fixture"]
    if len(profiles) != 1:
        raise ValueError("Required native production scale profile was not executed exactly once")
    profile = profiles[0]
    if profile.get("sourceCounts") != 4124 or profile.get("events") != 503128:
        raise ValueError("Native pressure input changed")
    stores = profile.get("stores")
    if not isinstance(stores, dict) or stores.get("seededEmptyCandidateNamespaces") != 6250:
        raise ValueError("Native large-catalog pressure was omitted")
    if profile.get("budgetPassed") is not True:
        raise ValueError("Native scale exceeded its unchanged/backfill budget; full profile retained")
    # Keep the original limits independently of the producer's PASS flag.
    require_fields(profile.get("budget"), {"backfillSecondsMax": 600.0, "unchangedP95SecondsMax": 1.0}, "scale.budget")
    for field, maximum in (("backfillSeconds", 600.0), ("unchangedP95", 1.0)):
        value = profile.get(field)
        if type(value) not in (int, float) or not math.isfinite(value) or value < 0 or value > maximum:
            raise ValueError(f"Native scale exceeds or lacks its original {field} budget")
    proof = profile.get("correctness", {})
    if not isinstance(proof, dict):
        raise ValueError("Native typed raw accounting proof is missing")
    before = proof.get("rawAccountingDigestBefore")
    if not isinstance(before, str) or re.fullmatch(r"[0-9a-f]{64}", before) is None or proof.get("rawAccountingDigestAfter") != before:
        raise ValueError("Native typed raw accounting proof is missing or changed")


def main():
    # Windows hosted shells may default to cp1252 even though the child and
    # retained evidence are UTF-8. Rendering a Chinese diagnostic must not stop
    # this launcher before it checks the actual fixture exit status/report.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="backslashreplace")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--output", type=Path, default=Path("runtime-recovery-production.json"))
    args = parser.parse_args()
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise SystemExit("This launcher requires a hosted Actions disposable workspace.")
    log_path = args.output.with_suffix(".log")
    validation_path = args.output.with_suffix(".validation.json")
    for path in (args.output, log_path, validation_path):
        if path.exists() or path.is_symlink():
            raise SystemExit(f"Refusing to overwrite fixture evidence: {path}")
    base = os.environ.get("RUNNER_TEMP") if os.name == "nt" else tempfile.gettempdir()
    if not base:
        raise SystemExit("Missing hosted temp directory")
    base = Path(base).resolve()
    home = Path.home().resolve()
    if base.is_relative_to(home) or home.is_relative_to(base):
        raise SystemExit("Hosted temp directory overlaps the user home")
    root = Path(tempfile.mkdtemp(prefix="tokenbar-runtime-", dir=base)).resolve()
    # Rust canonicalize returns the extended prefix on Windows; pass that same
    # canonical form to the fixture's strict environment containment checks.
    native_root = str(root)
    if os.name == "nt" and not native_root.startswith("\\\\?\\"):
        native_root = "\\\\?\\" + native_root
    root = Path(native_root)
    env = os.environ.copy()
    for name, directory in {
        "CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR": "tauri-support",
        "CODEX_TOKEN_BAR_TAURI_CACHE_DIR": "tauri-cache",
        "CODEX_TOKEN_BAR_SUPPORT_BASE_DIR": "shared-support",
        "CODEX_TOKEN_BAR_CACHE_BASE_DIR": "shared-cache",
        "CODEX_TOKEN_BAR_TAURI_USAGE_CACHE_DIR": "legacy-usage",
    }.items():
        env[name] = str(root / directory)
    binary = args.binary.resolve()
    if os.name == "nt":
        binary = binary.with_suffix(".exe")
    completed = subprocess.run([str(binary), str(root)], env=env,
                               capture_output=True, text=True, encoding="utf-8")
    # Preserve the first production failure before the longer unit suite runs.
    # The disposable fixture contains no user data. Do not turn failed output
    # into a successful profile; this is just evidence for its actual phase.
    args.output.with_suffix(".log").write_text(
        completed.stderr + completed.stdout, encoding="utf-8")
    if completed.stderr:
        print(completed.stderr, end="")
    print(completed.stdout, end="")
    decision = {"status": "FAIL", "producerExitCode": completed.returncode,
                "fixtureRootRetained": True, "fixtureRoot": str(root)}
    try:
        if completed.returncode:
            raise ValueError(f"Production-path fixture exited {completed.returncode}")
        result = json.loads(completed.stdout)
        validate_production_report(result, env.get("TOKENBAR_NATIVE_SCALE") == "1")
    except ValueError as error:
        decision["error"] = str(error)
        validation_path.write_text(json.dumps(decision, indent=2) + "\n", encoding="utf-8")
        raise SystemExit(completed.returncode or str(error)) from error
    result["fixtureRootRetained"] = True
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    decision["status"] = "PASS"
    validation_path.write_text(json.dumps(decision, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
