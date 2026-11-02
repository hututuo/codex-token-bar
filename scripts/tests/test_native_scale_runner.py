import copy
import importlib.util
from pathlib import Path
import unittest

path = Path(__file__).resolve().parents[1] / "cloud/run-business-store-fixture.py"
spec = importlib.util.spec_from_file_location("native_scale_runner", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class NativeScaleRunnerTests(unittest.TestCase):
    def profile(self):
        return {"status": "PASS", "checks": [{
            "name": "exact-rust-production-scale-fixture", "status": "PROFILED",
            "sourceCounts": 4124, "events": 503128,
            "stores": {"seededEmptyCandidateNamespaces": 6250}, "budgetPassed": True,
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
