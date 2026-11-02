#!/usr/bin/env python3
"""Form A/B using unchanged released Swift code, then restart the candidate.

macOS only. New XCTest files are injected into exact, isolated Git archives;
no production source or installed application directory is modified. Native
execution is required: missing builds, profiles or phases can never be PASS.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile

from check_formed_release_upgrade import (
    RELEASES, external_temporary_base, pinned_revision,
)
from prepare_v097_upgrade_validation import extract_revision

TEST_CLASS = "SwiftFormedReleaseProbeTests"
TEST_METHOD = "testRunIsolatedPhase"
SELECTOR = f"CodexTokenBarTests.{TEST_CLASS}/{TEST_METHOD}"
INJECTED_TEST = f"Tests/CodexTokenBarTests/{TEST_CLASS}.swift"
MARKER = "TOKENBAR_SWIFT_FORMED_REPORT "
RUNTIME = "native-swift-xctest-production-apis"
SCENARIOS = ("committed", "interrupted", "enriched")
PHASES = ("resume", "reopen")
NUMERIC_COLUMNS = ["source_id", "source_offset", "timestamp", "tokens", "input_tokens",
    "cached_input_tokens", "output_tokens", "reasoning_output_tokens", "accounting_kind", "reported_total_tokens", "legacy_tokens"]
RETAINED_COLUMNS = ["revision_id", "source_id", "session_id", "path", "signature", "parser_revision", "position", "timestamp",
    "tokens", "input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens", "model", "accounting_kind",
    "reported_total_tokens", "legacy_tokens", "user_prompt_start", "user_prompt_end", "assistant_response_start",
    "assistant_response_end", "token_source_offset"]


def collect_scenarios(operation, report: dict, save) -> None:
    """Swift has its own required matrix; Rust's two scenarios cannot satisfy it."""
    for scenario in SCENARIOS:
        try:
            report["scenarios"].extend(operation(scenario))
        except Exception as error:
            report["scenarios"].extend({"status": "FAIL", "scenario": scenario, "phase": phase,
                "error": str(error)} for phase in PHASES)
        save()
    expected = {(scenario, phase) for scenario in SCENARIOS for phase in PHASES}
    values = report["scenarios"]
    actual = [(item.get("scenario"), item.get("phase")) for item in values if isinstance(item, dict)]
    if len(values) != len(expected) or len(actual) != len(expected) or set(actual) != expected \
            or any(item.get("status") != "PASS" for item in values):
        raise ValueError("Every required Swift formed scenario and phase must actually pass")


def production_manifest(repository: Path, revision: str, source: Path) -> dict[str, str]:
    """Check Git blob identities, including manifest, resources and vendor code."""
    entries = subprocess.check_output(["git", "ls-tree", "-r", "-z", revision,
        "Sources", "Vendor", "Package.swift", "Package.resolved"], cwd=repository).split(b"\0")
    result = {}
    for entry in entries:
        if not entry:
            continue
        metadata, raw_path = entry.split(b"\t", 1)
        mode, kind, expected = metadata.decode().split()
        path = raw_path.decode()
        if kind != "blob" or mode not in {"100644", "100755"}:
            raise ValueError(f"Unsupported production archive member: {path}")
        target = source / path
        if target.is_symlink() or not target.is_file():
            raise ValueError(f"Missing or redirected production file: {path}")
        data = target.read_bytes()
        observed = hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()
        if observed != expected:
            raise ValueError(f"Production archive changed: {path}")
        result[path] = observed
    if not result or "Package.swift" not in result or "Package.resolved" not in result:
        raise ValueError("The production-source identity manifest is incomplete")
    return result


def prepare_source(repository: Path, revision: str, destination: Path, role: str, release: str) -> dict:
    if destination.exists():
        raise ValueError("Refusing to overwrite a source archive")
    if role not in {"release", "candidate"} or release not in RELEASES or not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Invalid pinned probe identity")
    extract_revision(repository, revision, destination)
    before = production_manifest(repository, revision, destination)
    target = destination / INJECTED_TEST
    if target.exists():
        raise ValueError("The injected probe path already exists in the archived revision")
    template = repository / "scripts/fixtures/swift_formed_release_probe.swift"
    text = template.read_text(encoding="utf-8")
    substitutions = {"__TOKENBAR_SWIFT_FORMED_SOURCE_SHA__": revision,
                     "__TOKENBAR_SWIFT_FORMED_ROLE__": role,
                     "__TOKENBAR_SWIFT_FORMED_RELEASE__": release}
    for marker, replacement in substitutions.items():
        if text.count(marker) != 1:
            raise ValueError("Probe template identity marker missing or duplicated")
        text = text.replace(marker, replacement)
    target.write_text(text, encoding="utf-8")
    if production_manifest(repository, revision, destination) != before:
        raise ValueError("Probe injection changed production files")
    return {"sourceSha": revision, "role": role, "release": release, "runtime": RUNTIME,
            "injection": INJECTED_TEST, "probeSha256": hashlib.sha256(text.encode()).hexdigest(),
            "productionFilesUnchanged": before}


def child_environment(base: Path) -> dict[str, str]:
    # xctest can include its environment in launcher errors. Do not pass
    # credentials or unrelated account/application overrides to a crash child.
    allowed = {"PATH", "HOME", "USER", "LOGNAME", "DEVELOPER_DIR", "SDKROOT", "SWIFT_EXEC",
               "LANG", "LC_ALL", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY",
               "SSL_CERT_FILE", "SSL_CERT_DIR", "GIT_SSL_CAINFO"}
    env = {key: value for key, value in os.environ.items() if key in allowed}
    env.update({key: str(base) for key in ["TMPDIR", "TMP", "TEMP"]})
    env["GIT_LFS_SKIP_SMUDGE"] = "1"
    return env


def execute(command: list[str], cwd: Path, env: dict, log: Path, *, expected: int = 0, timeout: int = 1800) -> str:
    with log.open("w", encoding="utf-8") as stream:
        child = subprocess.Popen(command, cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT,
                                 start_new_session=True)
        try:
            code = child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            # Kill only the process group created for this owned probe; cargo,
            # installed apps and unrelated test processes are never targeted.
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
            raise RuntimeError(f"Native process exceeded its {timeout}s deadline; see {log.name}")
    output = log.read_text(encoding="utf-8", errors="replace")
    if code != expected:
        raise RuntimeError(f"Process returned {code}, expected {expected}; see {log.name}\n{output[-6000:]}")
    return output


def test_bundle(source: Path) -> Path:
    candidates = {path.resolve() for pattern in ["*/debug/CodexTokenBarPackageTests.xctest", "debug/CodexTokenBarPackageTests.xctest"]
                  for path in (source / ".build").glob(pattern) if path.is_dir()}
    if len(candidates) != 1:
        raise ValueError(f"Expected one compiled native XCTest bundle, found {len(candidates)}")
    bundle = candidates.pop()
    if not bundle.is_relative_to((source / ".build").resolve()):
        raise ValueError("XCTest bundle escapes the owned source archive")
    return bundle


def verify_dependency(source: Path) -> dict:
    lock = json.loads((source / "Package.resolved").read_text())
    revision = next(item["state"]["revision"] for item in lock["pins"] if item["identity"] == "tiktokenswift")
    checkout = source / ".build/checkouts/TiktokenSwift"
    actual = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
    if actual != revision:
        raise ValueError("SwiftPM did not use the archived TiktokenSwift revision")
    package = (checkout / "Package.swift").read_text()
    frameworks = ["Sources/TiktokenFFI/TiktokenFFI.xcframework", "TiktokenFFI.xcframework"]
    framework = next((item for item in frameworks if f'path: "{item}"' in package), None)
    if framework is None:
        raise ValueError("Pinned Tiktoken framework path is unknown")
    relative = framework + "/macos-arm64_x86_64/TiktokenFFI.framework/TiktokenFFI"
    frozen = subprocess.check_output(["git", "-C", str(checkout), "show", f"{revision}:{relative}"])
    if frozen.startswith(b"version https://git-lfs.github.com/spec/v1\n"):
        fields = dict(line.split(" ", 1) for line in frozen.decode().splitlines())
        algorithm, expected = fields["oid"].split(":", 1)
        if algorithm != "sha256":
            raise ValueError("Unsupported pinned resource hash")
        size = int(fields["size"])
    else:
        expected, size = hashlib.sha256(frozen).hexdigest(), len(frozen)
    resource = (checkout / relative).read_bytes()
    if len(resource) != size or hashlib.sha256(resource).hexdigest() != expected:
        raise ValueError("Pinned native resource does not match its Git/LFS identity")
    return {"revision": revision, "resourceSha256": expected, "resourceBytes": size}


def native_report(output: str) -> dict:
    values = [json.loads(line.split(MARKER, 1)[1]) for line in output.splitlines() if MARKER in line]
    if len(values) != 1 or not isinstance(values[0], dict):
        raise ValueError("Expected one actual Swift production-API report")
    lines = [line for line in output.splitlines() if TEST_CLASS in line and TEST_METHOD in line]
    if not any("passed" in line for line in lines) or any(re.search(r"skipped|failed|XCTSkip", line, re.I) for line in lines):
        raise ValueError("A report without the entire named XCTest passing is not evidence")
    return values[0]


def parse_report(output: str, phase: str, scenario: str, release: str, candidate: str) -> dict:
    value = native_report(output)
    required = {"status": "PASS", "phase": phase, "scenario": scenario, "producerVersion": release,
        "producerSha": RELEASES[release], "candidateSha": candidate, "runtime": RUNTIME,
        "totals": [{"committed": 173, "interrupted": 183, "enriched": 166}[scenario], 310],
        "oldTypedProofsPreserved": True, "originalDatabasesUnchanged": True,
        "crashWALPreserved": True, "oldBPreserved": True, "rawDisappearanceRetainsHistory": True}
    if scenario == "enriched":
        required.update(nullModelAndTurnCompleted=True, originalVersionsRetained=True)
    for key, expected in required.items():
        if value.get(key) != expected or (type(expected) is bool and value.get(key) is not expected):
            raise ValueError(f"Invalid native proof {key}: {value.get(key)!r}")
    return value


def validate_store_proof(value: object) -> None:
    if not isinstance(value, dict) or type(value.get("rowCount")) is not int or value["rowCount"] <= 0:
        raise ValueError("A populated typed store proof is required")
    for key in ["schemaDigest", "rowsDigest"]:
        if not isinstance(value.get(key), str) or not re.fullmatch(r"[0-9a-f]{64}", value[key]):
            raise ValueError("Typed store digest is absent or invalid")
    counts = value.get("tableCounts")
    if not isinstance(counts, dict) or not counts or any(type(count) is not int or count < 0 for count in counts.values()):
        raise ValueError("Typed table counts are absent or invalid")
    if type(value.get("moduleUserVersion")) is not int or value["moduleUserVersion"] < 0:
        raise ValueError("Typed store version is absent or invalid")


def validate_originals(seed: dict, root: Path) -> None:
    validate_store_proof(seed.get("bProof"))
    originals = seed.get("originals", {})
    expected_paths = {"00-support/quota-history.sqlite", *("10-exact/" + letter * 64 + ".sqlite" for letter in "ab")}
    if set(originals) != expected_paths:
        raise ValueError("Released original database proofs are incomplete")
    for relative, proof in originals.items():
        validate_store_proof(proof.get("proof"))
        path = root / relative
        if path.is_symlink() or not path.resolve(strict=True).is_relative_to(root.resolve()):
            raise ValueError("Original database escaped the disposable fixture")
        if hashlib.sha256(path.read_bytes()).hexdigest() != proof.get("sha256"):
            raise ValueError("Released original database bytes do not match the recorded proof")


def validate_producer(root: Path, scenario: str, release: str) -> dict:
    value = json.loads((root / "formed-state.json").read_text())
    required = {"producerVersion": release, "producerSha": RELEASES[release], "runtime": RUNTIME,
        "scenario": scenario, "completedImports": 3 if scenario == "committed" else 2,
        "totalInputs": 3, "formedTotals": [162 if scenario == "committed" else 155, 310]}
    if any(value.get(key) != expected for key, expected in required.items()):
        raise ValueError("Released Swift process did not form the required historical state")
    count = 3 if scenario == "committed" else 2
    if not isinstance(value.get("formedStoreProofs"), dict) or len(value["formedStoreProofs"]) != count:
        raise ValueError("Released namespace proofs are absent or incomplete")
    for proof in value["formedStoreProofs"].values():
        validate_store_proof(proof)
    validate_originals(value.get("originalProofs", {}), root)
    name = "codex-ledger.sqlite" if scenario == "committed" else ".codex-ledger-migrating.sqlite"
    wal = root / "00-support" / (name + "-wal")
    if not wal.is_file() or wal.stat().st_size == 0:
        raise ValueError("The abrupt released process left no committed candidate WAL")
    return value


def validate_late_append(output: str, root: Path, release: str) -> dict:
    value = native_report(output)
    required = {"status": "PASS", "phase": "legacy-append", "scenario": "interrupted",
        "producerVersion": release, "producerSha": RELEASES[release], "runtime": RUNTIME,
        "totals": [172, 310], "frozenDestinationUnchanged": True, "oldTypedEventsPreserved": True,
        "previousOriginalPreserved": True}
    for key, expected in required.items():
        if value.get(key) != expected or (type(expected) is bool and value.get(key) is not expected):
            raise ValueError(f"Invalid released late-append proof {key}")
    late = json.loads((root / "late-source-state.json").read_text())
    if late.get("previousExactBackup") != "pre-append-exact.sqlite":
        raise ValueError("Invalid pre-append evidence path")
    validate_originals(late.get("latest", {}), root)
    previous = json.loads((root / "formed-state.json").read_text())["originalProofs"]["originals"]
    backup = root / "pre-append-exact.sqlite"
    expected_digest = previous["10-exact/" + "a" * 64 + ".sqlite"]["sha256"]
    if backup.is_symlink() or hashlib.sha256(backup.read_bytes()).hexdigest() != expected_digest:
        raise ValueError("Pre-append Exact original was not preserved")
    return value


def validate_table_image(value: object, *, rows: int, columns: list[str] | None = None) -> None:
    if not isinstance(value, dict) or not isinstance(value.get("columns"), list) \
            or not value["columns"] or any(not isinstance(name, str) or not name for name in value["columns"]) \
            or len(set(value["columns"])) != len(value["columns"]) \
            or (columns is not None and value["columns"] != columns) \
            or not isinstance(value.get("rows"), list) or len(value["rows"]) != rows:
        raise ValueError("Complete typed enrichment table evidence is required")
    for row in value["rows"]:
        if not isinstance(row, list) or len(row) != len(value["columns"]):
            raise ValueError("Incomplete typed enrichment row")
        for cell in row:
            if not isinstance(cell, str):
                raise ValueError("Typed enrichment cell is not encoded")
            data = base64.b64decode(cell, validate=True)
            if len(data) < 9 or data[0] not in range(1, 6) or int.from_bytes(data[1:9], "big") != len(data) - 9 \
                    or (data[0] in (1, 2) and len(data) != 17) or (data[0] == 5 and len(data) != 9):
                raise ValueError("Invalid canonical SQLite cell encoding")


def validate_late_enrichment(output: str, root: Path, release: str) -> dict:
    value = native_report(output)
    required = {"status": "PASS", "phase": "legacy-enrich", "scenario": "enriched",
        "producerVersion": release, "producerSha": RELEASES[release], "runtime": RUNTIME,
        "totals": [155, 310], "frozenDestinationUnchanged": True, "previousOriginalPreserved": True,
        "oldNumericRowsPreserved": True, "oldIdentityRowsPreserved": True,
        "nullModelAndTurnCompleted": True, "originalVersionsRetained": True}
    for key, expected in required.items():
        if value.get(key) != expected or (type(expected) is bool and value.get(key) is not expected):
            raise ValueError(f"Invalid released enrichment proof {key}")
    late = json.loads((root / "late-source-state.json").read_text())
    if late.get("previousExactBackup") != "pre-enrichment-exact.sqlite":
        raise ValueError("Invalid pre-enrichment database evidence path")
    validate_originals(late.get("latest", {}), root)
    before = json.loads((root / "formed-state.json").read_text())["originalProofs"]["originals"]
    backup = root / "pre-enrichment-exact.sqlite"
    expected_digest = before["10-exact/" + "a" * 64 + ".sqlite"]["sha256"]
    if backup.is_symlink() or hashlib.sha256(backup.read_bytes()).hexdigest() != expected_digest:
        raise ValueError("Pre-enrichment Exact original was not preserved")
    evidence = late.get("enrichment")
    if not isinstance(evidence, dict):
        raise ValueError("Released enrichment did not provide complete typed evidence")
    for key in ("numericBefore", "numericAfter"):
        validate_table_image(evidence.get(key), rows=2, columns=NUMERIC_COLUMNS)
    if evidence["numericBefore"] != evidence["numericAfter"]:
        raise ValueError("Released enrichment changed a historical typed numeric fact")
    validate_table_image(evidence.get("retainedVersions"), rows=2, columns=RETAINED_COLUMNS)
    retained = late["latest"]["originals"]["10-exact/" + "a" * 64 + ".sqlite"].get("tables", {}).get("retained_usage_revisions")
    if retained != evidence["retainedVersions"]:
        raise ValueError("Retained metadata versions do not match the actual released source image")
    raw_before = root / "pre-enrichment-rollout.jsonl"
    raw_after = root / "home-a/sessions/rollout-019ff8b9-09e7-75c1-b9a5-14fe7b60065a.jsonl"
    for path, key in [(raw_before, "rawBeforeSha256"), (raw_after, "rawAfterSha256")]:
        if path.is_symlink() or not path.resolve(strict=True).is_relative_to(root.resolve()) \
                or hashlib.sha256(path.read_bytes()).hexdigest() != evidence.get(key):
            raise ValueError("Enrichment raw representation is absent or changed")
    if evidence["rawBeforeSha256"] == evidence["rawAfterSha256"]:
        raise ValueError("The released metadata scenario did not exercise a real source rewrite")
    return value


def run_scenario(repository: Path, release: str, scenario: str, root: Path, base: Path,
                 bundles: dict[str, Path], output: Path, candidate: str) -> list[dict]:
    root.mkdir()
    (root / ".swift-formed-fixture").write_text("synthetic-swift-formed-v1\n")
    env = child_environment(base)
    env.update(TOKENBAR_SWIFT_FORMED_ROOT=str(root), TOKENBAR_SWIFT_FORMED_SCENARIO=scenario)
    results = []
    try:
        env["TOKENBAR_SWIFT_FORMED_PHASE"] = "produce"
        env["DYLD_FRAMEWORK_PATH"] = str(bundles["release"].parent)
        env["DYLD_LIBRARY_PATH"] = str(bundles["release"].parent)
        execute(["/usr/bin/xcrun", "xctest", "-XCTest", SELECTOR, str(bundles["release"])],
                repository, env, output / f"{scenario}-release.log", expected=86, timeout=300)
        validate_producer(root, scenario, release)
        shutil.copyfile(root / "formed-state.json", output / f"{scenario}-formed-state.json")
        if scenario == "interrupted":
            env["TOKENBAR_SWIFT_FORMED_PHASE"] = "legacy-append"
            log = execute(["/usr/bin/xcrun", "xctest", "-XCTest", SELECTOR, str(bundles["release"])],
                repository, env, output / "interrupted-late-released-append.log", timeout=300)
            late = validate_late_append(log, root, release)
            (output / "interrupted-late-append-report.json").write_text(json.dumps(late, indent=2) + "\n")
            shutil.copyfile(root / "late-source-state.json", output / "interrupted-late-source-state.json")
        elif scenario == "enriched":
            env["TOKENBAR_SWIFT_FORMED_PHASE"] = "legacy-enrich"
            log = execute(["/usr/bin/xcrun", "xctest", "-XCTest", SELECTOR, str(bundles["release"])],
                repository, env, output / "enriched-late-released-writer.log", timeout=300)
            late = validate_late_enrichment(log, root, release)
            (output / "enriched-late-writer-report.json").write_text(json.dumps(late, indent=2) + "\n")
            shutil.copyfile(root / "late-source-state.json", output / "enriched-late-source-state.json")
        for phase in PHASES:
            try:
                env["TOKENBAR_SWIFT_FORMED_PHASE"] = phase
                env["DYLD_FRAMEWORK_PATH"] = str(bundles["candidate"].parent)
                env["DYLD_LIBRARY_PATH"] = str(bundles["candidate"].parent)
                log = execute(["/usr/bin/xcrun", "xctest", "-XCTest", SELECTOR, str(bundles["candidate"])],
                    repository, env, output / f"{scenario}-{phase}.log", timeout=300)
                results.append(parse_report(log, phase, scenario, release, candidate))
            except Exception as error:
                results.append({"status": "FAIL", "scenario": scenario, "phase": phase, "error": str(error)})
    except Exception as error:
        results = [{"status": "FAIL", "scenario": scenario, "phase": phase,
                    "error": "Producer/preparation failed: " + str(error)} for phase in PHASES]
    finally:
        shutil.make_archive(str(output / f"{scenario}-synthetic-state"), "zip", root)
    return results


def run(repository: Path, release: str, output: Path) -> dict:
    if sys.platform != "darwin":
        raise ValueError("This gate requires native macOS Swift/XCTest; no substitute or skipped pass is supported")
    output.mkdir(parents=True, exist_ok=False)
    candidate = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository, text=True).strip()
    old = pinned_revision(repository, release)
    report = {"schemaVersion": 1, "release": release, "releaseSha": old, "candidateSha": candidate,
        "runtime": RUNTIME, "status": "RUNNING", "scenarios": [],
        "requiredScenarios": list(SCENARIOS), "requiredPhases": list(PHASES),
        "requiredLegacyPhases": {"interrupted": "legacy-append", "enriched": "legacy-enrich"},
        "scope": "Actual archived Swift production APIs under XCTest with synthetic A/B; not a signed/installed GUI or every incident variant"}
    def save():
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    save()
    try:
        explicit = os.environ.get("TOKENBAR_FIXTURE_TEMP_BASE")
        candidates = [Path(explicit)] if explicit else [Path(tempfile.gettempdir()), Path("/tmp")]
        base = external_temporary_base(candidates, Path.home())
        with tempfile.TemporaryDirectory(prefix="tokenbar-swift-formed-", dir=base) as temporary:
            scratch = Path(temporary).resolve()
            env = child_environment(base)
            execute(["swift", "--version"], repository, env, output / "swift-version.log", timeout=30)
            execute(["xcodebuild", "-version"], repository, env, output / "xcode-version.log", timeout=30)
            bundles = {}
            for role, revision in [("release", old), ("candidate", candidate)]:
                source = scratch / f"{role}-source"
                manifest = prepare_source(repository, revision, source, role, release)
                (output / f"{role}-source.json").write_text(json.dumps(manifest, indent=2) + "\n")
                execute(["bash", "scripts/prepare_tiktoken_lfs.sh"], source, env,
                        output / f"{role}-dependencies.log")
                dependency = verify_dependency(source)
                (output / f"{role}-dependency.json").write_text(json.dumps(dependency, indent=2) + "\n")
                execute(["swift", "build", "--build-tests", "--disable-automatic-resolution"], source, env,
                        output / f"{role}-build.log")
                if production_manifest(repository, revision, source) != manifest["productionFilesUnchanged"]:
                    raise ValueError("Production code or dependency pins changed while compiling the probe")
                bundles[role] = test_bundle(source)
            collect_scenarios(lambda scenario: run_scenario(repository, release, scenario,
                scratch / scenario, base, bundles, output, candidate), report, save)
        report["status"] = "PASS"
    except Exception as error:
        report.update(status="FAIL", error=str(error))
        raise
    finally:
        save()
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", choices=RELEASES, required=True)
    parser.add_argument("--output", type=Path, default=Path("swift-formed-state-evidence"))
    args = parser.parse_args()
    print(json.dumps(run(Path(__file__).resolve().parents[1], args.release, args.output.resolve()), sort_keys=True))


if __name__ == "__main__":
    main()
