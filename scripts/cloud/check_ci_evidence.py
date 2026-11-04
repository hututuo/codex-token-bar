#!/usr/bin/env python3
"""Seal only a complete standard CI run; retain unsuccessful job decisions."""
import argparse
import json
from pathlib import Path
import re


def validate_jobs(needs, source_sha, formed_requested=False, scale_requested=False):
    if not re.fullmatch(r"[0-9a-f]{40}", source_sha):
        raise ValueError("Exact source SHA is required")
    if not isinstance(needs, dict):
        raise ValueError("Missing CI job outcomes")
    expected = dict.fromkeys(("source", "frontend", "swift", "native", "windows-updater"), "success")
    expected.update({"formed-upgrade": "success" if formed_requested else "skipped",
                     "scale": "success" if scale_requested else "skipped"})
    for name, outcome in expected.items():
        if not isinstance(needs.get(name), dict) or needs[name].get("result") != outcome:
            raise ValueError(f"CI job {name} must be {outcome}")
    if needs["source"].get("outputs", {}).get("sha") != source_sha:
        raise ValueError("Resolved CI source does not match the evidence source")
    return expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--needs", required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--formed-requested", choices=("true", "false"), default="false")
    parser.add_argument("--scale-requested", choices=("true", "false"), default="false")
    parser.add_argument("--output", type=Path, default=Path("checked-source.json"))
    args = parser.parse_args()
    decision_path = args.output.with_name("ci-execution.json")
    if any(p.exists() or p.is_symlink() for p in (args.output, decision_path)):
        raise SystemExit("Refusing to overwrite CI evidence")
    decision = {"status": "FAIL", "sourceSha": args.source_sha, "runId": args.run_id,
                "scope": "standard CI job outcomes; optional matrices are listed separately"}
    try:
        if not re.fullmatch(r"[1-9][0-9]*", args.run_id):
            raise ValueError("Invalid CI run ID")
        needs = json.loads(args.needs)
        decision["jobs"] = needs
        decision["expectedOutcomes"] = validate_jobs(needs, args.source_sha,
            args.formed_requested == "true", args.scale_requested == "true")
        decision["status"] = "PASS"
    except ValueError as error:
        decision["error"] = str(error)
    decision_path.write_text(json.dumps(decision, indent=2) + "\n", encoding="utf-8")
    if decision["status"] != "PASS":
        raise SystemExit(decision["error"])
    # Keep the existing signing consumer's exact contract. Extended job evidence
    # is separate and never turns a selected/partial run into a full CI seal.
    args.output.write_text(json.dumps({"source_sha": args.source_sha,
        "run_id": args.run_id, "passed": True}) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
