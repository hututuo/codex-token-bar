#!/usr/bin/env python3
"""Run released native code, then resume its committed and interrupted A states.

This supplements (not replaces) the real v0.9.7 import and native Swift gates.
It compiles non-cfg(test) Rust production routing on macOS and Windows. A small
feature-gated offline probe is injected into exact Git archives: production
source files remain byte-for-byte unchanged. Sources, private state, logs and
proofs use fresh owned temporary roots; no installed app directory is opened.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from prepare_v097_upgrade_validation import extract_revision

RELEASES = {
    "0.9.8": "0a9520f99c3f13e0f48c098298b07611dc7acd63",
    "0.9.9": "35f31628e05930993c6c07155291a9740f04953d",
    "0.9.10": "1b12dc364fd064d27617392ff9b81645d6428e00",
    "0.9.11": "25af234290b6410016d34b898682cca26c62e08a",
}
OVERRIDES = dict(zip(("CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR", "CODEX_TOKEN_BAR_TAURI_CACHE_DIR",
    "CODEX_TOKEN_BAR_SUPPORT_BASE_DIR", "CODEX_TOKEN_BAR_CACHE_BASE_DIR", "CODEX_TOKEN_BAR_TAURI_USAGE_CACHE_DIR"),
    ("support", "cache", "shared-support", "shared-cache", "usage-cache")))
INJECTION = ("tauri-app/src-tauri/src/lib.rs", "tauri-app/src-tauri/Cargo.toml",
    "tauri-app/src-tauri/src/formed_release_probe.rs", "tauri-app/src-tauri/examples/formed-release-probe.rs")
PREFIX = "TOKENBAR_FORMED_REPORT "
SCENARIOS = ("committed", "interrupted")
PHASES = ("resume", "reopen")
EXAMPLE = '''fn main() {
    let args: Vec<_> = std::env::args_os().collect();
    if args.len()!=3 { eprintln!("required root and phase"); std::process::exit(2); }
    let phase=args[2].to_str().expect("UTF-8 phase");
    match codex_token_bar_lib::formed_release_probe::run(std::path::Path::new(&args[1]),phase) {
        Ok(value)=>println!("TOKENBAR_FORMED_REPORT {}",value),
        Err(error)=>{eprintln!("TOKENBAR_FORMED_FAIL: {}",error); std::process::exit(1);}
    }
}
'''
LATE_QUOTA = '''import os,sqlite3,sys
c=sqlite3.connect(sys.argv[1]);c.execute('PRAGMA journal_mode=WAL');c.execute('PRAGMA wal_autocheckpoint=0')
columns=[r[1] for r in c.execute('PRAGMA table_info(quota_snapshots)')]
quote=lambda s:'"'+s.replace('"','""')+'"'
values=['44' if s=='id' else quote(s)+'+1' if s=='created_at' else quote(s) for s in columns]
c.execute('INSERT INTO quota_snapshots ('+','.join(map(quote,columns))+') SELECT '+','.join(values)+' FROM quota_snapshots LIMIT 1')
c.commit();os._exit(0)
'''


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def pinned_revision(repository: Path, release: str) -> str:
    expected = RELEASES[release]
    actual = subprocess.check_output(["git", "rev-parse", f"v{release}^{{commit}}"], cwd=repository, text=True).strip()
    if actual != expected:
        raise ValueError(f"Public tag identity changed: {release}: {actual}")
    return actual


def inject(repository: Path, revision: str, destination: Path) -> dict:
    if destination.exists():
        raise ValueError("Refusing to overwrite a source archive")
    extract_revision(repository, revision, destination)
    native = destination / "tauri-app/src-tauri"
    source = repository / "scripts/fixtures/formed_release_probe.rs"
    with (native / "src/lib.rs").open("a", encoding="utf-8") as stream:
        stream.write('\n#[cfg(feature = "business-store-fixture")]\npub mod formed_release_probe;\n')
    with (native / "Cargo.toml").open("a", encoding="utf-8") as stream:
        stream.write('\n[[example]]\nname = "formed-release-probe"\npath = "examples/formed-release-probe.rs"\nrequired-features = ["business-store-fixture"]\n')
    shutil.copyfile(source, native / "src/formed_release_probe.rs")
    (native / "examples/formed-release-probe.rs").write_text(EXAMPLE, encoding="utf-8")
    # Tauri's production configuration embeds frontendDist at compile time.
    # Use the candidate's already-built assets; this probe never renders them.
    dist = repository / "tauri-app/dist"
    if not dist.is_dir():
        raise ValueError("Build the locked candidate frontend before this native probe")
    shutil.copytree(dist, destination / "tauri-app/dist", dirs_exist_ok=True)
    tracked = subprocess.check_output(["git", "ls-tree", "-r", "--name-only", revision,
        "tauri-app/src-tauri/src"], cwd=repository, text=True).splitlines()
    manifest = {}
    for relative in tracked:
        if relative in INJECTION:
            continue
        expected = subprocess.check_output(["git", "rev-parse", f"{revision}:{relative}"], cwd=repository, text=True).strip()
        actual = subprocess.check_output(["git", "hash-object", str(destination / relative)], cwd=repository, text=True).strip()
        if expected != actual:
            raise ValueError(f"Production source changed in archive: {relative}")
        manifest[relative] = expected
    return {"sourceSha": revision, "probeSha256": digest(source), "injection": list(INJECTION),
            "productionFilesUnchanged": manifest, "cfgTest": False}


def execute(command: list[str], cwd: Path, env: dict, log: Path, expected: int = 0, timeout: int = 1800) -> str:
    with log.open("w", encoding="utf-8") as stream:
        child = subprocess.Popen(command, cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT)
        try:
            code = child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            child.kill(); child.wait()
            raise RuntimeError(f"Execution deadline exceeded; see {log.name}")
    text = log.read_text(encoding="utf-8", errors="replace")
    if code != expected:
        raise RuntimeError(f"Command returned {code}, expected {expected}; see {log.name}\n{text[-5000:]}")
    return text


def parse_report(text: str, phase: str, release: str, scenario: str) -> dict:
    matches = [json.loads(line.split(PREFIX, 1)[1]) for line in text.splitlines() if PREFIX in line]
    if len(matches) != 1:
        raise ValueError("Expected one actual production report")
    value = matches[0]
    expected = dict(status="PASS", phase=phase, producerVersion=release, scenario=scenario,
        cfgTest=False, totals=[162, 310], oldTypedProofsPreserved=True, crashWALPreserved=True,
        rawDisappearanceRetainsHistory=True, oldBPreserved=scenario=="committed")
    for key, item in expected.items():
        if value.get(key) != item:
            raise ValueError(f"Invalid production proof {key}: {value.get(key)!r}, expected {item!r}")
    return value


def validate_matrix(results: list[dict]) -> None:
    expected = {(scenario, phase) for scenario in SCENARIOS for phase in PHASES}
    actual = [(item.get("scenario"), item.get("phase")) for item in results]
    if len(actual) != len(expected) or set(actual) != expected:
        raise ValueError("Every committed/interrupted resume and reopen must produce one result")
    failed = [item for item in results if item.get("status") != "PASS"]
    if failed:
        raise ValueError("Historical state checks failed: " + "; ".join(
            f"{item.get('scenario')}/{item.get('phase')}: {item.get('error', 'not passed')}" for item in failed))


def run_scenario(repository: Path, release: str, scenario: str, root: Path, base: Path,
                 bins: dict[str, Path], output: Path) -> list[dict]:
    root.mkdir()
    (root / ".formed-release-fixture").write_text("synthetic-only-v1\n")
    env = probe_environment(base)
    for key, slug in OVERRIDES.items():
        path = root / slug; path.mkdir(); env[key] = str(path)
    results = []
    try:
        execute([str(bins["release"]), str(root), scenario], repository, env,
                output / (scenario+"-release.log"), expected=86, timeout=300)
        state = json.loads((root / "formed-state.json").read_text(encoding="utf-8"))
        if (state.get("producerVersion") != release or state.get("cfgTest") is not False
                or state.get("phase") != scenario or not isinstance(state.get("proofs"), dict)
                or not state["proofs"] or state.get("formedExact") is not (scenario == "committed")
                or state.get("formedB") is not (scenario == "committed")):
            raise ValueError("Released binary failed to create the required proved, populated production state")
        quota = Path(state["legacyQuota"]).resolve(strict=True)
        if not quota.is_relative_to(root.resolve()) or not quota.is_file():
            raise ValueError("Released quota source escapes the disposable fixture")
        shutil.copyfile(root / "formed-state.json", output / (scenario+"-formed-state.json"))
        if scenario == "interrupted":
            execute([sys.executable, "-c", LATE_QUOTA, str(quota)], repository, env,
                    output / "interrupted-late-quota.log", timeout=30)
            wal = Path(str(quota)+"-wal")
            if not wal.is_file() or wal.stat().st_size == 0:
                raise ValueError("Late observation was not left committed in a nonempty source WAL")
        for phase in PHASES:
            try:
                text = execute([str(bins["candidate"]), str(root), phase], repository, env,
                    output / (scenario+"-"+phase+".log"), timeout=300)
                results.append(parse_report(text, phase, release, scenario))
            except Exception as error:
                results.append({"status": "FAIL", "scenario": scenario, "phase": phase, "error": str(error)})
    except Exception as error:
        # A failed producer leaves both required phases unverified. They must
        # never be silently omitted or treated as passing skipped work.
        results = [{"status": "FAIL", "scenario": scenario, "phase": phase,
                    "error": "Producer/preparation failed: " + str(error)} for phase in PHASES]
    finally:
        # Preserve the entire synthetic state even when an intermediate phase
        # fails. This is app data created in this isolated run, never user data.
        shutil.make_archive(str(output / (scenario+"-synthetic-state")), "zip", root)
    return results


def collect_scenarios(operation, report: dict, save) -> None:
    for scenario in SCENARIOS:
        try:
            report["scenarios"].extend(operation(scenario))
        except Exception as error:
            report["scenarios"].extend({"status": "FAIL", "scenario": scenario, "phase": phase,
                "error": str(error)} for phase in PHASES)
        save()
    validate_matrix(report["scenarios"])


def external_temporary_base(candidates: list[Path], home: Path) -> Path:
    """Select an existing OS/runner temp location outside any real home.

    Hosted macOS sets RUNNER_TEMP under /Users/runner. Do not treat that
    convenience variable as proof of isolation, or relax the native guard.
    Resolve links before checking; never use a home ancestor such as /.
    """
    home = home.resolve()
    for candidate in candidates:
        base = candidate.resolve()
        if (base.is_dir() and not base.is_relative_to(home)
                and not home.is_relative_to(base) and os.access(base, os.W_OK | os.X_OK)):
            return base
    raise ValueError("No writable external temporary directory; refusing user home")


def probe_environment(base: Path) -> dict[str, str]:
    # Rust's std::env::temp_dir and the Python producer must see the SAME
    # canonical base. Change child environment only, not global/home settings.
    return {**os.environ, **{key: str(base) for key in ("TMPDIR", "TMP", "TEMP")}}


def compile_probe(repository: Path, source: Path, scratch: Path, base: Path,
                  label: str, output: Path) -> Path:
    """Compile each source archive with a fresh, separately owned target.

    Tauri's local plugin build scripts persist absolute permission-file paths.
    Reusing a target from another extracted archive can read that archive's
    permissions, or fail after the old temporary directory has been removed.
    Registry/download caches are safe to retain; these build outputs are not.
    Copy the executable before removing its target so the two full dependency
    builds do not occupy the runner's limited disk at the same time.
    """
    executable = "formed-release-probe" + (".exe" if os.name == "nt" else "")
    binary = scratch / (label + (".exe" if os.name == "nt" else ""))
    with tempfile.TemporaryDirectory(prefix=label+"-build-", dir=scratch) as temporary:
        target = Path(temporary).resolve() / "target"
        env = probe_environment(base)
        env["CARGO_TARGET_DIR"] = str(target)
        proof = {"status": "RUNNING", "sourceDirectory": str(source),
                 "targetDirectory": str(target), "targetScope": "fresh-per-binary",
                 "usesRestoredTarget": False}
        path = output / (label+"-build.json")
        def save():
            path.write_text(json.dumps(proof, indent=2)+"\n", encoding="utf-8")
        save()
        try:
            execute(["cargo", "build", "--locked", "--manifest-path",
                     str(source / "tauri-app/src-tauri/Cargo.toml"),
                     "--target-dir", str(target), "--features", "business-store-fixture",
                     "--example", "formed-release-probe"], repository, env,
                    output / (label+"-build.log"))
            shutil.copy2(target / "debug/examples" / executable, binary)
            proof.update(status="PASS", binarySha256=digest(binary))
            return binary
        except Exception as error:
            proof.update(status="FAIL", error=str(error))
            raise
        finally:
            save()


def run(repository: Path, release: str, output: Path) -> dict:
    output.mkdir(parents=True, exist_ok=False)
    old = pinned_revision(repository, release)
    candidate = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository, text=True).strip()
    report = {"schemaVersion": 1, "release": release, "releaseSha": old, "candidateSha": candidate,
              "status": "RUNNING", "scenarios": [],
              "requiredScenarios": list(SCENARIOS), "requiredPhases": list(PHASES),
              "scope": "Actual Rust production; this is not native Swift formed-release validation"}
    def save():
        (output / "report.json").write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")
    save()
    explicit = os.environ.get("TOKENBAR_FIXTURE_TEMP_BASE")
    system_temp = Path(os.environ.get("SystemRoot", "C:/Windows")) / "Temp" if os.name == "nt" else Path("/tmp")
    candidates = [Path(explicit)] if explicit else [
        Path(os.environ.get("RUNNER_TEMP", tempfile.gettempdir())), Path(tempfile.gettempdir()), system_temp]
    try:
        base = external_temporary_base(candidates, Path.home())
        context = tempfile.TemporaryDirectory(prefix="tokenbar-formed-", dir=base)
    except Exception as error:
        report.update(status="FAIL", error=str(error)); save()
        raise
    with context as temp:
        scratch = Path(temp).resolve()
        try:
            bins = {}
            for label, revision in (("release", old), ("candidate", candidate)):
                source = scratch / (label+"-source")
                injection = inject(repository, revision, source)
                (output / (label+"-source.json")).write_text(json.dumps(injection, indent=2)+"\n", encoding="utf-8")
                bins[label] = compile_probe(repository, source, scratch, base, label, output)
            collect_scenarios(lambda scenario: run_scenario(repository, release, scenario,
                scratch / scenario, base, bins, output), report, save)
            report["status"] = "PASS"
        except Exception as error:
            report["status"] = "FAIL"; report["error"] = str(error)
            # Preserve a failed state, not just its last error. Exclude source/
            # build artifacts and executable binaries; there is no user data.
            for scenario in SCENARIOS:
                if (scratch / scenario).exists():
                    shutil.make_archive(str(output / (scenario+"-failed-state")), "zip", scratch / scenario)
            raise
        finally:
            save()
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", required=True, choices=RELEASES)
    parser.add_argument("--output", type=Path, default=Path("formed-state-evidence"))
    args = parser.parse_args()
    print(json.dumps(run(Path(__file__).resolve().parents[1], args.release, args.output.resolve()), sort_keys=True))


if __name__ == "__main__":
    main()
