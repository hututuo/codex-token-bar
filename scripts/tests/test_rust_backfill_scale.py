import copy
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("rust_backfill_scale", Path(__file__).resolve().parents[1] / "check_rust_backfill_scale.py")
scale = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(scale)


def profile(count=13):
    active = {"elapsedSeconds": 1.0, "largestProgressGapSeconds": 0.5, "stagedJobs": count,
              "batches": (count + 3) // 4, "peakStageStores": 4, "peakStageTables": 16,
              "progressEvents": count, "backfillProgressEvents": count, "lastBackfillCompleted": count,
              "modelBackfillMonotonic": True, "modelBackfillProgressError": None}
    cold = dict(active, backfillProgressEvents=0, lastBackfillCompleted=0, modelBackfillMonotonic=None)
    warm = dict(cold, stagedJobs=0, batches=0, peakStageStores=0, peakStageTables=0)
    return {"status": "PASS", "files": count, "events": count, "modelsRestored": count,
            "tokens": 120 * count + count * (count - 1) // 2, "stageStoresAfter": 0,
            "concurrentWriterProbeEnabled": False, "concurrentWriteAssertions": 0,
            "cfgTest": False, "nativeProductionRoutes": True, "sourceBytesUnchanged": True, "sourceFactsVerified": True,
            "sourceBytesDigest": "a" * 64, "numericRowsDigestBefore": "b" * 64, "numericRowsDigestAfter": "b" * 64,
            "cold": cold, "backfill": copy.deepcopy(active), "warm": warm, "totalSeconds": 3.0}


class RustSourceScaleGateTests(unittest.TestCase):
    def test_complete_production_profile_passes(self):
        scale.validate_profiles([profile(13), profile(128)], (13, 128), 30, 600)

    def test_missing_duplicate_wrong_order_and_wrong_size_profiles_fail(self):
        for values in ([], [profile(13)], [profile(13), profile(13)], [profile(128), profile(13)]):
            with self.subTest(values=[v["files"] for v in values]), self.assertRaises(ValueError):
                scale.validate_profiles(values, (13, 128), 30, 600)

    def test_failure_raw_sqlite_or_unproven_history_cannot_pass(self):
        for field, value in (("status", "FAIL"), ("cfgTest", True), ("nativeProductionRoutes", False),
                             ("concurrentWriterProbeEnabled", True), ("concurrentWriterProbeEnabled", None),
                             ("concurrentWriteAssertions", 1), ("concurrentWriteAssertions", False),
                             ("sourceBytesUnchanged", False), ("sourceFactsVerified", False), ("numericRowsDigestAfter", "c" * 64),
                             ("numericRowsDigestBefore", None), ("sourceBytesDigest", ""),
                             ("tokens", 1), ("events", 12), ("files", True), ("modelsRestored", 0), ("stageStoresAfter", 1)):
            data = profile(); data[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                scale.validate_profile(data, 13, 30, 600)

    def test_missing_phase_retained_stage_growth_reparse_and_progress_failure_fail(self):
        for phase, field, value in (("cold", "peakStageStores", 5), ("cold", "peakStageTables", 20),
                                    ("backfill", "stagedJobs", 12), ("backfill", "batches", 1),
                                    ("warm", "stagedJobs", 1), ("backfill", "modelBackfillMonotonic", False),
                                    ("backfill", "modelBackfillMonotonic", None),
                                    ("backfill", "modelBackfillProgressError", "completed 13 -> 0"),
                                    ("backfill", "lastBackfillCompleted", 12),
                                    ("backfill", "backfillProgressEvents", 0),
                                    ("cold", "progressEvents", 0), ("backfill", "elapsedSeconds", 601),
                                    ("cold", "largestProgressGapSeconds", 31),
                                    ("backfill", "elapsedSeconds", float("nan")),
                                    ("warm", "elapsedSeconds", float("inf"))):
            data = profile(); data[phase][field] = value
            with self.subTest(phase=phase, field=field), self.assertRaises(ValueError):
                scale.validate_profile(data, 13, 30, 600)
        data = profile(); del data["warm"]
        with self.assertRaises(ValueError): scale.validate_profile(data, 13, 30, 600)

    def test_invalid_execution_budgets_and_size_lists_fail(self):
        for sizes in ((), (8,), (8193,), (13, 13), (True,)):
            with self.subTest(sizes=sizes), self.assertRaises(ValueError):
                scale.validate_options(sizes, 1200, 30, 600)
        for budget in (0, -1, float("nan"), float("inf"), True):
            with self.subTest(budget=budget), self.assertRaises(ValueError):
                scale.validate_options((13,), 1200, budget, 600)

    def test_release_timing_rejects_unoptimized_or_test_artifacts(self):
        scale.validate_build_profile("dev", {"opt_level": "0", "test": False, "debug_assertions": True})
        valid = {"opt_level": "3", "test": False, "debug_assertions": False}
        scale.validate_build_profile("release", valid)
        for changed in ({"opt_level": "0"}, {"test": True}, {"debug_assertions": True}):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                scale.validate_build_profile("release", valid | changed)
        with self.assertRaises(ValueError): scale.validate_build_profile("release", {})

    def test_failed_independent_case_preserves_evidence_and_runs_later_sizes(self):
        for failure in ("exit", "invalid"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory(prefix="tokenbar-scale-runner-") as temp:
                base = Path(temp)
                calls = []

                def launch(command, *, cwd, env, stdout, stderr):
                    count = int(command[-1])
                    calls.append(count)
                    root = Path(command[1])
                    (root / "preserve.txt").write_text("synthetic fixture source\n")
                    value = profile(count)
                    if count == 13 and failure == "invalid":
                        value["numericRowsDigestAfter"] = "c" * 64
                    stdout.write(json.dumps(value)); stdout.flush()
                    stderr.write("native probe diagnostic\n"); stderr.flush()
                    return SimpleNamespace(wait=lambda timeout: 1 if count == 13 and failure == "exit" else 0,
                                           kill=lambda: None)

                def git(command, **_):
                    return "a" * 40 if command[1] == "rev-parse" else ""

                with patch.object(scale, "build_fixture", return_value=(base / "native", {"profileName": "dev"})), \
                     patch.object(scale.subprocess, "check_output", side_effect=git), \
                     patch.object(scale.subprocess, "Popen", side_effect=launch), \
                     patch.dict(scale.os.environ, {"RUNNER_TEMP": str(base)}), \
                     self.assertRaises(RuntimeError):
                    scale.run_sizes(base, base / "evidence", (13, 128), 1200, 30, 600)
                report = json.loads((base / "evidence/report.json").read_text())
                self.assertEqual(calls, [13, 128])
                self.assertEqual(report["status"], "FAIL")
                self.assertEqual([item["files"] for item in report["failures"]], [13])
                self.assertEqual(report["profiles"][-1]["files"], 128)
                retained = Path(report["failures"][0]["preservedRoot"])
                self.assertTrue((retained / "preserve.txt").is_file())
                self.assertTrue((base / "evidence/source-count-13.log").is_file())
                self.assertNotIn("runningSize", report)


if __name__ == "__main__": unittest.main()
