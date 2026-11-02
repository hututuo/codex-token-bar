#!/usr/bin/env python3
"""Compile current production migration code and test a disposable late import.

This bounded probe replaces only resource lookup and *unused* Exact-discovery
dependencies. It does not launch the app or inspect any real user database.
The package XCTest and hosted production-path suites remain separate gates.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
PRODUCTION_FILES = [
    "BusinessDatabaseMigration.swift", "PublishedBusinessAdmission.swift", "BusinessStoreFiles.swift",
    "CodexCrossProcessFileLock.swift", "CodexBusinessDatabase.swift",
    "SQLiteDatabaseDriver.swift", "SQLiteStoreConnection.swift", "SQLiteStoreNamespace.swift",
]


def run(output: Path | None = None) -> int:
    sources = [ROOT / "Sources/CodexTokenBar" / name for name in PRODUCTION_FILES]
    sources.append(ROOT / "scripts/fixtures/swift_startup_admission_probe.swift")
    report = {"source_hashes": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                for p in sources}, "gate": "published-ledger-admission"}
    with tempfile.TemporaryDirectory(prefix="tokenbar-admission-") as temporary:
        directory = Path(temporary)
        binary = directory / "admission-probe"
        command = ["swiftc", "-parse-as-library", "-module-name", "StartupAdmissionProbe",
                   *map(str, sources), "-o", str(binary)]
        started = time.monotonic()
        compiled = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=120)
        report["compile_exit"] = compiled.returncode
        report["compile_log"] = compiled.stdout + compiled.stderr
        if compiled.returncode == 0:
            environment = dict(os.environ, TOKENBAR_FIXTURE_REPO=str(ROOT))
            probe = subprocess.run([str(binary), str(directory / "fixture")], cwd=ROOT,
                                   env=environment, text=True, capture_output=True, timeout=120)
            report.update(exit_code=probe.returncode, log=probe.stdout + probe.stderr)
        else:
            report["exit_code"] = compiled.returncode
        report["seconds"] = round(time.monotonic() - started, 3)
        report["status"] = "PASS" if report["exit_code"] == 0 else "FAIL"
    rendered = json.dumps(report, indent=2, ensure_ascii=False) + "\n"
    if output:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(rendered)
    print(rendered, end="")
    return int(report["exit_code"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    raise SystemExit(run(parser.parse_args().output))
