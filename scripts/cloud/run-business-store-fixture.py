#!/usr/bin/env python3
"""Run the production-path fixture inside a retained, isolated hosted temp root."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--output", type=Path, default=Path("runtime-recovery-production.json"))
    args = parser.parse_args()
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise SystemExit("This launcher requires a hosted Actions disposable workspace.")
    base = os.environ.get("RUNNER_TEMP") if os.name == "nt" else tempfile.gettempdir()
    if not base:
        raise SystemExit("Missing hosted temp directory")
    base = Path(base).resolve()
    home = Path.home().resolve()
    if base.is_relative_to(home) or home.is_relative_to(base):
        raise SystemExit("Hosted temp directory overlaps the user home")
    root = Path(tempfile.mkdtemp(prefix="tokenbar-runtime-", dir=base)).resolve()
    # Rust canonicalize returns the extended prefix on Windows; pass that same
    # canonical form to the fixture's strict environment containment checks.
    native_root = str(root)
    if os.name == "nt" and not native_root.startswith("\\\\?\\"):
        native_root = "\\\\?\\" + native_root
    root = Path(native_root)
    env = os.environ.copy()
    for name, directory in {
        "CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR": "tauri-support",
        "CODEX_TOKEN_BAR_TAURI_CACHE_DIR": "tauri-cache",
        "CODEX_TOKEN_BAR_SUPPORT_BASE_DIR": "shared-support",
        "CODEX_TOKEN_BAR_CACHE_BASE_DIR": "shared-cache",
        "CODEX_TOKEN_BAR_TAURI_USAGE_CACHE_DIR": "legacy-usage",
    }.items():
        env[name] = str(root / directory)
    binary = args.binary.resolve()
    if os.name == "nt":
        binary = binary.with_suffix(".exe")
    completed = subprocess.run([str(binary), str(root)], env=env,
                               capture_output=True, text=True, encoding="utf-8")
    if completed.stderr:
        print(completed.stderr, end="")
    print(completed.stdout, end="")
    if completed.returncode:
        raise SystemExit(completed.returncode)
    result = json.loads(completed.stdout)
    if result.get("status") != "PASS":
        raise SystemExit("Production-path fixture did not pass")
    result["fixtureRootRetained"] = True
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
