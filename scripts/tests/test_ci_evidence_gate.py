import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "cloud/check_ci_evidence.py"
spec = importlib.util.spec_from_file_location("ci_evidence", SCRIPT)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
SHA = "a" * 40


def good_jobs():
    jobs = {name: {"result": "success"} for name in ("source", "frontend", "swift", "native", "windows-updater")}
    jobs["source"]["outputs"] = {"sha": SHA}
    jobs.update({"formed-upgrade": {"result": "skipped"}, "scale": {"result": "skipped"}})
    return jobs


class CIEvidenceGateTests(unittest.TestCase):
    def test_standard_pass_does_not_claim_optional_matrix_pass(self):
        outcomes = gate.validate_jobs(good_jobs(), SHA)
        self.assertEqual(outcomes["formed-upgrade"], "skipped")
        self.assertEqual(outcomes["scale"], "skipped")

    def test_every_required_job_must_run_and_pass(self):
        for name in ("source", "frontend", "swift", "native", "windows-updater"):
            for result in ("skipped", "cancelled", "failure", "timed_out", None):
                jobs = good_jobs()
                if result is None: del jobs[name]
                else: jobs[name]["result"] = result
                with self.subTest(job=name, result=result), self.assertRaises(ValueError):
                    gate.validate_jobs(jobs, SHA)

    def test_requested_optional_job_cannot_be_skipped(self):
        for name in ("formed-upgrade", "scale"):
            flags = {"formed_requested": name == "formed-upgrade", "scale_requested": name == "scale"}
            with self.assertRaises(ValueError): gate.validate_jobs(good_jobs(), SHA, **flags)
            jobs = good_jobs()
            jobs[name]["result"] = "success"
            gate.validate_jobs(jobs, SHA, **flags)

    def test_evidence_is_bound_to_resolved_source(self):
        for sha in ("b" * 40, "main", ""):
            with self.subTest(sha=sha), self.assertRaises(ValueError):
                gate.validate_jobs(good_jobs(), sha)

    def test_cli_retains_failure_and_never_creates_a_success_seal(self):
        for success in (True, False):
            with tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / "checked-source.json"
                jobs = good_jobs()
                if not success: jobs["native"]["result"] = "skipped"
                result = subprocess.run([sys.executable, str(SCRIPT), "--needs", json.dumps(jobs),
                    "--source-sha", SHA, "--run-id", "123", "--output", str(output)], capture_output=True)
                self.assertEqual(result.returncode == 0, success)
                self.assertEqual(output.exists(), success)
                decision = json.loads(output.with_name("ci-execution.json").read_text())
                self.assertEqual(decision["status"], "PASS" if success else "FAIL")
                if success:
                    self.assertEqual(json.loads(output.read_text()), {"source_sha": SHA, "run_id": "123", "passed": True})


if __name__ == "__main__":
    unittest.main()
