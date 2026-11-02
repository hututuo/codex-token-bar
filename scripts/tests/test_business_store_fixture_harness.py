import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "business_store_fixture_harness", Path(__file__).resolve().parents[1] / "check_business_store_fixture.py")
fixture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixture)


SCENARIO_NAMES = (
    "bootstrap", "quota", "modeltrace", "body-speed", "ledger-b",
    "exact-import-stage-and-home-scope", "live-external-state-readers",
    "legacy-source-preservation", "rerun-and-fail-closed", "bounded-stage-replacement",
    "public-read-only-routing", "runtime-recovery-production-path",
    "legacy-backfill-indexed-reconciliation",
)
BOOTSTRAP_PROOFS = (
    "incompleteExactDiscoveryFrozen", "incompleteExactSnapshotUnchanged",
    "independentPendingImportRecovered", "completeDiscoveryResumesExactHistory",
    "recoveryRetryPreservesHistory",
)
STARTUP_PROOFS = (
    "startupNamespaceOnlyIdentity", "startupLastGoodRestored", "startupConcurrentPublisherRead",
    "startupLegacySourceUnchanged", "startupLegacyNotImported", "startupSqliteWriteRefused",
)
STAGE_PROOFS = (
    "retainedStageContentVerified", "changedStageImportRejected",
    "stageMutationBeforePublicationRejected",
    "sealedStageMissingSealRejected", "resealedStageImportRejected",
    "stageSchemaMutationRejected", "stageSchemaMutationBeforePublicationRejected",
    "unsealedStageRebuiltFromSource", "pendingHistoryOverwriteRejected",
    "unsealedPreservationMutationRejected",
    "missingSourcePendingHistoryPublished",
)


def complete_native_report():
    checks = {name: {"name": name, "status": "PASS"} for name in SCENARIO_NAMES}
    checks["bootstrap"].update({field: True for field in BOOTSTRAP_PROOFS})
    checks["quota"].update(retainedReaderRows=3, uniqueRetainedRows=2, oldCycleSchema=True)
    checks["runtime-recovery-production-path"].update({
        field: True for field in (*STARTUP_PROOFS, *STAGE_PROOFS)
    })
    return {"status": "PASS", "checks": list(checks.values()),
            "concurrentWriterProbeEnabled": True, "concurrentWriteAssertions": 10}


def scenario(report, name):
    return next(item for item in report["checks"] if item["name"] == name)


class ProductionFixtureEvidenceTests(unittest.TestCase):
    def run_main_with_report(self, native, *, succeeds):
        """Exercise stdout decoding and publication, with only native execution stubbed."""
        with tempfile.TemporaryDirectory(prefix="tokenbar-reader-policy-", dir=os.environ.get("RUNNER_TEMP")) as temp:
            root = Path(temp) / "repository"
            (root / "scripts").mkdir(parents=True)
            report_path = root / "native-production-readers.json"
            report_path.write_text(json.dumps({"status": "PASS", "source_sha": "old"}))

            def git(command, **_):
                return "c" * 40 if command[1] == "rev-parse" else ""

            with patch.object(fixture, "__file__", str(root / "scripts/check_business_store_fixture.py")), \
                 patch.object(fixture.subprocess, "check_output", side_effect=git), \
                 patch.object(fixture, "execute_native", return_value=SimpleNamespace(
                     returncode=0, stdout=json.dumps(native), stderr="native probe output\n")) as run, \
                 patch.dict(os.environ, {"RUNNER_TEMP": temp}), patch("builtins.print"):
                if succeeds:
                    fixture.main()
                else:
                    with self.assertRaises(SystemExit):
                        fixture.main()
                run.assert_called_once()
            report = json.loads(report_path.read_text())
            self.assertEqual(report["status"], "PASS" if succeeds else "FAIL")
            self.assertEqual(report["source_sha"], "c" * 40)
            self.assertFalse(report["working_tree_dirty"])
            self.assertIs(report["cfg_test"], False)
            self.assertIn("native probe output", (root / "native-production-readers.log").read_text())
            return report

    def test_complete_production_evidence_is_published(self):
        report = self.run_main_with_report(complete_native_report(), succeeds=True)
        self.assertEqual(len(report["checks"]), 13)
        self.assertEqual({item["name"] for item in report["checks"]}, set(SCENARIO_NAMES))
        for field in STAGE_PROOFS:
            self.assertIs(scenario(report, "runtime-recovery-production-path")[field], True)

    def test_complete_manifest_policy_proof_is_required_before_publishing_pass(self):
        for field in BOOTSTRAP_PROOFS:
            for value in ("missing", False):
                with self.subTest(field=field, value=value):
                    native = complete_native_report()
                    bootstrap = scenario(native, "bootstrap")
                    if value == "missing":
                        del bootstrap[field]
                    else:
                        bootstrap[field] = value
                    self.run_main_with_report(native, succeeds=False)

    def test_every_startup_recovery_proof_remains_required(self):
        for field in STARTUP_PROOFS:
            for value in ("missing", False):
                with self.subTest(field=field, value=value):
                    native = complete_native_report()
                    runtime = scenario(native, "runtime-recovery-production-path")
                    if value == "missing":
                        del runtime[field]
                    else:
                        runtime[field] = value
                    self.run_main_with_report(native, succeeds=False)

    def test_each_retained_stage_proof_must_be_explicit_boolean_true(self):
        for field in STAGE_PROOFS:
            for value in ("missing", False, None, 0, 1, "true"):
                with self.subTest(field=field, value=value):
                    native = complete_native_report()
                    runtime = scenario(native, "runtime-recovery-production-path")
                    if value == "missing":
                        del runtime[field]
                    else:
                        runtime[field] = value
                    self.run_main_with_report(native, succeeds=False)

    def test_later_duplicate_pass_cannot_hide_a_failed_scenario(self):
        for name in SCENARIO_NAMES:
            with self.subTest(name=name):
                native = complete_native_report()
                native["checks"].insert(0, {"name": name, "status": "FAIL"})
                self.run_main_with_report(native, succeeds=False)

    def test_only_thirteen_unique_expected_scenarios_are_accepted(self):
        for mode in ("missing", "extra", "duplicate", "unknown", "wrong-list-type", "bad-item", "bad-name"):
            with self.subTest(mode=mode):
                native = complete_native_report()
                if mode == "missing":
                    native["checks"].pop()
                elif mode == "extra":
                    native["checks"].append({"name": "unexpected", "status": "PASS"})
                elif mode == "duplicate":
                    native["checks"][-1] = dict(native["checks"][0])
                elif mode == "unknown":
                    native["checks"][-1]["name"] = "unexpected"
                elif mode == "wrong-list-type":
                    native["checks"] = {item["name"]: item for item in native["checks"]}
                elif mode == "bad-item":
                    native["checks"][-1] = None
                else:
                    native["checks"][-1]["name"] = ["unhashable"]
                self.run_main_with_report(native, succeeds=False)

    def test_each_scenario_must_pass(self):
        for name in SCENARIO_NAMES:
            with self.subTest(name=name):
                native = complete_native_report()
                scenario(native, name)["status"] = "FAIL"
                self.run_main_with_report(native, succeeds=False)

    def test_concurrent_writer_and_quota_requirements_remain_enforced(self):
        for field, value in (("concurrentWriterProbeEnabled", False), ("concurrentWriteAssertions", 0)):
            with self.subTest(field=field):
                native = complete_native_report()
                native[field] = value
                self.run_main_with_report(native, succeeds=False)
        for field, value in (("retainedReaderRows", 2), ("uniqueRetainedRows", 3), ("oldCycleSchema", False)):
            with self.subTest(field=field):
                native = complete_native_report()
                scenario(native, "quota")[field] = value
                self.run_main_with_report(native, succeeds=False)

    def test_failure_or_incomplete_rerun_cannot_reuse_a_previous_pass(self):
        for mode in ("timeout", "incomplete"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(prefix="tokenbar-reader-harness-", dir=os.environ.get("RUNNER_TEMP")) as temp:
                root = Path(temp) / "repository"
                (root / "scripts").mkdir(parents=True)
                report_path = root / "native-production-readers.json"
                report_path.write_text(json.dumps({"status": "PASS", "source_sha": "old"}))

                def git(command, **_):
                    return "b" * 40 if command[1] == "rev-parse" else " M changed-source.rs\n"

                def native(*_, **__):
                    if mode == "timeout":
                        raise subprocess.TimeoutExpired("native fixture", 900)
                    return SimpleNamespace(returncode=0, stdout='{"status":"PASS","checks":[]}', stderr="diagnostic\n")

                with patch.object(fixture, "__file__", str(root / "scripts/check_business_store_fixture.py")), \
                     patch.object(fixture.subprocess, "check_output", side_effect=git), \
                     patch.object(fixture, "execute_native", side_effect=native), \
                     patch.dict(os.environ, {"RUNNER_TEMP": temp}), \
                     patch("builtins.print"), \
                     self.assertRaises((subprocess.TimeoutExpired, SystemExit)):
                    fixture.main()
                report = json.loads(report_path.read_text())
                self.assertEqual(report["status"], "FAIL")
                self.assertEqual(report["source_sha"], "b" * 40)
                self.assertTrue(report["working_tree_dirty"])
                self.assertIs(report["cfg_test"], False)


if __name__ == "__main__":
    unittest.main()
