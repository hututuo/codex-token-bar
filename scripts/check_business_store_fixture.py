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
        checks = {item["name"]: item for item in report["checks"]}
        required = {"bootstrap", "quota", "modeltrace", "body-speed", "ledger-b",
                    "exact-import-stage-and-home-scope", "live-external-state-readers",
                    "legacy-source-preservation", "rerun-and-fail-closed", "bounded-stage-replacement"}
        if report.get("status") != "PASS" or set(checks) != required:
            raise SystemExit("Incomplete production-path evidence")
        if any(item.get("status") != "PASS" for item in checks.values()):
            raise SystemExit("Failed production-path scenario")
        if checks["quota"].get("retainedReaderRows") != 2 or not checks["quota"].get("oldCycleSchema"):
            raise SystemExit("Retained quota history was not verified")
        report["source_sha"] = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=repository, text=True).strip()
        report["cfg_test"] = False
        (repository / "native-production-readers.json").write_text(
            json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
