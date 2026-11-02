#!/usr/bin/env python3
"""Gate distinct-source pressure through the real Rust business-store routes.

Each case has a fresh, isolated synthetic Home. The native probe performs cold
publication, real model enrichment with accounting digests unchanged, and a warm
no-op. Stage peaks are sampled before each ready batch is imported, not after
cleanup. This measures source count, not real-history byte volume or installed UI.
"""
from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

DEFAULT_SIZES = (13, 128, 512, 4124)
OVERRIDES = (
    "CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR", "CODEX_TOKEN_BAR_TAURI_CACHE_DIR",
    "CODEX_TOKEN_BAR_SUPPORT_BASE_DIR", "CODEX_TOKEN_BAR_CACHE_BASE_DIR",
    "CODEX_TOKEN_BAR_TAURI_USAGE_CACHE_DIR",
)


def validate_options(sizes: tuple[int, ...], timeout: int, max_gap: float, max_backfill: float) -> None:
    if not sizes or len(set(sizes)) != len(sizes) or any(type(n) is not int or not 9 <= n <= 8192 for n in sizes):
        raise ValueError("sizes must be nonempty, unique integers in 9...8192")
    for value in (timeout, max_gap, max_backfill):
        if type(value) not in (int, float) or not math.isfinite(value) or value <= 0:
            raise ValueError("execution timeout and latency budgets must be finite positive numbers")


def validate_profile(value: dict, count: int, max_gap: float, max_backfill: float) -> None:
    def equal_integer(item: dict, field: str, expected: int) -> None:
        if type(item.get(field)) is not int or item[field] != expected:
            raise ValueError(f"{field} must equal {expected}, found {item.get(field)!r}")

    if not isinstance(value, dict) or value.get("status") != "PASS":
        raise ValueError("native source-count probe did not pass")
    for field in ("files", "events", "modelsRestored"):
        equal_integer(value, field, count)
    equal_integer(value, "tokens", 120 * count + count * (count - 1) // 2)
    equal_integer(value, "stageStoresAfter", 0)
    equal_integer(value, "concurrentWriteAssertions", 0)
    if value.get("concurrentWriterProbeEnabled") is not False:
        raise ValueError("scale timing must exclude artificial per-job concurrent-writer assertions")
    if value.get("cfgTest") is not False or value.get("nativeProductionRoutes") is not True:
        raise ValueError("raw test SQLite cannot satisfy the production source-count gate")
    if value.get("sourceBytesUnchanged") is not True or value.get("sourceFactsVerified") is not True:
        raise ValueError("synthetic per-source facts or original source bytes were not preserved")
    for field in ("sourceBytesDigest", "numericRowsDigestBefore", "numericRowsDigestAfter"):
        if not isinstance(value.get(field), str) or re.fullmatch(r"[0-9a-f]{64}", value[field]) is None:
            raise ValueError(f"missing typed/source digest: {field}")
    if value["numericRowsDigestBefore"] != value["numericRowsDigestAfter"]:
        raise ValueError("backfill changed typed numeric history or event identities")
    for name in ("cold", "backfill", "warm"):
        phase = value.get(name)
        if not isinstance(phase, dict):
            raise ValueError(f"missing {name} production phase")
        warm = name == "warm"
        equal_integer(phase, "stagedJobs", 0 if warm else count)
        equal_integer(phase, "batches", 0 if warm else (count + 3) // 4)
        equal_integer(phase, "peakStageStores", 0 if warm else 4)
        equal_integer(phase, "peakStageTables", 0 if warm else 16)
        for field in ("elapsedSeconds", "largestProgressGapSeconds"):
            number = phase.get(field)
            if type(number) not in (int, float) or not math.isfinite(number) or number < 0:
                raise ValueError(f"invalid {name}.{field}: {number!r}")
        if phase["largestProgressGapSeconds"] > max_gap:
            raise ValueError(f"{name} progress gap exceeded {max_gap}s")
        if not warm and (type(phase.get("progressEvents")) is not int or phase["progressEvents"] <= 0):
            raise ValueError(f"{name} did not observe actual product progress")
    backfill = value["backfill"]
    if backfill.get("modelBackfillMonotonic") is not True or backfill.get("modelBackfillProgressError") is not None:
        raise ValueError("model backfill visible progress regressed or was not observed")
    equal_integer(backfill, "lastBackfillCompleted", count)
    if type(backfill.get("backfillProgressEvents")) is not int or backfill["backfillProgressEvents"] < count:
        raise ValueError("backfill did not observe progress for all distinct sources")
    if backfill["elapsedSeconds"] > max_backfill:
        raise ValueError(f"backfill exceeded {max_backfill}s")
    total = value.get("totalSeconds")
    if type(total) not in (int, float) or not math.isfinite(total) or total < 0:
        raise ValueError("invalid totalSeconds")


def validate_profiles(profiles: list[dict], sizes: tuple[int, ...], max_gap: float, max_backfill: float) -> None:
    if [value.get("files") for value in profiles] != list(sizes):
        raise ValueError("each requested source count must have exactly one profile in execution order")
    for value, count in zip(profiles, sizes, strict=True):
        validate_profile(value, count, max_gap, max_backfill)


def validate_build_profile(name: str, actual: dict) -> None:
    if name not in ("dev", "release") or not isinstance(actual, dict) or actual.get("test") is not False:
        raise ValueError("fixture requires an explicit non-test Cargo build profile")
    if name == "release" and (actual.get("opt_level") != "3" or actual.get("debug_assertions") is not False):
        raise ValueError("release timing requires the actual optimized release artifact; profile overrides are not accepted")


def build_fixture(repository: Path, output: Path, timeout: int, profile: str) -> tuple[Path, dict]:
    command = ["cargo", "build", "--locked", "--manifest-path", "tauri-app/src-tauri/Cargo.toml",
               "--features", "business-store-fixture", "--example", "business-store-fixture",
               "--message-format=json"]
    if profile == "release":
        command.append("--release")
    with (output / "build.jsonl").open("w", encoding="utf-8") as stdout, (output / "build.log").open("w", encoding="utf-8") as stderr:
        result = subprocess.run(command, cwd=repository, stdout=stdout, stderr=stderr, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"native fixture build failed ({result.returncode}); see build.log/build.jsonl")
    artifacts = []
    for line in (output / "build.jsonl").read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if value.get("reason") == "compiler-artifact" and value.get("target", {}).get("name") == "business-store-fixture" and value.get("executable"):
            artifacts.append(value)
    if len(artifacts) != 1 or not Path(artifacts[0]["executable"]).is_file():
        raise RuntimeError("Cargo did not identify exactly one executable for the current source")
    actual = artifacts[0].get("profile")
    validate_build_profile(profile, actual)
    compiler_settings = (
        "RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS", "CARGO_BUILD_TARGET", "CC", "CFLAGS", "CXX", "CXXFLAGS",
        *tuple(f"CARGO_PROFILE_{profile.upper()}_{setting}" for setting in (
            "OPT_LEVEL", "DEBUG", "DEBUG_ASSERTIONS", "OVERFLOW_CHECKS", "LTO", "CODEGEN_UNITS", "PANIC",
        )),
    )
    return Path(artifacts[0]["executable"]), {
        "profileName": profile, "artifactProfile": actual, "command": command,
        "compilerEnvironment": {key: os.environ[key] for key in compiler_settings if key in os.environ},
    }


def child_cpu_usage() -> tuple[float, float] | None:
    # The child process has been reaped before the second reading. Subtracting
    # the first excludes Cargo's earlier CPU time and includes native threads.
    try:
        import resource
        value = resource.getrusage(resource.RUSAGE_CHILDREN)
        return value.ru_utime, value.ru_stime
    except (ImportError, OSError, ValueError):
        return None


def child_cpu_delta(before: tuple[float, float] | None) -> dict:
    after = child_cpu_usage()
    if before is None or after is None:
        return {"status": "UNAVAILABLE", "reason": "child CPU accounting is unavailable on this host"}
    return {"status": "MEASURED", "method": "getrusage-children-delta",
            "userSeconds": after[0] - before[0], "systemSeconds": after[1] - before[1]}


def run_sizes(repository: Path, output: Path, sizes: tuple[int, ...], timeout: int,
              max_gap: float, max_backfill: float, profile: str = "dev") -> dict:
    validate_options(sizes, timeout, max_gap, max_backfill)
    output.mkdir(parents=True, exist_ok=False)
    sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository, text=True).strip()
    dirty = bool(subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=no"], cwd=repository, text=True).strip())
    report = {"schemaVersion": 1, "sourceSha": sha, "workingTreeDirty": dirty, "status": "RUNNING",
              "requestedSizes": list(sizes), "requestedBuildProfile": profile, "profiles": [], "failures": [],
              "budgets": {"executionTimeoutSeconds": timeout, "maxProgressGapSeconds": max_gap, "maxBackfillSeconds": max_backfill},
              "scope": "Synthetic distinct-source count through real Rust A routing. Model progress monotonicity is observed only for the actual backfillingModel phase. Per-job artificial concurrent-writer assertions are covered separately by the default 13-scenario fixture; normal diagnostic fsync, transactions, seals and real schema peak checks remain enabled. Timings apply only to the recorded Cargo artifact profile. Not real-history byte volume, already-retained massive stage catalogs, or installed-app UX acceptance."}
    target = output / "report.json"

    def save() -> None:
        temporary = target.with_suffix(".tmp")
        temporary.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        temporary.replace(target)

    save()
    try:
        executable, build = build_fixture(repository, output, timeout, profile)
        report["build"] = build
        save()
        base = Path(os.environ.get("RUNNER_TEMP", tempfile.gettempdir())).resolve()
        home = Path.home().resolve()
        if base == home or base.is_relative_to(home):
            if os.name == "nt":
                raise ValueError("an external RUNNER_TEMP is required; refusing the user's home")
            base = Path("/tmp")
        for count in sizes:
            report["runningSize"] = count
            root = None
            failure = None
            native = None
            stdout_path = output / f"source-count-{count}.json"
            stderr_path = output / f"source-count-{count}.log"
            started = time.monotonic()
            cpu_before = child_cpu_usage()
            try:
                root = Path(tempfile.mkdtemp(prefix=f"tokenbar-rust-sources-{count}-", dir=base)).resolve()
                report["runningRoot"] = str(root)
                save()
                env = os.environ.copy()
                for key, slug in zip(OVERRIDES, ("s", "c", "ss", "sc", "uc"), strict=True):
                    directory = root / slug
                    directory.mkdir()
                    env[key] = str(directory)
                with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
                    process = subprocess.Popen([str(executable), str(root), "--source-count", str(count)],
                                               cwd=repository, env=env, stdout=stdout, stderr=stderr)
                    try:
                        code = process.wait(timeout=timeout)
                    except subprocess.TimeoutExpired:
                        process.kill(); process.wait()
                        raise RuntimeError(f"{count}-source native probe exceeded its {timeout}s execution deadline")
                    except BaseException:
                        process.kill(); process.wait()
                        raise
                if code:
                    raise RuntimeError(f"{count}-source native probe failed ({code}); see {stdout_path.name}/{stderr_path.name}")
                native = json.loads(stdout_path.read_text(encoding="utf-8"))
                if not isinstance(native, dict):
                    raise ValueError("native source-count probe did not produce an object")
                report["profiles"].append(native)
                validate_profile(native, count, max_gap, max_backfill)
            except Exception as error:
                failure = str(error)
            except BaseException as error:
                failure = f"{type(error).__name__}: {error}"
                raise
            finally:
                duration = time.monotonic() - started
                cpu = child_cpu_delta(cpu_before)
                if isinstance(native, dict):
                    native.update(commandSeconds=duration, log=stderr_path.name, cpu=cpu)
                if root is not None:
                    diagnostics = root / "s" / "migration-diagnostics"
                    if diagnostics.is_dir():
                        try:
                            shutil.copytree(diagnostics, output / f"diagnostics-{count}")
                        except OSError as error:
                            failure = f"{failure + '; ' if failure else ''}diagnostic copy failed: {error}"
                if failure is None and root is not None:
                    try:
                        shutil.rmtree(root)
                    except OSError as error:
                        failure = f"fixture cleanup failed: {error}"
                if failure is not None:
                    report["failures"].append({"files": count, "error": failure,
                        "preservedRoot": str(root) if root is not None else None,
                        "log": stderr_path.name, "stdout": stdout_path.name,
                        "commandSeconds": duration, "cpu": cpu})
                save()
        report.pop("runningSize", None)
        report.pop("runningRoot", None)
        if report["failures"]:
            raise RuntimeError("source-count profiles failed: " + "; ".join(
                f"{item['files']}: {item['error']}" for item in report["failures"]))
        validate_profiles(report["profiles"], sizes, max_gap, max_backfill)
        report["status"] = "PASS"
        report.pop("runningSize", None)
        report.pop("runningRoot", None)
    except BaseException as error:
        report["status"] = "FAIL"
        report["error"] = str(error) or type(error).__name__
        raise
    finally:
        save()
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sizes", type=int, nargs="+", default=DEFAULT_SIZES)
    parser.add_argument("--timeout", type=int, default=1200)
    parser.add_argument("--max-progress-gap", type=float, default=30)
    parser.add_argument("--max-backfill-seconds", type=float, default=600)
    parser.add_argument("--profile", choices=("dev", "release"), default="dev")
    parser.add_argument("--output", type=Path, default=Path("rust-backfill-scale-evidence"))
    args = parser.parse_args()
    try:
        validate_options(tuple(args.sizes), args.timeout, args.max_progress_gap, args.max_backfill_seconds)
    except ValueError as error:
        parser.error(str(error))
    report = run_sizes(Path(__file__).resolve().parents[1], args.output.resolve(), tuple(args.sizes),
                       args.timeout, args.max_progress_gap, args.max_backfill_seconds, args.profile)
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
