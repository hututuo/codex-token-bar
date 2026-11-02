#!/usr/bin/env python3
"""Bind the actual native recovery verdict to CI, signing and publication.

The verdict is downloaded from the current CI run by exact artifact name.
This validator does not run native checks or infer them from a source flag.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re

SCHEMA_VERSION = 2
RECOVERY_JOBS = frozenset({
    "source", "harness-contracts", "public-v097", "readers", "formed-release", "swift-formed-release", "rust-backfill-scale", "swift-backfill-scale",
})
FORMED_RELEASES = ["0.9.8", "0.9.9", "0.9.10", "0.9.11"]
SWIFT_SIZES = [13, 128, 512, 4124]
RUST_SIZES = [13, 128, 512, 4124]
SWIFT_ENRICHED_PROOFS = ["nullModelAndTurnCompleted", "originalVersionsRetained",
    "repeatedMetadataGenerationsPreserved", "rawMissingBeforeMigration", "completeImportedNamespacePreserved"]
PUBLIC_RELEASE_SHA = "0219554ce444b0013987da7b82e3c2e891f4afdb"


def validate_identity(source_sha: str, run_id: str) -> None:
    if (not isinstance(source_sha, str) or not re.fullmatch(r"[0-9a-f]{40}", source_sha)
            or not isinstance(run_id, str) or not re.fullmatch(r"[1-9][0-9]*", run_id)):
        raise ValueError("Exact source SHA and positive workflow run ID are required")


def validate_recovery_verdict(value: object, source_sha: str, run_id: str) -> dict:
    validate_identity(source_sha, run_id)
    if (not isinstance(value, dict) or value.get("source_sha") != source_sha
            or value.get("run_id") != run_id or value.get("passed") is not True):
        raise ValueError("Native recovery verdict is not a pass for this source/run")
    jobs = value.get("jobs")
    if (not isinstance(jobs, dict) or set(jobs) != RECOVERY_JOBS
            or any(result != "success" for result in jobs.values())):
        raise ValueError("Every required native recovery job must have succeeded")
    if value.get("public_release") != "0.9.7" or value.get("public_release_sha") != PUBLIC_RELEASE_SHA:
        raise ValueError("Native recovery verdict does not include the pinned public v0.9.7 upgrade")
    if value.get("formed_releases") != FORMED_RELEASES:
        raise ValueError("Native recovery verdict does not cover all required formed releases")
    if (value.get("rust_macos_runner") != "macos-15-intel"
            or value.get("swift_macos_runner") != "macos-26-intel"
            or value.get("macos_recovery_architecture") != "x86_64"):
        raise ValueError("Native recovery verdict must retain the actual macOS runner architecture")
    if (value.get("swift_formed_releases") != FORMED_RELEASES
            or value.get("swift_formed_runtime") != "native-swift-xctest-production-apis"
            or value.get("swift_formed_scenarios") != ["committed", "interrupted", "enriched"]
            or value.get("swift_formed_phases") != ["resume", "reopen"]
            or value.get("swift_formed_enriched_proofs") != SWIFT_ENRICHED_PROOFS):
        raise ValueError("Native recovery verdict does not cover the actual Swift formed-release matrix")
    sizes = value.get("swift_backfill_sizes")
    if sizes != SWIFT_SIZES or any(type(size) is not int for size in sizes):
        raise ValueError("Native recovery verdict does not cover the complete Swift scale matrix")
    sizes = value.get("rust_backfill_sizes")
    if (sizes != RUST_SIZES or any(type(size) is not int for size in sizes)
            or value.get("rust_backfill_profile") != "release"
            or value.get("rust_backfill_runtime") != "non-cfg-test-production-apis-windows-macos"):
        raise ValueError("Native recovery verdict does not cover the optimized production Rust scale matrix")
    # Keep the producer's coverage limits in the sealed packet; a macOS Rust
    # job must not be relabelled as Swift formed-release or installed-app UX.
    for field in ("formed_runtime", "scope"):
        if not isinstance(value.get(field), str) or not value[field].strip():
            raise ValueError("Native recovery verdict is missing its coverage description")
    return value


def make_ci_evidence(verdict: object, source_sha: str, run_id: str) -> dict:
    recovery = validate_recovery_verdict(verdict, source_sha, run_id)
    return {
        "schemaVersion": SCHEMA_VERSION,
        "source_sha": source_sha,
        "run_id": run_id,
        "passed": True,
        "database_recovery_required": True,
        "database_recovery": recovery,
    }


def validate_ci_evidence(value: object, source_sha: str, run_id: str) -> dict:
    validate_identity(source_sha, run_id)
    fields = {"schemaVersion", "source_sha", "run_id", "passed",
              "database_recovery_required", "database_recovery"}
    if (not isinstance(value, dict) or set(value) != fields
            or type(value.get("schemaVersion")) is not int
            or value["schemaVersion"] != SCHEMA_VERSION
            or value.get("source_sha") != source_sha or value.get("run_id") != run_id
            or value.get("passed") is not True
            or value.get("database_recovery_required") is not True):
        raise ValueError("CI evidence must include the required recovery proof for this source/run")
    validate_recovery_verdict(value["database_recovery"], source_sha, run_id)
    return value


def read_evidence(path: pathlib.Path) -> object:
    if path.is_symlink() or not path.is_file():
        raise ValueError("Evidence must be a regular file, not a symlink")
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="mode", required=True)
    for mode in ("seal", "verify"):
        command = commands.add_parser(mode)
        command.add_argument("--source-sha", required=True)
        command.add_argument("--run-id", required=True)
        command.add_argument("--input", type=pathlib.Path, required=True)
        if mode == "seal":
            command.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    value = read_evidence(args.input)
    if args.mode == "seal":
        evidence = make_ci_evidence(value, args.source_sha, args.run_id)
        # A stale artifact from a previous invocation must not be overwritten.
        with args.output.open("x", encoding="utf-8") as stream:
            stream.write(json.dumps(evidence, indent=2) + "\n")
    else:
        validate_ci_evidence(value, args.source_sha, args.run_id)
    print("Verified CI/native recovery evidence:", args.source_sha, args.run_id)


if __name__ == "__main__":
    main()
