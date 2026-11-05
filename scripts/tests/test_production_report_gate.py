"""Negative controls for report admission, independent of the Rust producer."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "cloud/run-business-store-fixture.py"
spec = importlib.util.spec_from_file_location("production_runner", SCRIPT)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

PHASES = ("initialize-before-commit", "chunk-committed", "seal-before-commit",
          "seal-committed", "publication-before-commit", "publication-committed",
          "cleanup-before-commit", "cleanup-committed")


def good_report():
    checks = json.loads((Path(__file__).parent / "fixtures/native-concurrent-probe-2344.json").read_text())["checks"]
    checks += [
        {"name": "bootstrap", "status": "PASS"},
        {"name": "public-read-only-routing", "status": "PASS", "startupReadRefused": True,
         "concurrentPublisherRead": True, "uncommittedValueHidden": True,
         "mainWriteRefused": True, "unknownPartitionNotRegistered": True},
        {"name": "quota", "status": "PASS", "activeRows": 1, "legacyFacts": [1, 2], "historyPoints": 720},
        {"name": "modeltrace", "status": "PASS", "runs": 2},
        {"name": "body-speed", "status": "PASS", "samples": 2, "trendPoints": 1,
         "outputTokens": 120, "durationSeconds": 10.0, "samplesInTrend": 2},
        {"name": "ledger-b", "status": "PASS", "rows": 1},
        {"name": "exact-import-stage-and-home-scope", "status": "PASS", "homeOneTokens": 175,
         "homeTwoTokens": 240, "stageObjectsBefore": 1, "stageObjectsAfter": 1},
        {"name": "runtime-recovery-production-path", "status": "PASS", "tokensAfterReplay": 175,
         **dict.fromkeys(("externalStateReadOnly", "invalidCandidateRejected", "legacyCheckpointMismatch",
                         "legacyStateColumnsReadWithoutImport", "liveStateRefreshed",
                         "namespaceCandidateResumed", "oldStagePreserved"), True),
         "fixedPool": {"catalogGrowth": 0, "storeGrowth": 0, "jobs": 13,
                       **dict.fromkeys(("idempotentCleanup", "publicationRollback", "readOnly", "typedTempAlias"), True),
                       "legacy": {"buildingKept": True, "changedEvidenceKept": True, "idempotent": True,
                                  "publishedTokens": 134, "rollback": True}},
         "steadyRetention": {"calls": 3, "reopens": 0, "freshOpenControl": 1, "samePaths": True},
         "lateRetention": {"coldReopens": 4, "repeatReopens": 0, "invalidManifestsRejected": 2,
                           **dict.fromkeys(("sameHandle", "isolatedPaths", "physicalEvidencePreserved",
                                           "accountingPreserved", "noFabricatedSuccessReceipt"), True)}},
        {"name": "legacy-backfill-indexed-reconciliation", "status": "PASS", "preservedEventIds": True,
         "legacyRows": 4096, "legacyCountCalls": 4096, "tokensAfterReplay": 20480,
         "rawLookupMaxVmSteps": 18, "identityCountMaxVmSteps": 21, "compactionIdentityMaxVmSteps": 62},
        {"name": "pool-process-crash-recovery", "status": "PASS", "phases": [
            {"phase": phase, "forcedExit": 86, "resumes": [
                {"status": "PASS", "phase": phase, "oldTokens": 123, "publishedTokens": 134,
                 "publicationReceipts": 1, "reclaimIdempotent": True, "repeatedStartupChecks": 3,
                 "alreadyRecovered": attempt > 0 or phase == "cleanup-committed"}
                for attempt in range(3)]} for phase in PHASES]},
        {"name": "published-recovery-reads", "status": "PASS", "oldAndNewFacts": [123, 789],
         "tokensWithoutRawSessions": 175, "aUnchanged": True, "retryReadOnly": True,
         "publishedCatalogEntries": 2, "catalogParserCalled": False, "catalogActionsVerified": False},
        {"name": "legacy-source-preservation", "status": "PASS", "count": 4},
        {"name": "held-owner-lookup", "status": "PASS", "discoveryLookups": 5,
         "persistLookups": 3, "perSourceReopens": 0, "freshOpenControl": 1},
        {"name": "rerun-and-fail-closed", "status": "PASS", "storeCount": 20},
    ]
    return {"status": "PASS", "checks": checks}


def check(report, name):
    return next(c for c in report["checks"] if c["name"] == name)


class ProductionReportGateTests(unittest.TestCase):
    def admit(self, report):
        runner.validate_production_report(report, False)

    def test_full_report_accepts_explicit_unverified_catalog_actions(self):
        # These false fields mean untested UI actions, not failed accounting.
        self.admit(good_report())

    def test_each_missing_duplicate_skipped_or_failed_check_is_rejected(self):
        original = good_report()
        for index, item in enumerate(original["checks"]):
            for mutation in ("missing", "duplicate", "skipped", "failed"):
                invalid = copy.deepcopy(original)
                if mutation == "missing":
                    invalid["checks"].pop(index)
                elif mutation == "duplicate":
                    invalid["checks"].append(copy.deepcopy(item))
                else:
                    invalid["checks"][index]["status"] = mutation.upper()
                with self.subTest(check=item["name"], mutation=mutation), self.assertRaises(ValueError):
                    self.admit(invalid)

    def test_parent_success_cannot_override_corruption_or_false_proofs(self):
        cases = [
            ("public-read-only-routing", "mainWriteRefused", False),
            ("public-read-only-routing", "unknownPartitionNotRegistered", 1),
            ("quota", "legacyFacts", [1, 1]),
            ("ledger-b", "rows", True),
            ("exact-import-stage-and-home-scope", "homeTwoTokens", 175),
            ("runtime-recovery-production-path", "oldStagePreserved", False),
            ("runtime-recovery-production-path", "fixedPool", {}),
            ("legacy-backfill-indexed-reconciliation", "preservedEventIds", False),
            ("published-recovery-reads", "oldAndNewFacts", [123, 123]),
            ("published-recovery-reads", "retryReadOnly", False),
            ("legacy-source-preservation", "count", 0),
        ]
        for name, field, value in cases:
            report = good_report()
            check(report, name)[field] = value
            with self.subTest(check=name, field=field), self.assertRaises(ValueError):
                self.admit(report)

    def test_all_crash_phases_and_three_real_reopens_are_required(self):
        for mutation in ("missing-phase", "duplicate-phase", "wrong-exit", "missing-reopen",
                         "skipped-reopen", "double-accounting", "missing-old", "no-restart", "not-idempotent"):
            report = good_report()
            phases = check(report, "pool-process-crash-recovery")["phases"]
            if mutation == "missing-phase": phases.pop()
            elif mutation == "duplicate-phase": phases[-1] = copy.deepcopy(phases[0])
            elif mutation == "wrong-exit": phases[0]["forcedExit"] = 0
            elif mutation == "missing-reopen": phases[0]["resumes"].pop()
            else:
                field, value = {"skipped-reopen": ("status", "SKIP"), "double-accounting": ("publishedTokens", 268),
                                "missing-old": ("oldTokens", 0), "no-restart": ("repeatedStartupChecks", 0),
                                "not-idempotent": ("reclaimIdempotent", False)}[mutation]
                phases[0]["resumes"][1][field] = value
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                self.admit(report)

    def test_owner_lookup_gate_requires_both_real_paths_and_a_working_open_counter(self):
        for field, values in {
            "discoveryLookups": [0, -1, None, True],
            "persistLookups": [0, -1, None, True],
            "perSourceReopens": [1, None, False],
            "freshOpenControl": [0, None, True],
        }.items():
            for value in values:
                report = good_report()
                check(report, "held-owner-lookup")[field] = value
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    self.admit(report)

    def test_existing_query_work_budgets_and_core_witnesses_are_required(self):
        for field in ("rawLookupMaxVmSteps", "identityCountMaxVmSteps", "compactionIdentityMaxVmSteps"):
            for value in (None, 0, -1, True, 18.0, 513):
                report = good_report()
                check(report, "legacy-backfill-indexed-reconciliation")[field] = value
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    self.admit(report)
        for name, field, value in (
            ("published-recovery-reads", "catalogParserCalled", True),
            ("published-recovery-reads", "catalogActionsVerified", True),
            ("published-recovery-reads", "publishedCatalogEntries", 0),
            ("quota", "historyPoints", 0), ("rerun-and-fail-closed", "storeCount", True),
            ("concurrent-a-write-probe", "timeoutMilliseconds", 250.0),
            ("concurrent-a-write-probe", "parallelProbeRows", 4.0),
            ("body-speed", "outputTokens", 119),
            ("body-speed", "durationSeconds", 9.0), ("body-speed", "samplesInTrend", 1),
        ):
            report = good_report()
            check(report, name)[field] = value
            with self.subTest(name=name, field=field), self.assertRaises(ValueError):
                self.admit(report)
        for index in range(len(PHASES)):
            report = good_report()
            first = check(report, "pool-process-crash-recovery")["phases"][index]["resumes"][0]
            first["alreadyRecovered"] = not first["alreadyRecovered"]
            with self.subTest(phase=PHASES[index]), self.assertRaises(ValueError):
                self.admit(report)

    def test_retention_requires_executed_cold_control_and_preservation_proofs(self):
        valid = good_report()
        self.admit(valid)
        proof = check(valid, "runtime-recovery-production-path")
        for section in ("steadyRetention", "lateRetention"):
            for field, expected in proof[section].items():
                for mutation in ("missing", "wrong-type", "wrong-value"):
                    invalid = copy.deepcopy(valid)
                    target = check(invalid, "runtime-recovery-production-path")[section]
                    if mutation == "missing": del target[field]
                    elif mutation == "wrong-type": target[field] = 1 if type(expected) is bool else True
                    else: target[field] = (not expected if type(expected) is bool
                        else 0 if field == "coldReopens" else expected + 1)
                    with self.subTest(section=section, field=field, mutation=mutation), self.assertRaises(ValueError):
                        self.admit(invalid)
        for section in ("steadyRetention", "lateRetention"):
            invalid = copy.deepcopy(valid)
            del check(invalid, "runtime-recovery-production-path")[section]
            with self.subTest(section=section), self.assertRaises(ValueError):
                self.admit(invalid)

    def test_malformed_report_and_unexpected_scale_are_rejected(self):
        for report in (None, [], {}, {"status": "PASS", "checks": []},
                       {"status": "PASS", "checks": [None]}):
            with self.subTest(report=report), self.assertRaises(ValueError):
                self.admit(report)
        report = good_report()
        report["checks"].append({"name": "unexpected-pass", "status": "PASS"})
        with self.assertRaises(ValueError): self.admit(report)

    def test_rejection_retains_raw_output_and_explicit_failure_without_pass_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            output = root / "report.json"
            invalid = good_report()
            invalid["checks"] = invalid["checks"][:2]
            raw = json.dumps(invalid)
            args = SimpleNamespace(binary=root / "fake", output=output)
            with patch.object(runner.argparse.ArgumentParser, "parse_args", return_value=args), \
                 patch.dict(runner.os.environ, {"GITHUB_ACTIONS": "true", "RUNNER_TEMP": str(root)}), \
                 patch.object(runner.tempfile, "gettempdir", return_value=str(root)), \
                 patch.object(runner.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, raw, "")), \
                 patch("builtins.print"):
                with self.assertRaises(SystemExit): runner.main()
            self.assertFalse(output.exists(), "Rejected evidence must not survive as top-level PASS")
            self.assertIn(raw, output.with_suffix(".log").read_text())
            decision = json.loads(output.with_suffix(".validation.json").read_text())
            self.assertEqual(decision["status"], "FAIL")
            self.assertEqual(decision["producerExitCode"], 0)
            self.assertIn("missing", decision["error"].lower())

    def test_existing_output_is_refused_before_starting_a_new_fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for suffix in (".json", ".log", ".validation.json"):
                output = root / "report.json"
                existing = output.with_suffix(suffix)
                existing.write_text("prior evidence")
                args = SimpleNamespace(binary=root / "fake", output=output)
                with patch.object(runner.argparse.ArgumentParser, "parse_args", return_value=args), \
                     patch.dict(runner.os.environ, {"GITHUB_ACTIONS": "true"}), \
                     patch.object(runner.subprocess, "run") as child:
                    with self.assertRaises(SystemExit): runner.main()
                    child.assert_not_called()
                self.assertEqual(existing.read_text(), "prior evidence")
                existing.unlink()

    def test_main_accepts_only_valid_report_and_successful_process_together(self):
        for raw, code, accepted in ((json.dumps(good_report()), 0, True),
                                    (json.dumps(good_report()), 7, False), ("{truncated", 0, False)):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                output = root / "report.json"
                args = SimpleNamespace(binary=root / "fake", output=output)
                with patch.object(runner.argparse.ArgumentParser, "parse_args", return_value=args), \
                     patch.dict(runner.os.environ, {"GITHUB_ACTIONS": "true", "RUNNER_TEMP": str(root)}), \
                     patch.object(runner.tempfile, "gettempdir", return_value=str(root)), \
                     patch.object(runner.subprocess, "run", return_value=subprocess.CompletedProcess([], code, raw, "")), \
                     patch("builtins.print"):
                    if accepted: runner.main()
                    else:
                        with self.assertRaises(SystemExit): runner.main()
                self.assertEqual(output.exists(), accepted)
                decision = json.loads(output.with_suffix(".validation.json").read_text())
                self.assertEqual(decision["status"], "PASS" if accepted else "FAIL")
                self.assertEqual(decision["producerExitCode"], code)
                self.assertIn(raw, output.with_suffix(".log").read_text())


if __name__ == "__main__":
    unittest.main()
