import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "check_test_execution.py"
spec = importlib.util.spec_from_file_location("execution_gate", SCRIPT)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

RUST = "running 1 test\ntest core::safety ... ok\ntest result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 7 filtered out; finished in 0.1s\n"
SWIFT = "Test Case '-[Module.SafetyTests safety]' passed (0.01 seconds).\nTest Suite 'Selected tests' passed at 2026-11-04 20:00:00.\n Executed 1 test, with 0 failures (0 unexpected) in 0.01 seconds\n"


class TestExecutionGateTests(unittest.TestCase):
    def test_real_pass_records_are_required_in_addition_to_summary(self):
        for kind, text in (("rust", RUST), ("swift", SWIFT)):
            with self.subTest(kind=kind):
                self.assertEqual(gate.validate_execution(text, kind, ["safety"])["passed"], 1)
                for bad in ("", "Build complete!", text.replace("safety", "safety_extra"),
                            text.splitlines()[-1] + "\n", text + text):
                    with self.subTest(bad=bad), self.assertRaises(ValueError):
                        gate.validate_execution(bad, kind, ["safety"])

    def test_zero_match_and_all_skipped_are_not_success(self):
        cases = [("rust", RUST.replace("1 passed", "0 passed").replace("test core::safety ... ok\n", "")),
                 ("rust", RUST.replace("... ok", "... ignored").replace("1 passed", "0 passed").replace("0 ignored", "1 ignored")),
                 ("swift", SWIFT.replace("Test Case '-[Module.SafetyTests safety]' passed (0.01 seconds).\n", "").replace("Executed 1 test", "Executed 0 tests")),
                 ("swift", SWIFT.replace("safety]' passed", "safety]' skipped").replace("with 0 failures", "with 1 test skipped and 0 failures"))]
        for kind, text in cases:
            with self.subTest(kind=kind, text=text), self.assertRaises(ValueError):
                gate.validate_execution(text, kind)

    def test_required_skip_cannot_be_hidden_by_other_passing_tests(self):
        rust = RUST.replace("running 1 test", "running 2 tests").replace("test result:", "test core::required ... ignored\ntest result:").replace("0 ignored", "1 ignored")
        swift = SWIFT.replace("Test Suite", "Test Case '-[Module.SafetyTests required]' skipped (0.0 seconds).\nTest Suite").replace("Executed 1 test, with", "Executed 2 tests, with 1 test skipped and")
        for kind, text in (("rust", rust), ("swift", swift)):
            self.assertEqual(gate.validate_execution(text, kind)["skippedOrIgnored"], 1)
            with self.assertRaises(ValueError): gate.validate_execution(text, kind, ["required"])

    def test_failed_case_or_failed_summary_is_rejected(self):
        for kind, text in (("rust", RUST.replace("... ok", "... FAILED")),
                           ("rust", RUST.replace("0 failed", "1 failed")),
                           ("swift", SWIFT.replace("safety]' passed", "safety]' failed")),
                           ("swift", SWIFT.replace("0 failures", "1 failure"))):
            with self.subTest(kind=kind), self.assertRaises(ValueError): gate.validate_execution(text, kind)

    def test_swift_multiple_bundles_count_actual_tests_without_nested_summary_duplication(self):
        def bundle(name, records, skipped=0, total=None):
            count = len(records) if total is None else total
            skip = f"{skipped} test skipped and " if skipped else ""
            summary = f" Executed {count} tests, with {skip}0 failures (0 unexpected) in 0.1 seconds\n"
            return (f"Test Suite 'Selected tests' started at now.\nTest Suite '{name}.xctest' started at now.\n"
                + "".join(f"Test Case '-[{name}.Cases {test}]' {outcome} (0.0 seconds).\n" for test, outcome in records)
                + f"Test Suite '{name}.xctest' passed at now.\n" + summary
                + "Test Suite 'Selected tests' passed at now.\n" + summary)
        first = bundle("Main", [("safety", "passed"), ("optionalProfile", "skipped")], 1)
        second = bundle("Capture", [("another", "passed")])
        empty = bundle("Empty", [])
        result = gate.validate_execution(first + second + empty, "swift", ["safety", "another"])
        self.assertEqual(result["passed"], 2)
        self.assertEqual(result["skippedOrIgnored"], 1)
        for broken in (first.replace("0 failures", "1 failure") + second + empty,
                       first + bundle("Capture", [("another", "passed")], total=0) + empty,
                       first + second + "Test Suite 'Incomplete.xctest' started at now.\n",
                       first + second + first,
                       first + bundle("Capture", [("another", "skipped")]) + empty):
            with self.subTest(log=broken), self.assertRaises(ValueError):
                gate.validate_execution(broken, "swift")

    def test_rust_ignored_records_must_match_the_summary(self):
        for broken in (RUST.replace("0 ignored", "1 ignored"),
                       RUST.replace("test result:", "test core::optional ... ignored\ntest result:")):
            with self.subTest(log=broken), self.assertRaises(ValueError):
                gate.validate_execution(broken, "rust")

    def test_swift_started_bundles_and_cases_must_finish(self):
        started = "Test Suite 'Main.xctest' started at now.\n"
        partial = started + SWIFT.replace("Selected tests", "SafetyTests")
        dangling_case = SWIFT + "Test Case '-[Module.SafetyTests unfinished]' started.\n"
        complete = started + SWIFT.replace("Selected tests", "Main.xctest")
        for broken in (partial, SWIFT.replace("Selected tests", "SafetyTests"), dangling_case, complete + "Test Case '-[Module.SafetyTests unfinished]' started.\n",
                       "Test Suite 'All tests' started at now.\n" + complete):
            with self.subTest(log=broken), self.assertRaises(ValueError):
                gate.validate_execution(broken, "swift")

    def test_xctest_records_survive_interleaved_application_output(self):
        mixed = SWIFT.replace("Test Case", "Actual storage diagnostic without a newline: Test Case")
        self.assertEqual(gate.validate_execution(mixed, "swift", ["safety"])["passed"], 1)
        with self.assertRaises(ValueError):
            gate.validate_execution(mixed.replace("1 test", "2 tests"), "swift")

    def test_exact_source_rejects_tracked_edits_before_or_during_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "repo"
            root.mkdir()
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=root, text=True, stderr=subprocess.DEVNULL).strip()
            git("init", "-q")
            source = root / "source.txt"
            source.write_text("original\n")
            git("add", "source.txt")
            git("-c", "user.name=Test Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture")
            sha = git("rev-parse", "HEAD")
            sentinel = Path(directory) / "child-ran"
            def run(label, child, exact=True):
                log = Path(directory) / f"{label}.log"
                args = [sys.executable, str(SCRIPT), "--kind", "rust", "--log", str(log)]
                if exact: args += ["--source-sha", sha]
                result = subprocess.run(args + ["--", sys.executable, "-c", child], cwd=root, capture_output=True, text=True)
                return result, json.loads(log.with_suffix(".execution.json").read_text())
            source.write_text("uncommitted change\n")
            child = f"from pathlib import Path; Path({str(sentinel)!r}).touch(); print({RUST!r})"
            result, evidence = run("dirty-exact", child)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(sentinel.exists())
            self.assertEqual(evidence["status"], "FAIL")

            result, evidence = run("dirty-local", child, exact=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(evidence["sourceBefore"]["trackedDirty"])
            self.assertEqual(len(evidence["sourceBefore"]["trackedDiffSha256"]), 64)

            source.write_text("original\n")
            result, evidence = run("changed-during", f"from pathlib import Path; Path('source.txt').write_text('changed'); print({RUST!r})")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(evidence["status"], "FAIL")
            self.assertFalse(evidence["sourceBefore"]["trackedDirty"])
            self.assertTrue(evidence["sourceAfter"]["trackedDirty"])

    def test_exact_source_rejects_untracked_inputs_before_and_after_execution(self):
        for phase in ("before", "during"):
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / "repo"
                root.mkdir()
                subprocess.run(["git", "init", "-q"], cwd=root, check=True)
                (root / "source.txt").write_text("original")
                subprocess.run(["git", "add", "source.txt"], cwd=root, check=True)
                subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                    "commit", "-qm", "fixture"], cwd=root, check=True)
                sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
                if phase == "before": (root / "required_test.rs").write_text("untracked input")
                log = root / "execution.log"
                child = f"from pathlib import Path; Path('required_test.rs').write_text('untracked input'); print({RUST!r})"
                result = subprocess.run([sys.executable, str(SCRIPT), "--kind", "rust", "--log", str(log),
                    "--source-sha", sha, "--", sys.executable, "-c", child], cwd=root, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                evidence = json.loads(log.with_suffix(".execution.json").read_text())
                self.assertEqual(evidence["status"], "FAIL")
                self.assertIn("Untracked", evidence["error"])
                self.assertEqual(log.exists(), phase == "during")

    def test_exact_source_allows_only_declared_outputs_and_records_exceptions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            (root / "source.txt").write_text("original")
            subprocess.run(["git", "add", "source.txt"], cwd=root, check=True)
            subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                "commit", "-qm", "fixture"], cwd=root, check=True)
            sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            (root / "runtime-recovery-production.json").write_text("{}")
            log = root / "execution.log"
            child = ("from pathlib import Path; Path('visual-previews').mkdir(); "
                     f"Path('visual-previews/chart.png').write_bytes(b'fixture output'); print({RUST!r})")
            args = [sys.executable, str(SCRIPT), "--kind", "rust", "--log", str(log), "--source-sha", sha,
                "--allow-untracked-output", "runtime-recovery-production.json",
                "--allow-untracked-output", "visual-previews/*.png"]
            result = subprocess.run(args + ["--", sys.executable, "-c", child], cwd=root, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            evidence = json.loads(log.with_suffix(".execution.json").read_text())
            self.assertEqual(evidence["status"], "PASS")
            self.assertEqual(evidence["allowedUntrackedOutputs"], ["runtime-recovery-production.json", "visual-previews/*.png"])
            self.assertEqual(evidence["sourceBefore"]["untrackedInputs"], [])
            self.assertIn("visual-previews/chart.png", evidence["sourceAfter"]["allowedUntrackedOutputs"])
            (root / "visual-previews/safety.rs").write_text("not output")
            args[args.index(str(log))] = str(root / "retry.log")
            args += ["--allow-untracked-output", "execution.log", "--allow-untracked-output", "execution.execution.json"]
            result = subprocess.run(args + ["--", sys.executable, "-c", f"print({RUST!r})"], cwd=root, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("visual-previews/safety.rs", json.loads((root / "retry.execution.json").read_text())["error"])

    def test_actual_child_exit_and_empty_output_cannot_be_overridden_by_pass_summary(self):
        for text, code, success in ((RUST, 0, True), (RUST, 7, False), ("", 0, False)):
            with tempfile.TemporaryDirectory() as directory:
                log = Path(directory) / "tests.log"
                child = f"import sys; print({text!r}); sys.exit({code})"
                result = subprocess.run([sys.executable, str(SCRIPT), "--kind", "rust", "--log", str(log),
                    "--require", "safety", "--", sys.executable, "-c", child], capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, success, result.stderr)
                evidence = json.loads(log.with_suffix(".execution.json").read_text())
                self.assertEqual(evidence["status"], "PASS" if success else "FAIL")
                self.assertEqual(evidence["commandExitCode"], code)
                self.assertEqual(len(evidence["logSha256"]), 64)

    def test_source_mismatch_and_stale_output_stop_before_child_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "tests.log"
            sentinel = Path(directory) / "child-ran"
            command = [sys.executable, str(SCRIPT), "--kind", "rust", "--log", str(log)]
            child = ["--", sys.executable, "-c", f"from pathlib import Path; Path({str(sentinel)!r}).touch()"]
            result = subprocess.run(command + ["--source-sha", "0" * 40] + child, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(sentinel.exists())
            log.write_text("old passing log")
            result = subprocess.run(command + child, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(sentinel.exists())
            self.assertEqual(log.read_text(), "old passing log")


if __name__ == "__main__":
    unittest.main()
