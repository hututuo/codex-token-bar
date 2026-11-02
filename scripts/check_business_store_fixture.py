#!/usr/bin/env python3
"""Run the real native database routes with isolated synthetic data on both OSes.

This is not a replacement for cargo test: cfg(test) changes connection ownership
in the legacy code, so the feature-gated example is a required separate gate.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile


def main() -> None:
    repository = Path(__file__).resolve().parents[1]
    source_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository, text=True).strip()
    working_tree_dirty = bool(subprocess.check_output(
        ["git", "status", "--porcelain", "--untracked-files=no"], cwd=repository, text=True).strip())
    report_path = repository / "native-production-readers.json"
    # A failed or interrupted re-run must never leave the preceding PASS file
    # looking like evidence for this invocation or for different source bytes.
    report_path.write_text(json.dumps({"status": "FAIL", "source_sha": source_sha,
        "working_tree_dirty": working_tree_dirty, "cfg_test": False,
        "error": "This invocation has not produced a completed, validated production-path proof."}, indent=2) + "\n",
        encoding="utf-8")
    home = Path.home().resolve()
    base = Path(os.environ.get("RUNNER_TEMP", tempfile.gettempdir())).resolve()
    if base == home or base.is_relative_to(home):
        if os.name == "nt":
            raise SystemExit("An external RUNNER_TEMP is required; refusing the user's home")
        base = Path("/tmp").resolve()
    with tempfile.TemporaryDirectory(prefix="tokenbar-production-readers-", dir=base) as temp:
        root = Path(temp).resolve()
        env = os.environ.copy()
        for key, slug in zip((
            "CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR", "CODEX_TOKEN_BAR_TAURI_CACHE_DIR",
            "CODEX_TOKEN_BAR_SUPPORT_BASE_DIR", "CODEX_TOKEN_BAR_CACHE_BASE_DIR",
            "CODEX_TOKEN_BAR_TAURI_USAGE_CACHE_DIR",
        ), ("s", "c", "ss", "sc", "uc"), strict=True):
            path = root / slug
            path.mkdir()
            env[key] = str(path)
        result = subprocess.run([
            "cargo", "run", "--locked", "--manifest-path", "tauri-app/src-tauri/Cargo.toml",
            "--features", "business-store-fixture", "--example", "business-store-fixture",
            "--", str(root),
        ], cwd=repository, env=env, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=900)
        (repository / "native-production-readers.log").write_text(
            result.stderr + "\nSTDOUT:\n" + result.stdout, encoding="utf-8")
        print(result.stdout, end="")
        if result.returncode:
            print(result.stderr[-12000:])
            raise SystemExit(result.returncode)
        report = json.loads(result.stdout)
        required = {"bootstrap", "quota", "modeltrace", "body-speed", "ledger-b",
                    "exact-import-stage-and-home-scope", "live-external-state-readers",
                    "legacy-source-preservation", "rerun-and-fail-closed", "bounded-stage-replacement",
                    "public-read-only-routing", "runtime-recovery-production-path",
                    "legacy-backfill-indexed-reconciliation"}
        scenarios = report.get("checks") if isinstance(report, dict) else None
        if (not isinstance(scenarios, list) or len(scenarios) != len(required)
                or any(not isinstance(item, dict) or not isinstance(item.get("name"), str)
                       for item in scenarios)):
            raise SystemExit("Incomplete production-path evidence")
        checks = {item["name"]: item for item in scenarios}
        # Validate the original list before allowing a name-indexed lookup to
        # collapse two results: a later PASS must not hide an earlier failure.
        if (report.get("status") != "PASS" or len(checks) != len(scenarios)
                or set(checks) != required):
            raise SystemExit("Incomplete production-path evidence")
        if any(item.get("status") != "PASS" for item in checks.values()):
            raise SystemExit("Failed production-path scenario")
        if report.get("concurrentWriterProbeEnabled") is not True or report.get("concurrentWriteAssertions", 0) <= 0:
            raise SystemExit("Default production fixture lost its concurrent A-writer assertion")
        if any(checks["bootstrap"].get(field) is not True for field in (
            "incompleteExactDiscoveryFrozen", "incompleteExactSnapshotUnchanged",
            "independentPendingImportRecovered", "completeDiscoveryResumesExactHistory",
            "recoveryRetryPreservesHistory",
        )):
            raise SystemExit("Incomplete Exact discovery did not preserve its pending recovery boundary")
        if checks["quota"].get("retainedReaderRows") != 3 or checks["quota"].get("uniqueRetainedRows") != 2 or not checks["quota"].get("oldCycleSchema"):
            raise SystemExit("Retained quota history was not verified")
        if any(checks["runtime-recovery-production-path"].get(field) is not True for field in (
            "startupNamespaceOnlyIdentity", "startupLastGoodRestored", "startupConcurrentPublisherRead",
            "startupLegacySourceUnchanged", "startupLegacyNotImported", "startupSqliteWriteRefused",
        )):
            raise SystemExit("Read-only startup recovery was not verified through production routes")
        if any(checks["runtime-recovery-production-path"].get(field) is not True for field in (
            "retainedStageContentVerified", "changedStageImportRejected",
            "stageMutationBeforePublicationRejected",
            "sealedStageMissingSealRejected", "resealedStageImportRejected",
            "stageSchemaMutationRejected", "stageSchemaMutationBeforePublicationRejected",
            "unsealedStageRebuiltFromSource", "pendingHistoryOverwriteRejected",
        )):
            raise SystemExit("Retained stage content, schema, seal ownership and safe rebuild were not verified")
        report["source_sha"] = source_sha
        report["working_tree_dirty"] = working_tree_dirty
        report["cfg_test"] = False
        report_path.write_text(
            json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
