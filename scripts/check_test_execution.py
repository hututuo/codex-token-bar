#!/usr/bin/env python3
"""Run a test command and reject empty, failed, or missing required test execution.

Exit zero alone is not test evidence: Rust and XCTest can succeed with an empty
filter. Skips remain visible; a required test must have an actual passed record.
This is execution evidence, not a claim about coverage or production acceptance.
"""
import argparse
import fnmatch
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys


def validate_execution(text, kind, required=()):
    # The runner hashes raw log bytes, including Windows text-mode CRLF.
    # Normalize only paired line endings for parsing; keep lone CR and all
    # record/count/required-test checks intact.
    text = text.replace("\r\n", "\n")
    if kind == "rust":
        summaries = re.findall(r"^test result: (ok|FAILED)\. (\d+) passed; (\d+) failed; (\d+) ignored;.*$", text, re.M)
        if len(summaries) != 1:
            raise ValueError("Expected one complete Rust library test summary")
        status, passed, failed, skipped = summaries[0]
        passed, failed, skipped = map(int, (passed, failed, skipped))
        matches = re.findall(r"^test (\S+) \.\.\. (ok|FAILED|ignored)(?:,.*)?$", text, re.M)
        observed = {name: outcome for name, outcome in matches}
        if (len(observed) != len(matches)
                or sum(v == "ok" for v in observed.values()) != passed
                or sum(v == "ignored" for v in observed.values()) != skipped):
            raise ValueError("Rust execution records do not match the summary")
        successful = {name for name, outcome in matches if outcome == "ok"}
        failed = failed or status != "ok" or any(v == "FAILED" for v in observed.values())
    elif kind == "swift":
        summary_pattern = r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?"
        completions = list(re.finditer(
            r"^Test Suite '([^']+)' (passed|failed) at [^\n]*\n\s*" + summary_pattern, text, re.M))
        if not completions:
            raise ValueError("Missing completed XCTest suite")
        if (any(item[2] != "passed" or int(item[5]) for item in completions)
                or any(int(item[2]) for item in re.findall(summary_pattern, text))):
            raise ValueError("XCTest reported a failed suite")
        suite_starts = list(re.finditer(r"^Test Suite '([^']+)' started at [^\n]*", text, re.M))
        unfinished = {}
        for position, name, starting in sorted(
                [(item.start(), item[1], True) for item in suite_starts]
                + [(item.start(), item[1], False) for item in completions]):
            if starting:
                if name in unfinished:
                    raise ValueError(f"Duplicate XCTest suite start: {name}")
                unfinished[name] = position
            else:
                unfinished.pop(name, None)
        if unfinished:
            raise ValueError("Missing XCTest suite completion: " + ", ".join(unfinished))
        # SwiftPM runs each XCTest bundle separately. The final bundle can be
        # empty, and class/bundle/top-level summaries repeat the same counts.
        bundles = [item for item in completions if item[1].endswith(".xctest")]
        starts = [item for item in suite_starts if item[1].endswith(".xctest")]
        if bundles or starts:
            names = [item[1] for item in bundles]
            if (len(set(names)) != len(names) or [item[1] for item in starts] != names
                    or any(start.end() > end.start() for start, end in zip(starts, bundles))):
                raise ValueError("Missing or duplicate XCTest bundle completion")
            summaries = bundles
        else:
            summaries = [item for item in completions if item[1] in ("All tests", "Selected tests")]
            if not summaries:
                raise ValueError("Missing completed XCTest bundle or top-level suite")
        total = sum(int(item[3]) for item in summaries)
        skipped = sum(int(item[4] or 0) for item in summaries)
        passed = total - skipped
        # stdout from a test can join XCTest's stderr on the same physical line.
        # Retain the complete XCTest record even when its line has that prefix.
        case_pattern = r"Test Case '([^'\r\n]+)' (passed|failed|skipped)(?:\s|$)"
        matches = re.findall(case_pattern, text)
        observed = {name: outcome for name, outcome in matches}
        if (len(observed) != len(matches) or len(matches) != total
                or sum(v == "passed" for v in observed.values()) != passed
                or sum(v == "skipped" for v in observed.values()) != skipped):
            raise ValueError("XCTest execution records do not match the bundle summaries")
        case_starts = list(re.finditer(r"Test Case '([^'\r\n]+)' started(?:\.|\s|$)", text))
        case_ends = {item[1]: item.start() for item in re.finditer(case_pattern, text)}
        if (len({item[1] for item in case_starts}) != len(case_starts)
                or any(item[1] not in case_ends or item.start() >= case_ends[item[1]] for item in case_starts)):
            raise ValueError("Missing or duplicate XCTest case completion")
        if bundles:
            for start, end in zip(starts, bundles):
                records = re.findall(case_pattern, text[start.end():end.start()])
                if (len(records) != int(end[3])
                        or sum(outcome == "skipped" for _, outcome in records) != int(end[4] or 0)):
                    raise ValueError(f"XCTest bundle records do not match its summary: {end[1]}")
        successful = {name for name, outcome in matches if outcome == "passed"}
        failed = any(v == "failed" for v in observed.values())
    else:
        raise ValueError(f"Unsupported test report: {kind}")
    if failed or passed <= 0:
        raise ValueError("No tests passed, or test failures were reported")
    for name in required:
        # Token boundaries avoid matching a different test with a longer name.
        pattern = re.compile(r"(?:^|[.: /])" + re.escape(name) + r"(?:$|[\] /])")
        if not any(pattern.search(actual) for actual in successful):
            raise ValueError(f"Required test did not pass: {name}")
    return {"passed": passed, "skippedOrIgnored": skipped, "requiredTests": list(required)}


def source_identity(allowed_outputs=(), evidence_outputs=()):
    root = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
    evidence_names = set()
    for path in evidence_outputs:
        try:
            evidence_names.add(path.resolve().relative_to(root.resolve()).as_posix())
        except ValueError:
            pass  # Evidence outside this checkout cannot be a build input here.
    untracked = subprocess.check_output([
        "git", "-C", str(root), "ls-files", "--others", "--exclude-standard", "--full-name", "-z"
    ]).decode("utf-8", errors="surrogateescape").split("\0")
    def allowed(name):
        if name in evidence_names:
            return True
        parts = PurePosixPath(name).parts
        return any(len(parts) == len(PurePosixPath(pattern).parts)
                   and all(fnmatch.fnmatchcase(part, glob) for part, glob in zip(parts, PurePosixPath(pattern).parts))
                   for pattern in allowed_outputs)
    untracked = sorted(name for name in untracked if name)
    diff = subprocess.check_output(["git", "-C", str(root), "diff", "--binary", "HEAD", "--"])
    return {
        "head": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
        "trackedDirty": bool(diff),
        "trackedDiffSha256": hashlib.sha256(diff).hexdigest(),
        "workingTreeDirty": bool(subprocess.check_output(["git", "-C", str(root), "status", "--porcelain"], text=True).strip()),
        "untrackedInputs": [name for name in untracked if not allowed(name)],
        "allowedUntrackedOutputs": [name for name in untracked if allowed(name)],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kind", choices=("rust", "swift"), required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--source-sha")
    parser.add_argument("--allow-untracked-output", action="append", default=[],
                        help="Explicit repository-relative output path or single-level glob (recorded in evidence)")
    parser.add_argument("--require", action="append", default=[])
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("A test command is required after --")
    for pattern in args.allow_untracked_output:
        path = PurePosixPath(pattern)
        if not path.parts or path.is_absolute() or ".." in path.parts or "**" in pattern or "\\" in pattern:
            parser.error("Output exceptions must be repository-relative paths without .., ** or backslashes")
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="backslashreplace")
    evidence_path = args.log.with_suffix(".execution.json")
    for path in (args.log, evidence_path):
        if path.exists() or path.is_symlink():
            raise SystemExit(f"Refusing to overwrite test evidence: {path}")
    before = source_identity(args.allow_untracked_output, (args.log, evidence_path))
    decision = {"status": "FAIL", "sourceSha": before["head"], "workingTreeDirty": before["workingTreeDirty"],
                "sourceBefore": before,
                "kind": args.kind, "command": command, "allowedUntrackedOutputs": args.allow_untracked_output}
    exit_code = 1
    try:
        if args.source_sha is not None:
            if not re.fullmatch(r"[0-9a-f]{40}", args.source_sha) or before["head"] != args.source_sha:
                raise ValueError("Test checkout does not match the requested source SHA")
            if before["trackedDirty"]:
                raise ValueError("Tracked source differs from the requested source SHA")
            if before["untrackedInputs"]:
                raise ValueError("Untracked inputs are outside the requested source SHA: " + ", ".join(before["untrackedInputs"]))
        with args.log.open("x", encoding="utf-8") as log:
            child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     text=True, encoding="utf-8", errors="replace")
            for line in child.stdout:
                log.write(line)
                print(line, end="", flush=True)
            exit_code = child.wait()
        decision["commandExitCode"] = exit_code
        content = args.log.read_bytes()
        decision["logSha256"] = hashlib.sha256(content).hexdigest()
        after = source_identity(args.allow_untracked_output, (args.log, evidence_path))
        decision["sourceAfter"] = after
        if any(before[key] != after[key] for key in ("head", "trackedDiffSha256")):
            raise ValueError("Tracked source changed during test execution")
        if args.source_sha is not None and after["untrackedInputs"]:
            raise ValueError("Untracked inputs appeared during test execution: " + ", ".join(after["untrackedInputs"]))
        if exit_code:
            raise ValueError(f"Test command exited {exit_code}")
        decision.update(validate_execution(content.decode("utf-8"), args.kind, args.require))
        decision["status"] = "PASS"
    except (OSError, ValueError) as error:
        decision["error"] = str(error)
    evidence_path.write_text(json.dumps(decision, indent=2) + "\n", encoding="utf-8")
    if decision["status"] != "PASS":
        raise SystemExit(exit_code or decision["error"])


if __name__ == "__main__":
    main()
