#!/usr/bin/env python3
"""Run real native routes with owned synthetic data and retain failed evidence.

cfg(test) changes connection ownership, so this production example remains a
separate, required gate. Python contract tests do not substitute for its run.
"""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from native_fixture_evidence import FixtureAttempt, execute_native, fixture_temporary_base, native_path


def validate_native_report(report: object) -> dict:
    required = {"bootstrap", "quota", "modeltrace", "body-speed", "ledger-b",
                "exact-import-stage-and-home-scope", "live-external-state-readers",
                "legacy-source-preservation", "rerun-and-fail-closed", "bounded-stage-replacement",
                "public-read-only-routing", "runtime-recovery-production-path",
                "legacy-backfill-indexed-reconciliation"}
    scenarios = report.get("checks") if isinstance(report, dict) else None
    if (not isinstance(scenarios, list) or len(scenarios) != len(required)
            or any(not isinstance(item, dict) or not isinstance(item.get("name"), str)
                   for item in scenarios)):
        raise ValueError("Incomplete production-path evidence")
    checks = {item["name"]: item for item in scenarios}
    # Validate the original list before allowing a name-indexed lookup to
    # collapse two results: a later PASS must not hide an earlier failure.
    if (report.get("status") != "PASS" or len(checks) != len(scenarios)
            or set(checks) != required):
        raise ValueError("Incomplete production-path evidence")
    if any(item.get("status") != "PASS" for item in checks.values()):
        raise ValueError("Failed production-path scenario")
    if report.get("concurrentWriterProbeEnabled") is not True or report.get("concurrentWriteAssertions", 0) <= 0:
        raise ValueError("Default production fixture lost its concurrent A-writer assertion")
    if any(checks["bootstrap"].get(field) is not True for field in (
        "incompleteExactDiscoveryFrozen", "incompleteExactSnapshotUnchanged",
        "independentPendingImportRecovered", "completeDiscoveryResumesExactHistory",
        "recoveryRetryPreservesHistory",
    )):
        raise ValueError("Incomplete Exact discovery did not preserve its pending recovery boundary")
    if checks["quota"].get("retainedReaderRows") != 3 or checks["quota"].get("uniqueRetainedRows") != 2 or not checks["quota"].get("oldCycleSchema"):
        raise ValueError("Retained quota history was not verified")
    if any(checks["runtime-recovery-production-path"].get(field) is not True for field in (
        "startupNamespaceOnlyIdentity", "startupLastGoodRestored", "startupConcurrentPublisherRead",
        "startupLegacySourceUnchanged", "startupLegacyNotImported", "startupSqliteWriteRefused",
    )):
        raise ValueError("Read-only startup recovery was not verified through production routes")
    if any(checks["runtime-recovery-production-path"].get(field) is not True for field in (
        "retainedStageContentVerified", "changedStageImportRejected",
        "stageMutationBeforePublicationRejected",
        "sealedStageMissingSealRejected", "resealedStageImportRejected",
        "stageSchemaMutationRejected", "stageSchemaMutationBeforePublicationRejected",
        "unsealedStageRebuiltFromSource", "pendingHistoryOverwriteRejected",
        "unsealedPreservationMutationRejected",
        "missingSourcePendingHistoryPublished",
    )):
        raise ValueError("Retained stage content, schema, seal ownership and safe rebuild were not verified")
    return report


def main() -> None:
    repository = Path(__file__).resolve().parents[1]
    attempt = FixtureAttempt(repository / "native-production-readers.json", label="readers")
    phase = "source-identity"
    try:
        source_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository, text=True).strip()
        changes = subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=no"],
                                          cwd=repository, text=True).splitlines()
        attempt.update(source_sha=source_sha, working_tree_dirty=bool(changes), source_changes=changes)
        phase = "prepare-root"
        base = fixture_temporary_base()
        env = attempt.create_root(base, prefix="tokenbar-production-readers-", slugs=("s", "c", "ss", "sc", "uc"))
        phase = "native-execution"
        attempt.update(phase=phase)
        command = ["cargo", "run", "--locked", "--manifest-path", "tauri-app/src-tauri/Cargo.toml",
                   "--features", "business-store-fixture", "--example", "business-store-fixture",
                   "--", native_path(attempt.root)]
        result = execute_native(command, cwd=repository, env=env, timeout=900, log_directory=attempt.directory)
        attempt.logs(result.stdout, result.stderr)
        print(result.stdout, end="")
        if result.returncode:
            print(result.stderr[-12000:])
            raise subprocess.CalledProcessError(result.returncode, command, output=result.stdout, stderr=result.stderr)
        phase = "validate-native-proof"
        report = validate_native_report(json.loads(result.stdout))
        attempt.succeed(report)
    except BaseException as error:
        attempt.fail(error, phase=phase)
        code = getattr(error, "returncode", 1)
        raise SystemExit(code if isinstance(code, int) and 1 <= code <= 255 else 1) from error


if __name__ == "__main__":
    main()
