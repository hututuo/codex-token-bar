"""Reject compiler errors, empty runs and unrelated panics as mutation evidence."""
import importlib.util
from pathlib import Path
import sys
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("backup_cleanup_gate", SCRIPTS / "check_backup_cleanup_gate.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class BackupCleanupGateTests(unittest.TestCase):
    def test_requires_exact_test_failure_and_leaked_file_reason(self):
        log = (f"test {gate.TEST} ... FAILED\n"
               f"{gate.FAILURE} /fixture/actual-temp.sqlite\n"
               "test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 1792 filtered out; finished in 0.01s\n")
        gate.validate_rejection(log, 101)
        gate.validate_rejection(log.replace("\n", "\r\n"), 101)
        invalid = [
            (log, 0),
            ("error[E0000]: compilation failed\n" + gate.FAILURE, 101),
            ("test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 1793 filtered out; finished in 0.01s\n", 0),
            (log.replace(gate.TEST, "another_test"), 101),
            (log.replace(gate.FAILURE, "unrelated panic"), 101),
            (log + log, 101),
            (log.replace("0 passed; 1 failed", "1 passed; 1 failed"), 101),
        ]
        for text, code in invalid:
            for candidate in [text, text.replace("\n", "\r\n")]:
                with self.subTest(text=candidate, code=code), self.assertRaises(ValueError):
                    gate.validate_rejection(candidate, code)


if __name__ == "__main__":
    unittest.main()
