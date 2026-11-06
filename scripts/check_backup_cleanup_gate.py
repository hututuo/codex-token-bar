#!/usr/bin/env python3
"""Cloud-only, real-Rust negative control for the backup cleanup regression.

Run the normal test, temporarily disable cleanup, require that exact test to
fail for a leaked file, then restore bytes and rerun the normal test. Reports
stay outside the source checkout. No production database is opened.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from check_test_execution import validate_execution


TEST = "core::business_store_container::tests::failed_partial_backup_is_never_published"
FAILURE = "temporary backup family leaked after failed build:"
CLEANUP = '''fn cleanup_backup_temporary(path: &Path) {
    let _ = fs::remove_file(path);
    for suffix in ["-journal", "-wal", "-shm"] {
        let mut sidecar = path.as_os_str().to_os_string();
        sidecar.push(suffix);
        let _ = fs::remove_file(PathBuf::from(sidecar));
    }
}
'''
DISABLED = "fn cleanup_backup_temporary(path: &Path) {\n    let _ = path;\n}\n"


def validate_rejection(log, code):
    records = re.findall(r"^test (\S+) \.\.\. (ok|FAILED|ignored)(?:,.*)?$", log, re.M)
    summaries = re.findall(r"^test result: (ok|FAILED)\. (\d+) passed; (\d+) failed; (\d+) ignored;.*$", log, re.M)
    if (code != 101 or records != [(TEST, "FAILED")]
            or summaries != [("FAILED", "0", "1", "0")] or FAILURE not in log):
        raise ValueError("Cleanup control did not fail in the required regression for a leaked temporary file")


def main():
    if os.environ.get("GITHUB_ACTIONS") != "true" or not os.environ.get("RUNNER_TEMP"):
        raise SystemExit("Native builds for this check must run in the project cloud workflow")
    repo = Path(__file__).resolve().parents[1]
    output = Path(os.environ["RUNNER_TEMP"]) / "storage-backup-control"
    output.mkdir(exist_ok=False)
    candidates = [repo / "tauri-app/src-tauri/src/core" / name for name in (
        "business_store_container.rs", "business_store_container/backup.rs")]
    matches = []
    for path in candidates:
        if not path.exists():
            continue
        original = path.read_bytes()
        newline = b"\r\n" if b"\r\n" in original else b"\n"
        needle = CLEANUP.encode().replace(b"\n", newline)
        if needle in original:
            matches.append((path, original, needle, newline))
    if len(matches) != 1:
        raise SystemExit("Expected one exact cleanup implementation; review the mutation before continuing")
    source, original, needle, newline = matches[0]
    if original.count(needle) != 1:
        raise SystemExit("Ambiguous cleanup implementation")
    digest = lambda data: hashlib.sha256(data).hexdigest()
    command = ["cargo", "test", "--locked", "--manifest-path", "tauri-app/src-tauri/Cargo.toml",
               "--lib", TEST, "--", "--exact", "--test-threads=1"]
    report = {"status": "FAIL", "sourceSha": subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
        "source": source.relative_to(repo).as_posix(), "sourceBeforeSHA256": digest(original),
        "command": command, "productionDatabaseAccessed": False, "runs": []}

    def run(label):
        path = output / (label + ".log")
        with path.open("x", encoding="utf-8") as stream:
            result = subprocess.run(command, cwd=repo, stdout=stream, stderr=subprocess.STDOUT, timeout=900)
        data = path.read_bytes()
        text = data.decode("utf-8", errors="replace")
        report["runs"].append({"label": label, "exitCode": result.returncode, "logSHA256": digest(data)})
        print(f"{label}: exit {result.returncode}", flush=True)
        return text, result.returncode

    def require_pass(label):
        text, code = run(label)
        result = validate_execution(text, "rust", [TEST])
        if code != 0 or result["passed"] != 1 or result["skippedOrIgnored"] != 0:
            raise ValueError(f"{label} must execute exactly one passing cleanup regression")

    try:
        require_pass("baseline")
        try:
            mutant = original.replace(needle, DISABLED.encode().replace(b"\n", newline))
            source.write_bytes(mutant)
            report["mutatedSHA256"] = digest(mutant)
            validate_rejection(*run("cleanup-disabled"))
            report["regressionRejectedDisabledCleanup"] = True
        finally:
            source.write_bytes(original)
            report["sourceRestored"] = source.read_bytes() == original
            if not report["sourceRestored"]:
                raise ValueError("Failed to restore original source bytes")
            # Leave a verified original test binary, not the deliberately broken one.
            require_pass("restored")
        report["status"] = "PASS"
    except Exception as error:
        report["error"] = str(error)
    finally:
        report["sourceAfterSHA256"] = digest(source.read_bytes())
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
