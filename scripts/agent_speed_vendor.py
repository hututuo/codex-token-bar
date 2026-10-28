#!/usr/bin/env python3
"""Developer-only Agent Speed provenance/sync checks. Default mode is offline."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

REPOSITORY = "https://github.com/zoefix/agent-speed"
SCOPES = ("macos/Sources/AgentSpeedCore", "macos/Tests/AgentSpeedCoreTests", "windows/src/AgentSpeed.Core", "spec")
EXCLUDES = ("spec/research/", "spec/prototypes/")
ROOT = Path(__file__).resolve().parents[1]


def allowed(path):
    p = PurePosixPath(path)
    if (p.parts[:3] == ("windows", "src", "AgentSpeed.Core")
            and len(p.parts) > 3 and p.parts[3] in {"bin", "obj"}):
        return False
    return (not p.is_absolute() and ".." not in p.parts and "\\" not in path
            and not path.startswith(EXCLUDES)
            and (path == "LICENSE" or any(path.startswith(scope + "/") for scope in SCOPES)))


def digest(path, base):
    relative = path.relative_to(base)
    if any((base / Path(*relative.parts[:n])).is_symlink() for n in range(1, len(relative.parts) + 1)):
        raise ValueError("Symlink in vendored input: " + relative.as_posix())
    return hashlib.sha256(path.read_bytes()).hexdigest()


def local_hashes(vendor):
    result = {}
    for path in vendor.rglob("*"):
        name = path.relative_to(vendor).as_posix()
        if allowed(name) and (path.is_file() or path.is_symlink()):
            result[name] = digest(path, vendor)
    return dict(sorted(result.items()))


def git(upstream, *arguments):
    return subprocess.check_output(["git", "-C", str(upstream), *arguments], text=True, timeout=30).strip()


def upstream_hashes(upstream):
    if git(upstream, "status", "--porcelain", "--", *SCOPES, "LICENSE"):
        raise ValueError("Upstream scoped working tree must be clean")
    paths = git(upstream, "ls-tree", "-r", "--name-only", "HEAD", "--", *SCOPES, "LICENSE").splitlines()
    return {name: digest(upstream / name, upstream) for name in paths if allowed(name)}


def load_lock(vendor):
    lock = json.loads((vendor / "UPSTREAM.json").read_text(encoding="utf-8"))
    if lock.get("schemaVersion") != 2 or lock.get("repository") != REPOSITORY:
        raise ValueError("Unsupported Agent Speed provenance schema/repository")
    if not re.fullmatch(r"[0-9a-f]{40}", lock.get("commit", "")):
        raise ValueError("Upstream commit must be an exact SHA")
    files = lock.get("files", {})
    patches = lock.get("patches", {})
    additions = lock.get("additions", {})
    if (not files or "LICENSE" not in files or set(patches) - set(files)
            or set(additions) & set(files) or set(additions) & set(patches)):
        raise ValueError("Incomplete upstream file/patch inventory")
    for path, sha in files.items():
        if not allowed(path) or not re.fullmatch(r"[0-9a-f]{64}", sha):
            raise ValueError("Invalid upstream file entry")
    for path, patch in patches.items():
        if (not allowed(path) or not isinstance(patch, dict)
                or not isinstance(patch.get("reason"), str) or not patch["reason"].strip()
                or not re.fullmatch(r"[0-9a-f]{64}", patch.get("sha256", ""))):
            raise ValueError("Every local patch needs a reason and SHA-256")
    for path, addition in additions.items():
        if not allowed(path) or not isinstance(addition, dict):
            raise ValueError("Invalid local addition entry")
        if (not isinstance(addition.get("reason"), str) or not addition["reason"].strip()
                or not re.fullmatch(r"[0-9a-f]{64}", addition.get("sha256", ""))):
            raise ValueError("Every local addition needs a reason and SHA-256")
    for scope in SCOPES:
        if not any(path.startswith(scope + "/") for path in files):
            raise ValueError("Missing upstream scope: " + scope)
    return lock


def changes(expected, actual):
    return {"added": sorted(set(actual) - set(expected)),
            "removed": sorted(set(expected) - set(actual)),
            "modified": sorted(p for p in expected.keys() & actual.keys() if expected[p] != actual[p])}


def offline_check(vendor, lock):
    expected = dict(lock["files"])
    for path, patch in lock["patches"].items():
        expected[path] = patch["sha256"]
    for path, addition in lock["additions"].items():
        expected[path] = addition["sha256"]
    result = changes(expected, local_hashes(vendor))
    if any(result.values()):
        raise ValueError("Unrecorded vendor drift: " + json.dumps(result))
    if lock["commit"] not in (vendor / "VENDOR.md").read_text(encoding="utf-8"):
        raise ValueError("VENDOR.md and UPSTREAM.json commit disagree")
    if "Permission is hereby granted" not in (vendor / "LICENSE").read_text(encoding="utf-8"):
        raise ValueError("Expected preserved MIT license")
    return result


def remote_head():
    # Public GitHub metadata only; never called by the product or default check.
    environment = dict(os.environ, GIT_TERMINAL_PROMPT="0")
    output = subprocess.check_output(["git", "ls-remote", REPOSITORY + ".git", "HEAD"], text=True,
                                     timeout=30, env=environment)
    if not re.fullmatch(r"[0-9a-f]{40}\s+HEAD\s*", output):
        raise ValueError("Cannot validate upstream HEAD")
    return output.split()[0]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("check", "compare", "record"))
    parser.add_argument("--vendor", type=Path, default=ROOT / "Vendor/AgentSpeed")
    parser.add_argument("--upstream", type=Path, help="clean local Agent Speed checkout; no fetch/checkout is performed")
    parser.add_argument("--remote", action="store_true", help="explicitly check public GitHub HEAD (release preflight)")
    parser.add_argument("--commit", help="exact reviewed SHA, required to record")
    parser.add_argument("--patch-reasons", type=Path, help="JSON map of every permitted divergent path to its reason")
    parser.add_argument("--addition-reasons", type=Path, help="JSON map of every reviewed local-only added path to its reason")
    parser.add_argument("--reviewed", action="store_true", help="explicit acknowledgement after local patches and tests are reviewed")
    args = parser.parse_args(argv)
    vendor = args.vendor.resolve()
    try:
        if args.action == "record":
            if not args.upstream or not args.patch_reasons or not args.addition_reasons or not args.reviewed or not re.fullmatch(r"[0-9a-f]{40}", args.commit or ""):
                raise ValueError("record requires --upstream --commit --patch-reasons --addition-reasons --reviewed")
            upstream = args.upstream.resolve()
            if git(upstream, "rev-parse", "HEAD") != args.commit:
                raise ValueError("Reviewed SHA does not match upstream checkout")
            files, actual = upstream_hashes(upstream), local_hashes(vendor)
            delta = changes(files, actual)
            if delta["removed"]:
                raise ValueError("Synchronize removed scoped files before recording: " + json.dumps(delta))
            reasons = json.loads(args.patch_reasons.read_text(encoding="utf-8"))
            if (not isinstance(reasons, dict) or set(reasons) != set(delta["modified"])
                    or any(not isinstance(r, str) or not r.strip() for r in reasons.values())):
                raise ValueError("Patch reasons must match every and only divergent file")
            addition_reasons = json.loads(args.addition_reasons.read_text(encoding="utf-8"))
            if (not isinstance(addition_reasons, dict) or set(addition_reasons) != set(delta["added"])
                    or any(not isinstance(r, str) or not r.strip() for r in addition_reasons.values())):
                raise ValueError("Addition reasons must match every and only local added file")
            lock = {"schemaVersion": 2, "repository": REPOSITORY, "commit": args.commit,
                    "scopes": list(SCOPES), "excludes": list(EXCLUDES), "files": files,
                    "patches": {p: {"sha256": actual[p], "reason": reasons[p]} for p in sorted(reasons)},
                    "additions": {p: {"sha256": actual[p], "reason": addition_reasons[p]}
                                  for p in sorted(addition_reasons)}}
            # Validate all invariants before overwriting the small provenance file.
            if args.commit not in (vendor / "VENDOR.md").read_text(encoding="utf-8") or "Permission is hereby granted" not in (vendor / "LICENSE").read_text(encoding="utf-8"):
                raise ValueError("Update VENDOR.md and preserve the license first")
            (vendor / "UPSTREAM.json").write_text(json.dumps(lock, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            load_lock(vendor)
        else:
            lock = load_lock(vendor)
            offline_check(vendor, lock)
            if args.upstream:
                upstream = args.upstream.resolve()
                head = git(upstream, "rev-parse", "HEAD")
                result = changes(lock["files"], upstream_hashes(upstream))
                print(json.dumps({"pinned": lock["commit"], "candidate": head, "changes": result}, indent=2))
                if args.action == "check" and (head != lock["commit"] or any(result.values())):
                    raise ValueError("Candidate differs; follow docs/maintenance/agent-speed-upstream-sync.md")
            elif args.action == "compare":
                raise ValueError("compare requires a clean --upstream checkout")
            if args.remote:
                head = remote_head()
                if head != lock["commit"]:
                    raise ValueError("Agent Speed changed to " + head + "; review and synchronize before release (see sync guide)")
        print("Agent Speed vendor check passed")
        return 0
    except (ValueError, OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
