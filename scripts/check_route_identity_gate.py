#!/usr/bin/env python3
"""Cloud-only production identity control: valid A replacement, mutation, restore.

The fixture runs in a new process and isolated temporary root per attempt.
Original/replacement database images and logs are retained, never user data.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

NAMES = {"generic-writer", "generic-reader", "exact-writer", "exact-reader",
         "stage-admission", "published-read-admission"}
FAILURE = "route identity fence accepted replaced A:"
OVERRIDES = {
    "CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR": "tauri-support",
    "CODEX_TOKEN_BAR_TAURI_CACHE_DIR": "tauri-cache",
    "CODEX_TOKEN_BAR_SUPPORT_BASE_DIR": "shared-support",
    "CODEX_TOKEN_BAR_CACHE_BASE_DIR": "shared-cache",
    "CODEX_TOKEN_BAR_TAURI_USAGE_CACHE_DIR": "legacy-usage",
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def validate_fixture(report, code, disabled=False):
    if disabled:
        if code != 1 or report.get("status") != "FAIL" or not report.get("error", "").startswith(FAILURE):
            raise ValueError("Disabled identity check did not fail for accepting a valid replaced A")
        return
    if code != 0 or report.get("status") != "PASS" or report.get("cfgTest") is not False:
        raise ValueError("Production identity fixture did not pass")
    for key in ("replacementCatalogValid", "replacementBytesIdentical", "markerUnchanged",
                "originalAndReplacementPreserved"):
        if report.get(key) is not True:
            raise ValueError(f"Missing identity control proof: {key}")
    if report.get("restoredReads") != [123, 175]:
        raise ValueError("Restored canary reads differ")
    checks = report.get("checks", [])
    if len(checks) != len(NAMES) or {item.get("name") for item in checks} != NAMES:
        raise ValueError("Missing or duplicate identity entrypoint checks")
    if any(item.get("rejected") is not True or "容器文件" not in item.get("error", "") for item in checks):
        raise ValueError("An entrypoint did not reject the changed physical owner")


def main():
    if os.environ.get("GITHUB_ACTIONS") != "true" or not os.environ.get("RUNNER_TEMP"):
        raise SystemExit("Run route identity compilation and probes in the project cloud workflow")
    repo = Path(__file__).resolve().parents[1]
    output = Path(os.environ["RUNNER_TEMP"]) / "route-identity-control"
    output.mkdir(exist_ok=False)
    source = repo / "tauri-app/src-tauri/src/core/business_store_route/admission.rs"
    original = source.read_bytes()
    newline = b"\r\n" if b"\r\n" in original else b"\n"
    start = b"pub(super) fn verify_active_container_identity(path: &Path) -> Result<(), String> {"
    if original.count(start) != 1:
        raise SystemExit("Expected exactly one production physical identity implementation")
    a = original.index(start)
    b = original.index(newline + b"}" + newline, a) + len(newline + b"}")
    disabled = start + newline + b"    let _ = path;" + newline + b"    Ok(())" + newline + b"}"
    mutant = original[:a] + disabled + original[b:]
    if b"let observed = container_file_identity(path)?;" not in original[a:b]:
        raise SystemExit("Identity mutation target no longer checks the physical file")
    subprocess.run(["git", "diff", "--quiet", "HEAD", "--", "tauri-app/src-tauri/src",
                    "tauri-app/src-tauri/Cargo.toml"], cwd=repo, check=True)
    build = ["cargo", "build", "--locked", "--manifest-path", "tauri-app/src-tauri/Cargo.toml",
             "--features", "business-store-fixture", "--example", "route-identity-fixture"]
    binary = repo / "tauri-app/src-tauri/target/debug/examples" / ("route-identity-fixture.exe" if os.name == "nt" else "route-identity-fixture")
    report = {"status": "FAIL", "sourceSha": subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
        "sourceBeforeSHA256": digest(original), "source": str(source.relative_to(repo)),
        "buildCommand": build, "productionDatabaseAccessed": False, "runs": []}

    def run(label, mutation=False):
        build_path = output / f"{label}-build.log"
        with build_path.open("x", encoding="utf-8") as stream:
            result = subprocess.run(build, cwd=repo, stdout=stream, stderr=subprocess.STDOUT, timeout=900)
        if result.returncode != 0:
            raise ValueError(f"{label} production fixture build failed: {result.returncode}")
        base = Path(os.environ["RUNNER_TEMP"]).resolve()
        user_home = Path.home().resolve()
        if base.is_relative_to(user_home) or user_home.is_relative_to(base):
            base = Path(os.environ.get("SystemRoot", "C:/Windows")) / "Temp" if os.name == "nt" else Path("/tmp")
            base = base.resolve()
        if base.is_relative_to(user_home) or user_home.is_relative_to(base):
            raise ValueError("Identity fixture temp base overlaps user home")
        root = Path(tempfile.mkdtemp(prefix=f"tokenbar-identity-{label}-", dir=base)).resolve()
        native = str(root)
        if os.name == "nt" and not native.startswith("\\\\?\\"):
            native = "\\\\?\\" + native
        root = Path(native)
        env = os.environ.copy()
        for key, directory in OVERRIDES.items():
            env[key] = str(root / directory)
        result = subprocess.run([str(binary), str(root)], cwd=repo, env=env,
                                capture_output=True, text=True, encoding="utf-8", timeout=180)
        log_path = output / f"{label}.log"
        log_path.write_text(result.stderr + result.stdout, encoding="utf-8")
        actual = json.loads(result.stdout)
        report["runs"].append({"label": label, "exitCode": result.returncode,
            "buildExitCode": 0, "buildLogSHA256": digest(build_path.read_bytes()),
            "logSHA256": digest(log_path.read_bytes()), "binarySHA256": digest(binary.read_bytes()),
            "fixtureRoot": str(root), "sourceSHA256": digest(source.read_bytes()), "report": actual})
        validate_fixture(actual, result.returncode, mutation)
        print(f"{label}: exit {result.returncode}", flush=True)

    try:
        run("baseline")
        try:
            source.write_bytes(mutant)
            report["mutatedSHA256"] = digest(mutant)
            run("identity-disabled", True)
            report["regressionRejectedDisabledIdentity"] = True
        finally:
            source.write_bytes(original)
            report["sourceRestored"] = source.read_bytes() == original
            if not report["sourceRestored"]:
                raise ValueError("Could not restore the production identity source")
            run("restored")
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
