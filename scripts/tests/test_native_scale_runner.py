import copy
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

path = Path(__file__).resolve().parents[1] / "cloud/run-business-store-fixture.py"
spec = importlib.util.spec_from_file_location("native_scale_runner", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class NativeScaleRunnerTests(unittest.TestCase):
    def test_actual_hosted_fixture_nested_negative_control_is_admitted(self):
        # Exact redacted control objects from the 2344 production-path job,
        # whose producer succeeded but whose old flat-field reader rejected it.
        actual = json.loads((Path(__file__).parent / "fixtures/native-concurrent-probe-2344.json").read_text())
        module.validate_concurrent_probe(actual)

    def test_concurrent_probe_requires_real_lock_control_and_observed_exact_calls(self):
        result = {"checks": [
            {"name": "concurrent-a-write-probe", "status": "PASS", "timeoutMilliseconds": 250,
             "serializedProbeConnection": True, "parallelProbeRows": 4, "catalogStable": True,
             "negativeControl": {"sqliteCode": "Some(DatabaseBusy)", "heldByBeginImmediate": True,
                                 "writeResumedAfterRollback": True}},
            {"name": "exact-concurrent-a-write-observed", "status": "PASS", "probeWrites": 12},
        ]}
        module.validate_concurrent_probe(result)
        for key, value in [("timeoutMilliseconds", 500), ("negativeControl", {}),
                           ("catalogStable", False), ("parallelProbeRows", 0)]:
            invalid = copy.deepcopy(result)
            invalid["checks"][0][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                module.validate_concurrent_probe(invalid)
        for key, value in [("sqliteCode", "None"), ("heldByBeginImmediate", False),
                           ("writeResumedAfterRollback", False)]:
            invalid = copy.deepcopy(result)
            invalid["checks"][0]["negativeControl"][key] = value
            with self.subTest(negative=key), self.assertRaises(ValueError):
                module.validate_concurrent_probe(invalid)
        for count in (0, -1, None, True):
            invalid = copy.deepcopy(result)
            invalid["checks"][1]["probeWrites"] = count
            with self.subTest(count=count), self.assertRaises(ValueError):
                module.validate_concurrent_probe(invalid)
        with self.assertRaises(ValueError):
            module.validate_concurrent_probe({"checks": [result["checks"][0]]})

    def test_windows_style_console_cannot_hide_fixture_error_or_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            output = root / "evidence.json"
            args = SimpleNamespace(binary=root / "fixture", output=output)
            console = io.BytesIO()
            stream = io.TextIOWrapper(console, encoding="cp1252")
            child = subprocess.CompletedProcess([], 7,
                stdout=json.dumps({"status": "FAIL", "error": "旧账保留"}, ensure_ascii=False),
                stderr="真实失败阶段：sync_error\n")
            with patch.object(module.argparse.ArgumentParser, "parse_args", return_value=args), \
                 patch.dict(module.os.environ, {"GITHUB_ACTIONS": "true", "RUNNER_TEMP": str(root)}), \
                 patch.object(module.tempfile, "gettempdir", return_value=str(root)), \
                 patch.object(module.subprocess, "run", return_value=child), \
                 patch.object(module.sys, "stdout", stream), patch.object(module.sys, "stderr", stream):
                with self.assertRaises(SystemExit) as error:
                    module.main()
                self.assertEqual(error.exception.code, 7)
                self.assertEqual(stream.encoding, "utf-8")
                stream.flush()
            self.assertIn("旧账保留", console.getvalue().decode("utf-8"))
            self.assertIn("真实失败阶段", output.with_suffix(".log").read_text(encoding="utf-8"))
            self.assertFalse(output.exists(), "A failed fixture must never create a successful JSON profile")
            stream.detach()

    def profile(self):
        return {"status": "PASS", "checks": [{
            "name": "exact-rust-production-scale-fixture", "status": "PROFILED",
            "sourceCounts": 4124, "events": 503128,
            "stores": {"seededEmptyCandidateNamespaces": 6250}, "budgetPassed": True,
            "budget": {"backfillSecondsMax": 600.0, "unchangedP95SecondsMax": 1.0},
            "backfillSeconds": 300.0, "unchangedP95": 0.5,
            "correctness": {"rawAccountingDigestBefore": "a" * 64, "rawAccountingDigestAfter": "a" * 64},
        }]}

    def test_optional_profile_does_not_change_regular_fixture_gate(self):
        module.validate_native_scale({"status": "PASS"}, False)
        with self.assertRaises(ValueError):
            module.validate_native_scale({"status": "PASS"}, True)

    def test_required_pressure_must_have_one_full_sized_profile(self):
        profile = self.profile()
        module.validate_native_scale(profile, True)
        duplicate = copy.deepcopy(profile)
        duplicate["checks"] *= 2
        with self.assertRaises(ValueError):
            module.validate_native_scale(duplicate, True)
        for key, value in [("sourceCounts", 512), ("events", 4096), ("budgetPassed", False)]:
            invalid = copy.deepcopy(profile)
            invalid["checks"][0][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                module.validate_native_scale(invalid, True)
        invalid = self.profile()
        invalid["checks"][0]["stores"]["seededEmptyCandidateNamespaces"] = 0
        with self.assertRaises(ValueError):
            module.validate_native_scale(invalid, True)
        for proof in ({}, {"rawAccountingDigestBefore": "a" * 64, "rawAccountingDigestAfter": "b" * 64}):
            invalid = self.profile()
            invalid["checks"][0]["correctness"] = proof
            with self.assertRaises(ValueError):
                module.validate_native_scale(invalid, True)

    def test_reported_pass_cannot_override_the_original_timing_limits(self):
        for field, value in (("backfillSeconds", 600.01), ("unchangedP95", 1.001),
                             ("backfillSeconds", float("nan")), ("unchangedP95", True),
                             ("unchangedP95", -1), ("budget", {"backfillSecondsMax": 1200.0, "unchangedP95SecondsMax": 2.0})):
            profile = self.profile()
            profile["checks"][0][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                module.validate_native_scale(profile, True)
