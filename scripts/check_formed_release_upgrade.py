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
import tomllib

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
PROBE_PACKAGE = "codex-token-bar"
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


def local_patch_packages(source: Path, manifest: Path) -> list[str]:
    """Read package names for in-archive path patches in the native manifest."""
    archive = source.resolve()
    manifest = manifest.resolve()
    if not manifest.is_relative_to(archive) or not manifest.is_file() or not os.access(manifest, os.R_OK):
        raise ValueError("Native Cargo.toml is not a readable file in the source archive")
    with manifest.open("rb") as stream:
        cargo = tomllib.load(stream)

    packages = {PROBE_PACKAGE}
    patch_table = cargo.get("patch", {})
    if not isinstance(patch_table, dict):
        raise ValueError("Invalid [patch] table in source archive")
    patches = patch_table.get("crates-io", {})
    if not isinstance(patches, dict):
        raise ValueError("Invalid [patch.crates-io] table in source archive")
    for patch_name, patch in patches.items():
        if not isinstance(patch, dict) or "path" not in patch:
            continue
        relative_path = patch["path"]
        if not isinstance(relative_path, str):
            raise ValueError(f"Invalid local patch path for {patch_name}")
        crate_dir = (manifest.parent / relative_path).resolve()
        if not crate_dir.is_relative_to(archive):
            raise ValueError(f"Local patch crate escapes the source archive: {patch_name}")
        if not crate_dir.is_dir():
            raise ValueError(f"Local patch crate directory is missing: {patch_name}")
        crate_manifest = (crate_dir / "Cargo.toml").resolve()
        if (not crate_manifest.is_relative_to(archive) or not crate_manifest.is_file()
                or not os.access(crate_manifest, os.R_OK)):
            raise ValueError(f"Local patch crate has no readable in-archive Cargo.toml: {patch_name}")
        with crate_manifest.open("rb") as stream:
            crate_cargo = tomllib.load(stream)
        package_table = crate_cargo.get("package")
        package = package_table.get("name") if isinstance(package_table, dict) else None
        if not isinstance(package, str) or not package:
            raise ValueError(f"Local patch crate has no package name: {patch_name}")
        packages.add(package)
    return sorted(packages)


def build_probe(repository: Path, source: Path, env: dict[str, str], log: Path) -> str:
    """Rebuild the injected package while retaining cached third-party crates.

    Tauri and patched plugins record absolute permission paths. Historical and
    candidate archives use different temporary roots but share this helper's
    target directory, so Cargo can otherwise reuse successful build-script
    outputs that point at the previous archive. Clean the root package and
    local path-patched crates only; registry/git downloads and compiled
    third-party dependency artifacts remain reusable.
    """
    target = Path(env["CARGO_TARGET_DIR"]).resolve()
    managed_target = (repository / "tauri-app/src-tauri/target").resolve()
    if target != managed_target:
        raise ValueError("Refusing to clean outside the formed-release helper target")

    manifest = source / "tauri-app/src-tauri/Cargo.toml"
    packages = local_patch_packages(source, manifest)
    for index, package in enumerate(packages):
        clean_log = log.with_name(log.stem + f"-clean-{index}.log")
        execute(["cargo", "clean", "--locked", "--manifest-path", str(manifest), "--package", package,
            "--target-dir", str(target)], repository, env, clean_log, timeout=300)
    return execute(["cargo", "build", "--locked", "--manifest-path", str(manifest),
        "--features", "business-store-fixture", "--example", "formed-release-probe"],
        repository, env, log)


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


def run(repository: Path, release: str, output: Path) -> dict:
    output.mkdir(parents=True, exist_ok=False)
    old = pinned_revision(repository, release)
    candidate = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository, text=True).strip()
    report = {"schemaVersion": 1, "release": release, "releaseSha": old, "candidateSha": candidate,
              "status": "RUNNING", "scenarios": [], "scope": "Actual Rust production; native Swift uses separate gates"}
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
                env = probe_environment(base)
                target = repository / "tauri-app/src-tauri/target"
                env["CARGO_TARGET_DIR"] = str(target)
                build_probe(repository, source, env, output / (label+"-build.log"))
                executable = "formed-release-probe" + (".exe" if os.name == "nt" else "")
                bins[label] = scratch / (label + (".exe" if os.name == "nt" else ""))
                shutil.copy2(target / "debug/examples" / executable, bins[label])
            for scenario in ("committed", "interrupted"):
                root = scratch / scenario; root.mkdir()
                (root / ".formed-release-fixture").write_text("synthetic-only-v1\n")
                env = probe_environment(base)
                for key, slug in OVERRIDES.items():
                    path = root / slug; path.mkdir(); env[key] = str(path)
                execute([str(bins["release"]), str(root), scenario], repository, env,
                    output / (scenario+"-release.log"), expected=86, timeout=300)
                state = json.loads((root / "formed-state.json").read_text(encoding="utf-8"))
                if state.get("producerVersion") != release or state.get("cfgTest") is not False or not state.get("proofs"):
                    raise ValueError("Released binary failed to create a proved, populated production state")
                shutil.copyfile(root / "formed-state.json", output / (scenario+"-formed-state.json"))
                if scenario == "interrupted":
                    execute([sys.executable, "-c", LATE_QUOTA, state["legacyQuota"]], repository, env,
                            output / "interrupted-late-quota.log", timeout=30)
                    if not Path(state["legacyQuota"]+"-wal").is_file():
                        raise ValueError("Late observation was not left committed in a real source WAL")
                for phase in ("resume", "reopen"):
                    text = execute([str(bins["candidate"]), str(root), phase], repository, env,
                        output / (scenario+"-"+phase+".log"), timeout=300)
                    report["scenarios"].append(parse_report(text, phase, release, scenario)); save()
                shutil.make_archive(str(output / (scenario+"-synthetic-state")), "zip", root)
            report["status"] = "PASS"
        except Exception as error:
            report["status"] = "FAIL"; report["error"] = str(error)
            # Preserve a failed state, not just its last error. Exclude source/
            # build artifacts and executable binaries; there is no user data.
            for scenario in ("committed", "interrupted"):
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
