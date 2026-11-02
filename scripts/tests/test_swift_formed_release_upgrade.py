import base64
import copy
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
        "totals": [{"committed": 173, "interrupted": 183, "enriched": 166}[scenario], 310],
        "oldTypedProofsPreserved": True, "originalDatabasesUnchanged": True,
        "crashWALPreserved": True, "oldBPreserved": True, "rawDisappearanceRetainsHistory": True,
        **({key: True for key in probe.ENRICHED_PROOFS} if scenario == "enriched" else {})}


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


def enrichment_state(root):
    """Contract-only fake bytes; this helper cannot supply a native test PASS."""
    formed = formed_state(root, "enriched")
    relative = "10-exact/" + "a" * 64 + ".sqlite"
    original = root / relative
    (root / "pre-enrichment-exact.sqlite").write_bytes(original.read_bytes())
    original.write_bytes(b"new synthetic enrichment contract bytes")
    latest = copy.deepcopy(formed["originalProofs"])
    latest["originals"][relative]["sha256"] = hashlib.sha256(original.read_bytes()).hexdigest()
    null = base64.b64encode(bytes([5]) + bytes(8)).decode()
    def integer(number):
        return base64.b64encode(bytes([1]) + (8).to_bytes(8, "big") + number.to_bytes(8, "big")).decode()
    def text(value):
        data = value.encode()
        return base64.b64encode(bytes([3]) + len(data).to_bytes(8, "big") + data).decode()
    one = integer(1)
    g1, g2 = text("00000000-0000-4000-8000-000000000001"), text("00000000-0000-4000-8000-000000000002")
    numeric = {"columns": probe.NUMERIC_COLUMNS, "rows": [[one] * len(probe.NUMERIC_COLUMNS) for _ in range(2)]}
    retained = {"columns": probe.RETAINED_COLUMNS, "rows": [[null] * len(probe.RETAINED_COLUMNS) for _ in range(2)]}
    events = {"columns": probe.EVENT_COLUMNS, "rows": [[one] * len(probe.EVENT_COLUMNS) for _ in range(2)]}
    first_turn = [one, g1, integer(0), integer(99)]
    second_turn = [one, g2, integer(1), integer(99)]
    first_bindings = {"columns": probe.BINDING_COLUMNS, "rows": [[one, integer(i), g1, integer(i+100), integer(0), integer(50), one] for i in (1, 2)]}
    second_bindings = {"columns": probe.BINDING_COLUMNS, "rows": [[one, integer(i), g2, integer(i+101), integer(1), integer(51), one] for i in (1, 2)]}
    first_tables = {"events": events, "retained_usage_revisions": retained, "usage_ledger_bindings": first_bindings,
        "usage_ledger_turns": {"columns": probe.TURN_COLUMNS, "rows": [first_turn]}}
    latest_tables = {"events": events, "retained_usage_revisions": retained, "usage_ledger_bindings": second_bindings,
        "usage_ledger_turns": {"columns": probe.TURN_COLUMNS, "rows": [first_turn, second_turn]}}
    latest["originals"][relative]["tables"] = latest_tables
    before = root / "pre-enrichment-rollout.jsonl"
    intermediate_raw = root / "intermediate-enrichment-rollout.jsonl"
    after = root / "post-enrichment-rollout.jsonl"
    before.write_bytes(b"old raw contract fixture")
    intermediate_raw.write_bytes(b"first rewrite prefix\n" + before.read_bytes())
    after.write_bytes(b"second rewrite prefix\n" + intermediate_raw.read_bytes())
    b_raw = root / "pre-upgrade-b-rollout.jsonl"; b_raw.write_bytes(b"source B raw contract fixture")
    intermediate_db = root / "intermediate-enrichment-exact.sqlite"
    intermediate_db.write_bytes(b"intermediate synthetic contract database")
    value = {"latest": latest, "previousExactBackup": "pre-enrichment-exact.sqlite", "enrichment": {
        "numericBefore": numeric, "numericAfter": copy.deepcopy(numeric), "retainedVersions": retained,
        "rawBeforeSha256": hashlib.sha256(before.read_bytes()).hexdigest(),
        "rawIntermediateSha256": hashlib.sha256(intermediate_raw.read_bytes()).hexdigest(),
        "rawAfterSha256": hashlib.sha256(after.read_bytes()).hexdigest(),
        "rawBSha256": hashlib.sha256(b_raw.read_bytes()).hexdigest(), "rawMissingBeforeMigration": True,
        "intermediate": {"sha256": hashlib.sha256(intermediate_db.read_bytes()).hexdigest(),
            "proof": proof(), "tables": first_tables}}}
    (root / "late-source-state.json").write_text(json.dumps(value))
    return value


def enrichment_report():
    return {"status": "PASS", "phase": "legacy-enrich", "scenario": "enriched",
        "producerVersion": RELEASE, "producerSha": probe.RELEASES[RELEASE], "runtime": probe.RUNTIME,
        "totals": [155, 310], "frozenDestinationUnchanged": True, "previousOriginalPreserved": True,
        "oldNumericRowsPreserved": True, "oldIdentityRowsPreserved": True,
        "nullModelAndTurnCompleted": True, "originalVersionsRetained": True,
        "repeatedMetadataGenerationsPreserved": True, "rawMissingBeforeMigration": True}


class SwiftFormedHarnessTests(unittest.TestCase):
    def test_all_three_scenarios_and_both_candidate_processes_are_required(self):
        expected = {(scenario, phase) for scenario in probe.SCENARIOS for phase in probe.PHASES}
        self.assertEqual(len(expected), 6)
        saved = []
        evidence = {"scenarios": []}
        probe.collect_scenarios(lambda scenario: [report(phase, scenario) for phase in probe.PHASES],
                                evidence, lambda: saved.append(len(evidence["scenarios"])))
        self.assertEqual(saved, [2, 4, 6])
        self.assertEqual({(item["scenario"], item["phase"]) for item in evidence["scenarios"]}, expected)
        for bad in ([], [report("resume", "enriched")] * 2,
                    [{**report(phase, "enriched"), "status": "SKIP"} for phase in probe.PHASES]):
            attempted = []
            def run(scenario):
                attempted.append(scenario)
                return bad if scenario == "enriched" else [report(phase, scenario) for phase in probe.PHASES]
            with self.subTest(bad=bad), self.assertRaisesRegex(ValueError, "Every required Swift"):
                probe.collect_scenarios(run, {"scenarios": []}, lambda: None)
            self.assertEqual(attempted, list(probe.SCENARIOS))

    def test_enriched_candidate_report_cannot_reuse_the_append_or_total_only_result(self):
        value = report("resume", "enriched")
        self.assertEqual(probe.parse_report(output(value), "resume", "enriched", RELEASE, SHA), value)
        for key, wrong in [("totals", [183, 310]), ("nullModelAndTurnCompleted", False),
                           ("originalVersionsRetained", None), ("originalVersionsRetained", 1)]:
            invalid = {**value, key: wrong}
            with self.subTest(key=key), self.assertRaises(ValueError):
                probe.parse_report(output(invalid), "resume", "enriched", RELEASE, SHA)

    def test_every_enriched_candidate_proof_must_be_boolean_true(self):
        for key in probe.ENRICHED_PROOFS:
            for wrong in ("missing", False, None, 0, 1, "true"):
                value = report("resume", "enriched")
                if wrong == "missing": value.pop(key)
                else: value[key] = wrong
                with self.subTest(key=key, wrong=wrong), self.assertRaises(ValueError):
                    probe.parse_report(output(value), "resume", "enriched", RELEASE, SHA)

    def test_released_enrichment_requires_retained_full_typed_images_and_real_raw_rewrite(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            state = enrichment_state(root)
            value = enrichment_report()
            self.assertEqual(probe.validate_late_enrichment(output(value), root, RELEASE), value)
            for key in ("oldNumericRowsPreserved", "oldIdentityRowsPreserved", "nullModelAndTurnCompleted",
                        "originalVersionsRetained", "frozenDestinationUnchanged", "previousOriginalPreserved",
                        "repeatedMetadataGenerationsPreserved", "rawMissingBeforeMigration"):
                with self.subTest(key=key), self.assertRaises(ValueError):
                    probe.validate_late_enrichment(output({**value, key: False}), root, RELEASE)
            for change in ("missing", "numeric", "cell", "retention", "raw"):
                invalid = copy.deepcopy(state)
                if change == "missing":
                    del invalid["enrichment"]
                elif change == "numeric":
                    invalid["enrichment"]["numericAfter"]["rows"][0][0] = base64.b64encode(bytes([5]) + bytes(8)).decode()
                elif change == "cell":
                    invalid["enrichment"]["numericBefore"]["rows"][0][0] = "not a typed cell"
                elif change == "retention":
                    invalid["enrichment"]["retainedVersions"]["columns"] = ["total_only"]
                else:
                    invalid["enrichment"]["rawBeforeSha256"] = invalid["enrichment"]["rawAfterSha256"]
                (root / "late-source-state.json").write_text(json.dumps(invalid))
                with self.subTest(change=change), self.assertRaises(ValueError):
                    probe.validate_late_enrichment(output(value), root, RELEASE)
            (root / "late-source-state.json").write_text(json.dumps(state))
            (root / "pre-enrichment-exact.sqlite").write_bytes(b"lost original")
            with self.assertRaisesRegex(ValueError, "not preserved"):
                probe.validate_late_enrichment(output(value), root, RELEASE)

    def test_repeated_enrichment_requires_intermediate_history_and_pre_upgrade_raw_absence(self):
        for change in ("missing-intermediate", "lost-g1-events", "lost-g1-turn", "unchanged-binding", "same-generation",
                       "different-turn", "missing-flag", "raw-present", "bad-intermediate-db", "bad-raw-copy"):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                state = enrichment_state(root)
                value = enrichment_report()
                self.assertEqual(probe.validate_late_enrichment(output(value), root, RELEASE), value)
                evidence = state["enrichment"]
                latest = state["latest"]["originals"]["10-exact/" + "a" * 64 + ".sqlite"]["tables"]
                if change == "missing-intermediate": evidence.pop("intermediate")
                elif change == "lost-g1-events": latest["events"] = {"columns": probe.EVENT_COLUMNS, "rows": []}
                elif change == "lost-g1-turn": latest["usage_ledger_turns"]["rows"].pop(0)
                elif change == "unchanged-binding": latest["usage_ledger_bindings"] = copy.deepcopy(evidence["intermediate"]["tables"]["usage_ledger_bindings"])
                elif change == "same-generation": latest["usage_ledger_turns"]["rows"][1][1] = latest["usage_ledger_turns"]["rows"][0][1]
                elif change == "different-turn": latest["usage_ledger_turns"]["rows"][1][3] = latest["usage_ledger_turns"]["rows"][1][0]
                elif change == "missing-flag": evidence["rawMissingBeforeMigration"] = 1
                elif change == "raw-present":
                    path = root / "home-a/sessions/rollout-019ff8b9-09e7-75c1-b9a5-14fe7b60065a.jsonl"
                    path.parent.mkdir(parents=True); path.write_bytes(b"raw is still present")
                elif change == "bad-intermediate-db": (root / "intermediate-enrichment-exact.sqlite").write_bytes(b"changed")
                else: (root / "post-enrichment-rollout.jsonl").write_bytes(b"changed")
                (root / "late-source-state.json").write_text(json.dumps(state))
                with self.assertRaises(ValueError):
                    probe.validate_late_enrichment(output(value), root, RELEASE)

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

    def test_missing_released_enrichment_blocks_both_candidate_phases(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            artifacts = directory / "artifacts"; artifacts.mkdir()
            fixture = directory / "enriched"
            bundles = {"release": directory / "old.xctest", "candidate": directory / "current.xctest"}
            phases = []
            def execute(command, cwd, env, log, **kwargs):
                phase = env["TOKENBAR_SWIFT_FORMED_PHASE"]
                phases.append(phase)
                if phase == "produce":
                    formed_state(fixture, "enriched")
                    return ""
                raise RuntimeError("old writer failed to form actual enrichment")
            with patch.object(probe, "execute", side_effect=execute):
                results = probe.run_scenario(ROOT, RELEASE, "enriched", fixture, directory,
                                             bundles, artifacts, SHA)
            self.assertEqual(phases, ["produce", "legacy-enrich"])
            self.assertEqual([item["status"] for item in results], ["FAIL", "FAIL"])
            self.assertTrue((artifacts / "enriched-synthetic-state.zip").is_file())


if __name__ == "__main__":
    unittest.main()
