#!/usr/bin/env python3
"""Build/run an identical real-production Rust aggregate fixture on hosted CI.

Example (separate clean checkouts, normal project macOS native prerequisites):
  python3 harness/scripts/cloud/run_multi_client_aggregate_benchmark.py \
    --baseline baseline --baseline-sha <40-hex> \
    --candidate candidate --candidate-sha <40-hex> --evidence aggregate-evidence

This script deliberately refuses local builds. It changes only the two named
cloud checkouts for test injection, restores their source even on build failure,
and retains evidence/seed databases. It never discovers an application DB.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import sqlite3
import subprocess
import sys
import time

import summarize_multi_client_aggregate_benchmark as validation

SOURCE = Path("tauri-app/src-tauri/src/core/multi_client_usage.rs")
INJECTED = SOURCE.with_name("multi_client_aggregate_benchmark.rs")
SQL = Path("Sources/CodexTokenBar/Resources/client-usage-effective-events.sql")
PRICES = Path("Vendor/AgentSpeed/spec/assets/prices.json")
INJECTION = b'\n#[cfg(test)]\n#[path = "multi_client_aggregate_benchmark.rs"]\nmod cloud_aggregate_benchmark;\n'
SCHEMA = """
CREATE TABLE client_usage_events(client TEXT NOT NULL,event_id TEXT NOT NULL,session_id TEXT NOT NULL,
 model TEXT NOT NULL,timestamp REAL NOT NULL,input_tokens INTEGER NOT NULL,output_tokens INTEGER NOT NULL,
 cache_read_tokens INTEGER,cache_write_tokens INTEGER,reasoning_tokens INTEGER,payload TEXT NOT NULL,
 PRIMARY KEY(client,event_id));
CREATE INDEX client_usage_by_model ON client_usage_events(client,model,timestamp);
CREATE INDEX client_usage_by_time ON client_usage_events(timestamp,client);
CREATE TABLE client_usage_revisions(revision INTEGER PRIMARY KEY AUTOINCREMENT,client TEXT NOT NULL,
 event_id TEXT NOT NULL,captured_at REAL NOT NULL,payload TEXT NOT NULL);
CREATE TABLE client_file_checkpoints(client TEXT NOT NULL,source_key TEXT NOT NULL,offset INTEGER NOT NULL,
 size INTEGER NOT NULL,modified REAL NOT NULL,identity TEXT NOT NULL,PRIMARY KEY(client,source_key));
CREATE TABLE multi_usage_metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
PRAGMA user_version=2;
"""


def require(condition, message):
    validation.require(condition, message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def git(root, *arguments):
    return subprocess.check_output(["git", "-C", str(root), *arguments], text=True).strip()


def save_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def seed_database(path, size):
    """Build one schema2 synthetic input; copy these exact bytes to both roles."""
    require(not path.exists(), "refusing to overwrite seed")
    connection = sqlite3.connect(path)
    try:
        connection.executescript(SCHEMA)
        physical = []
        for row in validation.logical_rows(size):
            index = row["index"]
            copies = 2 if row["client"] in ("claudeCode", "claudeDesktop") else 1
            for copy in range(copies):
                session = f"synthetic-session-{index}-{copy}"
                event = f"synthetic-{index}"
                if copies == 2:
                    event = "v1:" + digest(session.encode()) + ":id:" + digest(f"response-{index}".encode())
                timestamp = row["timestamp"] - (86_400 if copies == 2 and copy == 0 else 0)
                # The maxima are distributed across copies. Filtering either
                # copy before canonical response merging changes the answer.
                input_tokens = row["inputTokens"] - (3 if copies == 2 and copy == 1 else 0)
                output_tokens = row["outputTokens"] - (5 if copies == 2 and copy == 0 else 0)
                payload = {"client": row["client"], "eventID": event, "sessionID": session,
                           "model": row["model"], "timestamp": timestamp * 1_000,
                           "inputTokens": input_tokens, "outputTokens": output_tokens,
                           "quality": "synthetic-cloud-benchmark"}
                for field in validation.COUNTERS[2:]:
                    if row[field] is not None:
                        payload[field] = row[field]
                write = row["cacheWriteTokens"]
                if write is not None and index % 5 != 0:
                    # One coherent pair and, for copied responses, a newer
                    # incoherent pair. Independent MAX(TTL) is incorrect.
                    payload["cacheWrite5mTokens"] = write - 7
                    payload["cacheWrite1hTokens"] = 7 if copy == 0 else 8
                physical.append((row["client"], event, session, row["model"], timestamp,
                                 input_tokens, output_tokens, row["cacheReadTokens"],
                                 write, row["reasoningTokens"], json.dumps(payload, sort_keys=True, separators=(",", ":"))))
        connection.executemany("INSERT INTO client_usage_events VALUES(?,?,?,?,?,?,?,?,?,?,?)", physical)
        connection.executemany("INSERT INTO client_usage_revisions(client,event_id,captured_at,payload) VALUES(?,?,?,?)",
                               [(row[0], row[1], validation.NOW, row[-1]) for row in physical])
        connection.execute("INSERT INTO multi_usage_metadata VALUES('updated_at_ms',?)", (str(validation.NOW * 1_000),))
        connection.execute("INSERT INTO client_file_checkpoints VALUES('deepseek','synthetic-only',1,1,?,'synthetic-v1')", (validation.NOW,))
        connection.commit()
        require(connection.execute("PRAGMA integrity_check").fetchone() == ("ok",), "seed integrity check failed")
    finally:
        connection.close()
    return {"file": path.name, "sha256": validation.sha256(path), "logicalRows": size, "physicalRows": len(physical)}


def logged(root, label, argv, cwd, environment=None):
    started = time.time()
    status = {"argv": list(map(str, argv)), "cwd": str(cwd), "commandExitCode": None, "logExitCode": None,
              "environment": environment or {}, "startedUnix": started}
    try:
        with (root / (label + ".log")).open("w") as log:
            process = subprocess.Popen(argv, cwd=cwd, env={**os.environ, **(environment or {})},
                                       stdout=log, stderr=subprocess.STDOUT, text=True)
            status["commandExitCode"] = process.wait()
            log.flush()
        status["logExitCode"] = 0
    finally:
        status["elapsedSeconds"] = time.time() - started
        save_json(root / (label + ".exit.json"), status)
    require(status["commandExitCode"] == 0, f"{label} failed; see retained log")
    return (root / (label + ".log")).read_text()


def source_provenance(checkout, expected):
    require(re.fullmatch(r"[0-9a-f]{40}", expected) is not None, "exact 40-character source SHA required")
    require(git(checkout, "rev-parse", "HEAD") == expected, "checkout does not match requested SHA")
    require(not git(checkout, "status", "--porcelain", "--untracked-files=all"), "product checkout must be completely clean, including untracked inputs")
    source = (checkout / SOURCE).read_bytes()
    require(b"fn read_cached_multi_client_aggregates(" in source, "real production entry point missing")
    require(b"mod cloud_aggregate_benchmark;" not in source and not (checkout / INJECTED).exists(), "fixture injection already exists")
    return {"sha": expected, "sourceSha256": digest(source), "sqlSha256": validation.sha256(checkout / SQL),
            "pricesSha256": validation.sha256(checkout / PRICES)}


def build(checkout, role, provenance, evidence, fixture):
    # These are normal full product frontend inputs to Tauri's release build,
    # not stub source modules or an extracted aggregate crate.
    logged(evidence, role + "-npm-ci", ["npm", "ci"], checkout / "tauri-app")
    logged(evidence, role + "-frontend", ["npm", "run", "build"], checkout / "tauri-app")
    require(not git(checkout, "status", "--porcelain", "--untracked-files=all"), "frontend preparation changed source inputs")
    original = (checkout / SOURCE).read_bytes()
    fixture_bytes = fixture.read_bytes()
    require(digest(original) == provenance["sourceSha256"], "source changed before injection")
    provenance["fixtureSha256"] = digest(fixture_bytes)
    provenance["injectedSourceSha256"] = digest(original + INJECTION)
    target_dir = evidence / (role + "-target")
    command = ["cargo", "test", "--manifest-path", str(checkout / "tauri-app/src-tauri/Cargo.toml"),
               "--target-dir", str(target_dir), "--lib", "--release", "--locked", "--no-run", "--message-format=json"]
    try:
        (checkout / INJECTED).write_bytes(fixture_bytes)
        (checkout / SOURCE).write_bytes(original + INJECTION)
        text = logged(evidence, role + "-build", command, checkout)
        require((checkout / SOURCE).read_bytes() == original + INJECTION and (checkout / INJECTED).read_bytes() == fixture_bytes,
                "build changed injected inputs")
        allowed = {f" M {SOURCE.as_posix()}", f"?? {INJECTED.as_posix()}"}
        status = subprocess.check_output(["git", "-C", str(checkout), "status", "--porcelain", "--untracked-files=all"], text=True)
        require(set(status.splitlines()) == allowed, "unexpected build-time source inputs")
        artifacts = []
        for line in text.splitlines():
            if not line.startswith("{"):
                continue
            value = json.loads(line)
            if value.get("reason") == "compiler-artifact" and value.get("profile", {}).get("test") is True and value.get("target", {}).get("name") == "codex_token_bar_lib" and value.get("executable"):
                artifacts.append(Path(value["executable"]).resolve())
        require(len(artifacts) == 1 and artifacts[0].is_relative_to(target_dir), "exact real library test executable missing/ambiguous")
        binary = artifacts[0]
        provenance["binarySha256"] = validation.sha256(binary)
        provenance["binary"] = str(binary)
        provenance["binaryArtifact"] = str(binary.relative_to(evidence))
    finally:
        # Never overwrite a concurrent edit on recovery.
        current = (checkout / SOURCE).read_bytes()
        require(current in (original, original + INJECTION), "injected source drifted; refusing unsafe restoration")
        if current != original:
            (checkout / SOURCE).write_bytes(original)
        if (checkout / INJECTED).exists():
            require((checkout / INJECTED).read_bytes() == fixture_bytes, "fixture drifted; preserving it for inspection")
            (checkout / INJECTED).unlink()
        provenance["restoredSourceSha256"] = validation.sha256(checkout / SOURCE)
        provenance["cleanAfter"] = not git(checkout, "status", "--porcelain", "--untracked-files=all")
    require(provenance["cleanAfter"], "product checkout not clean after injection restoration")
    text = logged(evidence, role + "-list", [str(binary), "--list", "--exact", validation.TEST], checkout)
    require(f"{validation.TEST}: test" in text, "test filter would run zero tests")
    return binary


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    for role in ("baseline", "candidate"):
        parser.add_argument("--" + role, type=Path, required=True)
        parser.add_argument("--" + role + "-sha", required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--sizes", type=int, nargs="+", default=[1_200, 12_000])
    parser.add_argument("--trials", type=int, default=3)
    parser.add_argument("--cold-iterations", type=int, default=3)
    parser.add_argument("--hit-iterations", type=int, default=25)
    args = parser.parse_args()
    require(os.environ.get("GITHUB_ACTIONS") == "true" and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted", "native benchmark builds require a GitHub-hosted cloud runner")
    require(sys.platform in ("darwin", "linux"), "current fixture measures Unix getrusage only")
    require(args.trials >= 2 and len(set(args.sizes)) == len(args.sizes) and all(size >= 24 for size in args.sizes), "invalid workload/trials")
    require(0 < args.cold_iterations <= 1_000 and 0 < args.hit_iterations <= 1_000, "invalid iteration count")
    checkouts = {role: getattr(args, role).resolve() for role in ("baseline", "candidate")}
    evidence = args.evidence.resolve()
    require(checkouts["baseline"] != checkouts["candidate"], "separate product checkouts required")
    require(not any(evidence.is_relative_to(path) or path.is_relative_to(evidence) for path in checkouts.values()), "evidence must be outside product checkouts")
    evidence.mkdir(parents=True, exist_ok=False)
    fixture = Path(__file__).with_name("fixtures") / "MultiClientAggregateBenchmark.rs"
    manifest = {"schemaVersion": 1, "status": "RUNNING", "singleHostedRunner": True, "freshProcessPerCase": True,
                "fixtureSha256": validation.sha256(fixture), "nowUnix": validation.NOW, "timezone": "UTC",
                "sizes": args.sizes, "trials": args.trials, "iterations": {"cold": args.cold_iterations, "cache-hit": args.hit_iterations},
                "witnessExpectations": {"baseline": "canonical", "candidate": "staged"},
                "sources": {}, "seeds": {}, "executionOrder": [], "runner": {"platform": platform.platform(),
                    "runnerName": os.environ.get("RUNNER_NAME"), "runID": os.environ.get("GITHUB_RUN_ID"),
                    "runAttempt": os.environ.get("GITHUB_RUN_ATTEMPT"), "python": sys.version},
                "harnessInputs": {path.name: validation.sha256(path) for path in (Path(__file__), Path(validation.__file__), fixture)}}
    save_json(evidence / "manifest.json", manifest)
    try:
        for role, checkout in checkouts.items():
            manifest["sources"][role] = source_provenance(checkout, getattr(args, role + "_sha"))
        for field in ("sqlSha256", "pricesSha256"):
            require(manifest["sources"]["baseline"][field] == manifest["sources"]["candidate"][field], f"pair must use identical {field}")
        for size in args.sizes:
            manifest["seeds"][str(size)] = seed_database(evidence / f"synthetic-schema2-{size}.sqlite", size)
        for tool in ("rustc", "cargo", "node", "npm"):
            logged(evidence, "toolchain-" + tool, [tool, "--version"], evidence)
        binaries = {role: build(checkout, role, manifest["sources"][role], evidence, fixture) for role, checkout in checkouts.items()}
        for size in args.sizes:
            seed = manifest["seeds"][str(size)]
            for phase in validation.PHASES:
                for trial in range(1, args.trials + 1):
                    roles = ("baseline", "candidate") if trial % 2 else ("candidate", "baseline")
                    for role in roles:
                        label = f"{role}-{size}-{phase}-{trial}"
                        require(validation.sha256(binaries[role]) == manifest["sources"][role]["binarySha256"], "binary drift before execution")
                        database = evidence / (label + ".sqlite")
                        shutil.copyfile(evidence / seed["file"], database)
                        require(validation.sha256(database) == seed["sha256"], "paired input copy drift")
                        environment = {"TZ": "UTC", "CTB_AGGREGATE_SYNTHETIC": "schema2-v1", "CTB_AGGREGATE_DATABASE": str(database),
                                       "CTB_AGGREGATE_DATABASE_SHA256": seed["sha256"], "CTB_AGGREGATE_SOURCE": manifest["sources"][role]["sha"],
                                       "CTB_AGGREGATE_PHASE": phase, "CTB_AGGREGATE_TRIAL": str(trial), "CTB_AGGREGATE_LOGICAL_ROWS": str(size),
                                       "CTB_AGGREGATE_PHYSICAL_ROWS": str(seed["physicalRows"]), "CTB_AGGREGATE_NOW": str(validation.NOW),
                                       "CTB_AGGREGATE_ITERATIONS": str(manifest["iterations"][phase])}
                        logged(evidence, label, [str(binaries[role]), "--exact", validation.TEST, "--nocapture", "--test-threads=1"], checkouts[role], environment)
                        manifest["executionOrder"].append(label)
                        save_json(evidence / "manifest.json", manifest)
        for role, checkout in checkouts.items():
            require(not git(checkout, "status", "--porcelain", "--untracked-files=all"), "source changed during benchmark")
            require(validation.sha256(checkout / SOURCE) == manifest["sources"][role]["sourceSha256"], "production source drift")
        manifest["status"] = "COMPLETE"
        save_json(evidence / "manifest.json", manifest)
        result = validation.validate_and_summarize(evidence, fixture)
        save_json(evidence / "summary.json", result)
        print(json.dumps(result, indent=2))
        return 0
    except Exception as error:
        manifest["status"] = "FAILED"
        manifest["error"] = str(error)
        save_json(evidence / "manifest.json", manifest)
        raise


if __name__ == "__main__":
    raise SystemExit(main())
