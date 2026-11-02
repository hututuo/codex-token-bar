import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import check_swift_formed_release_upgrade as probe

RELEASE = "0.9.8"
SHA = "b" * 40


def proof():
    return {"rowCount": 1, "rowsDigest": "c" * 64, "schemaDigest": "d" * 64,
            "tableCounts": {"events": 1}, "moduleUserVersion": 0}


def report(phase="resume", scenario="committed"):
    return {"status": "PASS", "phase": phase, "scenario": scenario, "producerVersion": RELEASE,
        "producerSha": probe.RELEASES[RELEASE], "candidateSha": SHA, "runtime": probe.RUNTIME,
        "totals": [173 if scenario == "committed" else 183, 310],
        "oldTypedProofsPreserved": True, "originalDatabasesUnchanged": True,
        "crashWALPreserved": True, "oldBPreserved": True, "rawDisappearanceRetainsHistory": True}


def output(value=None):
    return probe.MARKER + json.dumps(value or report()) + "\n" + \
        f"Test Case '-[CodexTokenBarTests.{probe.TEST_CLASS} {probe.TEST_METHOD}]' passed (0.1 seconds).\n"


def formed_state(root, scenario):
    originals = {}
    for relative in ["00-support/quota-history.sqlite", *("10-exact/" + letter * 64 + ".sqlite" for letter in "ab")]:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"synthetic harness contract bytes, not a native database")
        originals[relative] = {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "proof": proof()}
    value = {"producerVersion": RELEASE, "producerSha": probe.RELEASES[RELEASE], "runtime": probe.RUNTIME,
        "scenario": scenario, "completedImports": 3 if scenario == "committed" else 2,
        "totalInputs": 3, "formedTotals": [162 if scenario == "committed" else 155, 310],
        "formedStoreProofs": {str(number): proof() for number in range(3 if scenario == "committed" else 2)},
        "originalProofs": {"originals": originals, "bProof": proof()}}
    (root / "formed-state.json").write_text(json.dumps(value))
    name = "codex-ledger.sqlite" if scenario == "committed" else ".codex-ledger-migrating.sqlite"
    (root / "00-support" / (name + "-wal")).write_bytes(b"nonempty contract fixture")
    return value


class SwiftFormedHarnessTests(unittest.TestCase):
    def test_source_archive_injection_preserves_actual_git_production_blobs(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            repository = directory / "repository"
            repository.mkdir()
            files = {"Sources/Module/main.swift": "let preserved = 42\n", "Vendor/Library/source.c": "/* retained */\n",
                     "Package.swift": "// production package\n", "Package.resolved": "{}\n"}
            for relative, content in files.items():
                path = repository / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)
            (repository / "Tests/CodexTokenBarTests").mkdir(parents=True)
            (repository / "Tests/CodexTokenBarTests/Existing.swift").write_text("// existing test\n")
            template = repository / "scripts/fixtures/swift_formed_release_probe.swift"
            template.parent.mkdir(parents=True)
            template.write_bytes((ROOT / "scripts/fixtures/swift_formed_release_probe.swift").read_bytes())
            subprocess.run(["git", "init", "-q", str(repository)], check=True)
            subprocess.run(["git", "add", "."], cwd=repository, check=True)
            subprocess.run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                            "commit", "-qm", "isolated synthetic source"], cwd=repository, check=True)
            revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository, text=True).strip()
            archive = directory / "archive"
            evidence = probe.prepare_source(repository, revision, archive, "release", RELEASE)
            self.assertEqual(set(evidence["productionFilesUnchanged"]), set(files))
            for relative, content in files.items():
                self.assertEqual((archive / relative).read_text(), content)
            injected = (archive / probe.INJECTED_TEST).read_text()
            self.assertIn(revision, injected)
            self.assertNotIn("__TOKENBAR_SWIFT_FORMED_", injected)
            self.assertEqual(template.read_bytes(), (ROOT / "scripts/fixtures/swift_formed_release_probe.swift").read_bytes())
            (archive / "Sources/Module/main.swift").write_text("let changed = true\n")
            with self.assertRaisesRegex(ValueError, "Production archive changed"):
                probe.production_manifest(repository, revision, archive)
            with self.assertRaisesRegex(ValueError, "overwrite"):
                probe.prepare_source(repository, revision, archive, "release", RELEASE)

    def test_report_requires_real_xctest_completion_and_exact_source_identity(self):
        self.assertEqual(probe.parse_report(output(), "resume", "committed", RELEASE, SHA), report())
        for key, wrong in [("candidateSha", "c" * 40), ("producerSha", SHA), ("runtime", "rust"),
                           ("totals", [162, 310]), ("oldTypedProofsPreserved", 1), ("oldBPreserved", False)]:
            value = report(); value[key] = wrong
            with self.subTest(key=key), self.assertRaises(ValueError):
                probe.parse_report(output(value), "resume", "committed", RELEASE, SHA)
        for text in [probe.MARKER + json.dumps(report()), output().replace("passed", "skipped"),
                     output().replace("passed", "failed"), output() + output()]:
            with self.subTest(text=text), self.assertRaises(ValueError):
                probe.parse_report(text, "resume", "committed", RELEASE, SHA)

    def test_producer_requires_full_original_proofs_and_a_nonempty_crash_wal(self):
        for scenario in probe.SCENARIOS:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                expected = formed_state(root, scenario)
                self.assertEqual(probe.validate_producer(root, scenario, RELEASE), expected)
                name = "codex-ledger.sqlite" if scenario == "committed" else ".codex-ledger-migrating.sqlite"
                wal = root / "00-support" / (name + "-wal")
                wal.write_bytes(b"")
                with self.assertRaisesRegex(ValueError, "WAL"):
                    probe.validate_producer(root, scenario, RELEASE)

    def test_producer_rejects_changed_legacy_bytes_and_empty_namespace_proofs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            state = formed_state(root, "committed")
            (root / "00-support/quota-history.sqlite").write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "bytes"):
                probe.validate_producer(root, "committed", RELEASE)
            state = formed_state(root, "committed")
            state["formedStoreProofs"]["0"] = {}
            (root / "formed-state.json").write_text(json.dumps(state))
            with self.assertRaisesRegex(ValueError, "populated typed store proof"):
                probe.validate_producer(root, "committed", RELEASE)

    def test_child_environment_does_not_forward_credentials_or_application_overrides(self):
        with patch.dict(os.environ, {"HOME": "/unchanged/home", "GH_TOKEN": "must-not-forward",
             "SPARKLE_PRIVATE_KEY": "must-not-forward", "CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR": "/real/data"}, clear=False):
            env = probe.child_environment(Path("/tmp/owned-base"))
        self.assertEqual(env["HOME"], "/unchanged/home")
        self.assertEqual(env["TMPDIR"], "/tmp/owned-base")
        self.assertNotIn("GH_TOKEN", env)
        self.assertNotIn("SPARKLE_PRIVATE_KEY", env)
        self.assertNotIn("CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR", env)

    def test_late_released_append_requires_frozen_destination_and_preserved_original(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            formed = formed_state(root, "interrupted")
            relative = "10-exact/" + "a" * 64 + ".sqlite"
            original = root / relative
            backup = root / "pre-append-exact.sqlite"
            backup.write_bytes(original.read_bytes())
            original.write_bytes(b"new synthetic legacy observation")
            latest = formed["originalProofs"]
            latest["originals"][relative]["sha256"] = hashlib.sha256(original.read_bytes()).hexdigest()
            (root / "late-source-state.json").write_text(json.dumps({"latest": latest,
                "previousExactBackup": "pre-append-exact.sqlite"}))
            value = {"status": "PASS", "phase": "legacy-append", "scenario": "interrupted",
                "producerVersion": RELEASE, "producerSha": probe.RELEASES[RELEASE], "runtime": probe.RUNTIME,
                "totals": [172, 310], "frozenDestinationUnchanged": True, "oldTypedEventsPreserved": True,
                "previousOriginalPreserved": True}
            self.assertEqual(probe.validate_late_append(output(value), root, RELEASE), value)
            for key in ["frozenDestinationUnchanged", "oldTypedEventsPreserved", "previousOriginalPreserved"]:
                wrong = {**value, key: False}
                with self.subTest(key=key), self.assertRaises(ValueError):
                    probe.validate_late_append(output(wrong), root, RELEASE)
            backup.write_bytes(b"lost original")
            with self.assertRaisesRegex(ValueError, "not preserved"):
                probe.validate_late_append(output(value), root, RELEASE)

    def test_missing_or_ambiguous_native_bundle_is_not_a_skipped_pass(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            with self.assertRaises(ValueError):
                probe.test_bundle(source)
            one = source / ".build/arm64-apple-macosx/debug/CodexTokenBarPackageTests.xctest"
            one.mkdir(parents=True)
            self.assertEqual(probe.test_bundle(source), one.resolve())
            two = source / ".build/x86_64-apple-macosx/debug/CodexTokenBarPackageTests.xctest"
            two.mkdir(parents=True)
            with self.assertRaises(ValueError):
                probe.test_bundle(source)

    def test_non_macos_cannot_claim_native_execution(self):
        with patch.object(probe.sys, "platform", "linux"):
            with self.assertRaisesRegex(ValueError, "requires native macOS"):
                probe.run(ROOT, RELEASE, Path("never-created-swift-report"))

    def test_real_subprocess_exit_code_and_deadline_are_enforced(self):
        if os.name == "nt":
            self.skipTest("The Swift-only runner uses POSIX process groups")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            text = probe.execute([sys.executable, "-c", "print('owned child');raise SystemExit(86)"],
                                 root, os.environ.copy(), root / "child.log", expected=86, timeout=5)
            self.assertIn("owned child", text)
            with self.assertRaisesRegex(RuntimeError, "expected 86"):
                probe.execute([sys.executable, "-c", "raise SystemExit(1)"], root, os.environ.copy(),
                              root / "wrong-exit.log", expected=86, timeout=5)
            with self.assertRaisesRegex(RuntimeError, "deadline"):
                probe.execute([sys.executable, "-c", "import time;time.sleep(10)"], root, os.environ.copy(),
                              root / "timeout.log", timeout=0.05)

    def test_failed_producer_marks_both_phases_failed_and_archives_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            artifacts = directory / "artifacts"; artifacts.mkdir()
            bundles = {"release": directory / "old.xctest", "candidate": directory / "current.xctest"}
            with patch.object(probe, "execute", side_effect=RuntimeError("native producer failed")):
                results = probe.run_scenario(ROOT, RELEASE, "committed", directory / "committed",
                                             directory, bundles, artifacts, SHA)
            self.assertEqual([(item["phase"], item["status"]) for item in results], [("resume", "FAIL"), ("reopen", "FAIL")])
            self.assertTrue((artifacts / "committed-synthetic-state.zip").is_file())

    def test_failed_resume_still_runs_and_records_reopen(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            artifacts = directory / "artifacts"; artifacts.mkdir()
            fixture = directory / "committed"
            bundles = {"release": directory / "old.xctest", "candidate": directory / "current.xctest"}
            phases = []
            def execute(command, cwd, env, log, **kwargs):
                phase = env["TOKENBAR_SWIFT_FORMED_PHASE"]
                phases.append(phase)
                if phase == "produce":
                    formed_state(fixture, "committed")
                    return ""
                if phase == "resume":
                    raise RuntimeError("resume failed")
                return output(report("reopen"))
            with patch.object(probe, "execute", side_effect=execute):
                results = probe.run_scenario(ROOT, RELEASE, "committed", fixture, directory,
                                             bundles, artifacts, SHA)
            self.assertEqual(phases, ["produce", "resume", "reopen"])
            self.assertEqual([item["status"] for item in results], ["FAIL", "PASS"])
            self.assertTrue((artifacts / "committed-synthetic-state.zip").is_file())

    def test_missing_late_released_append_cannot_pass_interrupted_recovery(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            artifacts = directory / "artifacts"; artifacts.mkdir()
            fixture = directory / "interrupted"
            bundles = {"release": directory / "old.xctest", "candidate": directory / "current.xctest"}
            phases = []
            def execute(command, cwd, env, log, **kwargs):
                phase = env["TOKENBAR_SWIFT_FORMED_PHASE"]
                phases.append(phase)
                if phase == "produce":
                    formed_state(fixture, "interrupted")
                    return ""
                raise RuntimeError("old writer did not produce the required real append")
            with patch.object(probe, "execute", side_effect=execute):
                results = probe.run_scenario(ROOT, RELEASE, "interrupted", fixture, directory,
                                             bundles, artifacts, SHA)
            self.assertEqual(phases, ["produce", "legacy-append"])
            self.assertEqual([item["status"] for item in results], ["FAIL", "FAIL"])
            self.assertTrue((artifacts / "interrupted-synthetic-state.zip").is_file())


if __name__ == "__main__":
    unittest.main()
