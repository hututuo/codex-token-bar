#!/usr/bin/env python3
"""Run the production fixture with precreated overrides and retained failures."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_business_store_fixture import validate_native_report
from native_fixture_evidence import FixtureAttempt, execute_native, fixture_temporary_base, native_path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--output", type=Path, default=Path("runtime-recovery-production.json"))
    args = parser.parse_args()
    repository = Path(__file__).resolve().parents[2]
    attempt = FixtureAttempt(args.output, label="runtime")
    phase = "source-identity"
    try:
        if os.environ.get("GITHUB_ACTIONS") != "true":
            raise ValueError("This launcher requires a hosted Actions disposable workspace.")
        source_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository, text=True).strip()
        changes = subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=no"],
                                          cwd=repository, text=True).splitlines()
        attempt.update(source_sha=source_sha, working_tree_dirty=bool(changes), source_changes=changes)
        phase = "prepare-root"
        env = attempt.create_root(fixture_temporary_base(), prefix="tokenbar-runtime-",
            slugs=("tauri-support", "tauri-cache", "shared-support", "shared-cache", "legacy-usage"))
        binary = args.binary.resolve()
        if os.name == "nt":
            binary = binary.with_suffix(".exe")
        phase = "native-execution"
        attempt.update(phase=phase)
        command = [str(binary), native_path(attempt.root)]
        completed = execute_native(command, cwd=repository, env=env, timeout=900, log_directory=attempt.directory)
        attempt.logs(completed.stdout, completed.stderr)
        if completed.stderr:
            print(completed.stderr, end="")
        print(completed.stdout, end="")
        if completed.returncode:
            raise subprocess.CalledProcessError(completed.returncode, command,
                output=completed.stdout, stderr=completed.stderr)
        phase = "validate-native-proof"
        result = validate_native_report(json.loads(completed.stdout))
        attempt.succeed(result)
    except BaseException as error:
        attempt.fail(error, phase=phase)
        code = getattr(error, "returncode", 1)
        raise SystemExit(code if isinstance(code, int) and 1 <= code <= 255 else 1) from error


if __name__ == "__main__":
    main()
