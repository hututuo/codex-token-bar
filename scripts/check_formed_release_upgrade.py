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
import sqlite3
import stat
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
RECOVERY_DIRECTORIES = ("support/codex-ledger-snapshots", "support/ledger-migration-backups")
SCHEMA11_RECOVERY_SUFFIXES = (".schema11-candidate", ".schema11-rollback", ".schema11-migration.json")
TRANSIENT_RECOVERY_SUFFIXES = ("-wal", "-shm", "-journal", "-lock", ".lock")
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


def _canonical_json(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _file_sha256(path: Path) -> str:
    digest_value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest_value.update(chunk)
    return digest_value.hexdigest()


def _validate_synthetic_scenario(root: Path, owned_parent: Path) -> Path:
    if root.is_symlink():
        raise ValueError("Refusing to inspect a symlinked scenario root")
    resolved_root = root.resolve(strict=True)
    resolved_parent = owned_parent.resolve(strict=True)
    if resolved_root.parent != resolved_parent:
        raise ValueError("Recovery-material inspection is limited to a direct disposable scenario child")
    marker = resolved_root / ".formed-release-fixture"
    try:
        marker_stat = marker.lstat()
    except OSError as error:
        raise ValueError("Disposable scenario ownership marker is unavailable") from error
    if not stat.S_ISREG(marker_stat.st_mode) or marker.read_text(encoding="utf-8") != "synthetic-only-v1\n":
        raise ValueError("Disposable scenario ownership marker is invalid")
    return resolved_root


def _transient_recovery_sidecar(path: Path) -> bool:
    name = path.name.lower()
    return name.endswith(TRANSIENT_RECOVERY_SUFFIXES)


def _manifest_file(root: Path, path: Path) -> dict:
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode):
        raise ValueError(f"Recovery material is not a regular file: {path.relative_to(root)}")
    if not path.resolve(strict=True).is_relative_to(root):
        raise ValueError(f"Recovery material escapes the disposable scenario: {path}")
    return {"path": path.relative_to(root).as_posix(), "size": metadata.st_size, "sha256": _file_sha256(path)}


def _walk_owned_recovery_directory(root: Path, relative: str, files: dict[str, dict]) -> None:
    directory = root / relative
    try:
        metadata = directory.lstat()
    except FileNotFoundError:
        return
    if not stat.S_ISDIR(metadata.st_mode):
        raise ValueError(f"Owned recovery directory is not a regular directory: {relative}")

    def fail_walk(error):
        raise error

    for current, directories, names in os.walk(directory, followlinks=False, onerror=fail_walk):
        parent = Path(current)
        for name in list(directories):
            child = parent / name
            child_stat = child.lstat()
            if not stat.S_ISDIR(child_stat.st_mode):
                raise ValueError(f"Symlink or non-directory in owned recovery directory: {child.relative_to(root)}")
        for name in names:
            path = parent / name
            if _transient_recovery_sidecar(path):
                continue
            entry = _manifest_file(root, path)
            files[entry["path"]] = entry


def _migration_attempt_state(root: Path) -> dict:
    database = root / "support/codex-ledger.sqlite"
    metadata = database.lstat()
    if not stat.S_ISREG(metadata.st_mode) or not database.resolve(strict=True).is_relative_to(root):
        raise ValueError("A container is not a regular file in the disposable scenario")
    uri = database.resolve(strict=True).as_uri() + "?mode=ro"
    try:
        connection = sqlite3.connect(uri, uri=True, timeout=5)
        connection.execute("PRAGMA query_only=ON")
        try:
            tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            required = {"tb_container_meta", "tb_legacy_inputs", "tb_store_imports", "tb_stores"}
            if not required.issubset(tables):
                raise ValueError(f"A container is missing migration evidence tables: {sorted(required - tables)}")
            metadata_rows = [list(row) for row in connection.execute(
                "SELECT key,value FROM tb_container_meta "
                "WHERE instr(lower(key),'migration')>0 OR instr(lower(key),'normaliz')>0 ORDER BY key")]

            def table_digest(table: str, ordering: str) -> dict:
                rows = [list(row) for row in connection.execute(f'SELECT * FROM "{table}" ORDER BY {ordering}')]
                return {"rowCount": len(rows), "sha256": hashlib.sha256(_canonical_json(rows)).hexdigest()}

            state = {
                "metadata": {"rowCount": len(metadata_rows), "sha256": hashlib.sha256(_canonical_json(metadata_rows)).hexdigest()},
                "tb_legacy_inputs": table_digest("tb_legacy_inputs", "source_path"),
                "tb_store_imports": table_digest("tb_store_imports", "store_id,source_digest"),
                "tb_stores": table_digest("tb_stores", "store_id"),
            }
            state["sha256"] = hashlib.sha256(_canonical_json(state)).hexdigest()
            return state
        finally:
            connection.close()
    except sqlite3.Error as error:
        raise ValueError(f"Could not inspect migration metadata in the disposable A container: {error}") from error


def recovery_material_snapshot(root: Path, owned_parent: Path) -> dict:
    """Hash owned recovery files and A migration records; never use mtimes."""
    root = _validate_synthetic_scenario(root, owned_parent)
    files: dict[str, dict] = {}
    for relative in RECOVERY_DIRECTORIES:
        _walk_owned_recovery_directory(root, relative, files)

    def fail_walk(error):
        raise error

    for current, directories, names in os.walk(root, followlinks=False, onerror=fail_walk):
        parent = Path(current)
        # Never follow an arbitrary link elsewhere in the disposable root.
        directories[:] = [name for name in directories if not (parent / name).is_symlink()]
        for name in names:
            path = parent / name
            if not name.endswith(SCHEMA11_RECOVERY_SUFFIXES) or _transient_recovery_sidecar(path):
                continue
            entry = _manifest_file(root, path)
            files[entry["path"]] = entry

    ordered_files = [files[name] for name in sorted(files)]
    migration_state = _migration_attempt_state(root)
    return {"files": ordered_files, "migrationState": migration_state}


def _recovery_snapshot_sha256(snapshot: dict) -> str:
    return hashlib.sha256(_canonical_json(snapshot)).hexdigest()


def _recovery_snapshot_difference(before: dict, after: dict) -> dict:
    left = {entry["path"]: entry for entry in before["files"]}
    right = {entry["path"]: entry for entry in after["files"]}
    return {
        "added": sorted(right.keys() - left.keys()),
        "removed": sorted(left.keys() - right.keys()),
        "changed": sorted(path for path in left.keys() & right.keys() if left[path] != right[path]),
        "migrationStateChanged": before["migrationState"] != after["migrationState"],
    }


def run_candidate_reopens(candidate_command: list[str], repository: Path, root: Path, owned_parent: Path,
        env: dict[str, str], output: Path, release: str, scenario: str, on_pass=None) -> tuple[list[dict], dict]:
    baseline = recovery_material_snapshot(root, owned_parent)
    baseline_sha = _recovery_snapshot_sha256(baseline)
    evidence = {
        "scope": [*RECOVERY_DIRECTORIES, "scenario files ending in schema11 recovery suffixes", "A migration/normalization metadata and ownership tables"],
        "baselineAfterResume": baseline,
        "baselineSha256": baseline_sha,
        "excludedTransientSidecars": list(TRANSIENT_RECOVERY_SUFFIXES),
        "mtimeCompared": False,
        "passes": [],
    }
    proofs = []
    for ordinal in range(1, 4):
        log = output / f"{scenario}-reopen-{ordinal}.log"
        text = execute([*candidate_command, str(root), "reopen"], repository, env, log, timeout=300)
        proof = parse_report(text, "reopen", release, scenario)
        observed = recovery_material_snapshot(root, owned_parent)
        difference = _recovery_snapshot_difference(baseline, observed)
        retained = not any(difference.values())
        pass_evidence = {
            "ordinal": ordinal,
            "independentCandidateProcess": True,
            "recoveryMaterialsRetained": retained,
            "manifestSha256": _recovery_snapshot_sha256(observed),
            "migrationStateSha256": observed["migrationState"]["sha256"],
        }
        if not retained:
            pass_evidence["difference"] = difference
        evidence["passes"].append(pass_evidence)
        proof.update({
            "reopenOrdinal": ordinal,
            "recoveryMaterialsRetained": retained,
            "recoveryMaterialManifestSha256": pass_evidence["manifestSha256"],
            "migrationStateSha256": pass_evidence["migrationStateSha256"],
            "mtimeCompared": False,
        })
        proofs.append(proof)
        if on_pass:
            on_pass(proof, evidence)
        if not retained:
            raise ValueError(f"Independent reopen {ordinal} changed recovery materials: {json.dumps(difference, sort_keys=True)}")
    return proofs, evidence


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
              "status": "RUNNING", "scenarios": [], "recoveryMaterialChecks": {},
              "scope": "Actual Rust production; native Swift uses separate gates"}
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
                text = execute([str(bins["candidate"]), str(root), "resume"], repository, env,
                    output / (scenario+"-resume.log"), timeout=300)
                report["scenarios"].append(parse_report(text, "resume", release, scenario)); save()

                def record_reopen(proof, evidence):
                    report["scenarios"].append(proof)
                    report["recoveryMaterialChecks"][scenario] = evidence
                    save()

                _, evidence = run_candidate_reopens([str(bins["candidate"])], repository, root, scratch,
                    env, output, release, scenario, on_pass=record_reopen)
                report["recoveryMaterialChecks"][scenario] = evidence
                save()
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
