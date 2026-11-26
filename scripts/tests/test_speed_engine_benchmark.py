import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "scripts/cloud/summarize_speed_engine_benchmark.py"
SPEC = importlib.util.spec_from_file_location("speed_engine_benchmark", MODULE_PATH)
BENCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BENCH)
BASELINE = "f9e917917df07a24a800bf63d00700d0028bcb28"
CANDIDATE = "a" * 40


class SpeedEngineBenchmarkTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.fixture = self.root / "fixture.swift"
        self.fixture.write_text("// synthetic harness identity; never compiled\n")
        manifest = {
            "schemaVersion": 1, "baseline": BASELINE, "candidate": CANDIDATE,
            "actualSources": {"baseline": BASELINE, "candidate": CANDIDATE}, "harness": "b" * 40,
            "fixtureSha256": hashlib.sha256(self.fixture.read_bytes()).hexdigest(),
            "configuration": "release", "swiftFlags": ["-Xswiftc", "-enable-testing"],
            "responses": list(BENCH.SIZES), "shapes": list(BENCH.SHAPES), "trials": list(BENCH.TRIALS),
            "ticks": 200, "freshProcessPerCase": True, "singleHostedRunner": True,
        }
        self.write_json("manifest.json", manifest)
        (self.root / "toolchain.txt").write_text("synthetic hosted toolchain fixture\n")
        for role, source in (("baseline", BASELINE), ("candidate", CANDIDATE)):
            for phase in ("provenance-before", "prepare-lfs", "build", "provenance-after"):
                argv = ["swift", "build", "--build-tests", "-c", "release", "-Xswiftc", "-enable-testing"]
                self.write_command(f"{role}-{phase}", [], argv)
            for trial in BENCH.TRIALS:
                argv = self.command_argv(source, trial, "SpeedEngineBenchmarkTests.testReplacementAndBoundaryCompatibilityTrace")
                trace = [{"kind": "compatibility", "source": source, "trial": trial, "phase": phase,
                          "output": {"nowMs": 1_800_000_000_000, "live": [60.0, 70.0], "eventCount": 0},
                          "storedKeys": ["a", "b"]} for phase in BENCH.TRACE_PHASES]
                self.write_command(f"{role}-compatibility-{trial}", trace, argv)
                for size in BENCH.SIZES:
                    for shape in BENCH.SHAPES:
                        argv = self.command_argv(source, trial, "SpeedEngineBenchmarkTests.testUnchangedSyntheticPublishes")
                        argv += [f"SPEED_BENCHMARK_RESPONSES={size}", f"SPEED_BENCHMARK_SHAPE={shape}", "SPEED_BENCHMARK_TICKS=200"]
                        metadata = {"source": source, "trial": trial, "fixtureResponses": size, "shape": shape}
                        cpu = (100.0 if role == "baseline" else 50.0) + trial
                        measurement = {
                            **metadata, "kind": "measurement", "phase": "unchanged", "ticks": 200,
                            "milliseconds": cpu + 10, "cpuMilliseconds": cpu,
                            "userMilliseconds": cpu - 5, "systemMilliseconds": 5.0,
                            "processPeakRSSBytesBeforeFixture": 100_000,
                            "processPeakRSSBytesBeforeLoop": 200_000, "processPeakRSSBytesAfterLoop": 210_000,
                            "processCurrentRSSBytesBeforeFixture": 90_000,
                            "processCurrentRSSBytesBeforeLoop": 180_000, "processCurrentRSSBytesAfterLoop": 185_000,
                            "currentRSSStatusBeforeFixture": 0, "currentRSSStatusBefore": 0,
                            "currentRSSStatusAfter": 0, "checksum": 10_000.0,
                        }
                        correctness = [{**metadata, "kind": "correctness", "phase": phase,
                                        "output": self.output(size, phase)} for phase in BENCH.PHASES]
                        self.write_command(f"{role}-{size}-{shape}-{trial}", [measurement, *correctness], argv)

    def write_json(self, name, body):
        (self.root / name).write_text(json.dumps(body) + "\n")

    def command_argv(self, source, trial, filter_name):
        return ["env", f"SPEED_BENCHMARK_SOURCE={source}", f"SPEED_BENCHMARK_TRIAL={trial}",
                "swift", "test", "-c", "release", "-Xswiftc", "-enable-testing", "--skip-build", "--filter", filter_name]

    def write_command(self, label, records, argv):
        self.write_json(label + ".exit.json", {"commandExitCode": 0, "logExitCode": 0, "argv": argv})
        self.write_records(label, records)

    def write_records(self, label, records):
        (self.root / (label + ".log")).write_text("".join(BENCH.PREFIX + json.dumps(record) + "\n" for record in records))

    def records(self, label):
        return [json.loads(line.split(BENCH.PREFIX, 1)[1]) for line in (self.root / (label + ".log")).read_text().splitlines()
                if BENCH.PREFIX in line]

    def output(self, size, phase):
        expected = BENCH.independent_totals(size)
        now = 1_800_082_000_000 + (100_000 if phase == "after-unchanged" else 0)
        return {"nowMs": now, "todayStartMs": 1_800_000_000_000,
                "today": [size, expected["input"], 0, 0, expected["output"], 0],
                "unfinalized": expected["unfinalized"], "todayCost": [expected["cost"], expected["unpriced"]],
                "live": [1.0, 2.0], "eventCount": 0,
                "history": [[now - (299 - index) * 1000, 0.0, 0.0, 0.0, 0.0] for index in range(300)]}

    def summarize(self):
        return BENCH.validate_and_summarize(self.root, BASELINE, CANDIDATE, self.fixture)

    def test_complete_pair_reports_subsystem_metrics_and_semantics(self):
        result = self.summarize()
        self.assertEqual(result["status"], "PASS")
        self.assertEqual(len(result["records"]), 24)
        self.assertEqual(len(result["summary"]), 4)
        self.assertEqual(result["semanticComparisons"], 35)
        self.assertGreater(result["summary"][0]["observedMedianReductionPercent"]["cpuMilliseconds"], 0)
        self.assertIn("No speed or RSS threshold", result["performanceGate"])
        self.assertTrue(any("no whole-app" in item for item in result["limitations"]))

    def test_baseline_trial_disagreement_fails_before_performance_claim(self):
        label = "baseline-2000-day-2"
        records = self.records(label)
        records[1]["output"]["live"][0] += 0.1
        self.write_records(label, records)
        with self.assertRaisesRegex(BENCH.EvidenceError, "self-consistency"):
            self.summarize()

    def test_candidate_semantic_regression_fails(self):
        for trial in BENCH.TRIALS:
            label = f"candidate-2000-day-{trial}"
            records = self.records(label)
            for record in records[1:]:
                record["output"]["live"][0] += 0.25
            self.write_records(label, records)
        with self.assertRaisesRegex(BENCH.EvidenceError, "paired.*floating mismatch"):
            self.summarize()

    def test_float_tolerance_is_absolute_and_integer_contract_stays_exact(self):
        BENCH.compare_semantics({"live": [1, 2.0]}, {"live": [1.0000001, 2.0000001]})
        for actual in ([1.0000001], [2], [True]):
            with self.subTest(actual=actual), self.assertRaises(BENCH.EvidenceError):
                BENCH.compare_semantics({"today": [1]}, {"today": actual})
        with self.assertRaises(BENCH.EvidenceError):
            BENCH.compare_semantics({"live": [1_000_000_000.0]}, {"live": [1_000_000_000.01]})

    def test_missing_or_failed_command_and_zero_execution_are_rejected(self):
        label = "baseline-2000-day-1"
        exit_path = self.root / (label + ".exit.json")
        saved = json.loads(exit_path.read_text())
        self.write_json(label + ".exit.json", {**saved, "commandExitCode": 1})
        with self.assertRaisesRegex(BENCH.EvidenceError, "did not exit"):
            self.summarize()
        self.write_json(label + ".exit.json", saved)
        self.write_records(label, [])
        with self.assertRaisesRegex(BENCH.EvidenceError, "zero-test success"):
            self.summarize()
        exit_path.unlink()
        with self.assertRaisesRegex(BENCH.EvidenceError, "cannot read"):
            self.summarize()

    def test_short_sha_fixture_drift_and_wrong_source_are_rejected(self):
        with self.assertRaisesRegex(BENCH.EvidenceError, "40-character"):
            BENCH.validate_and_summarize(self.root, BASELINE[:8], CANDIDATE, self.fixture)
        original = self.fixture.read_text()
        self.fixture.write_text("// changed fixture\n")
        with self.assertRaisesRegex(BENCH.EvidenceError, "fixture SHA-256"):
            self.summarize()
        self.fixture.write_text(original)
        label = "candidate-2000-day-1"
        records = self.records(label)
        records[0]["source"] = BASELINE
        self.write_records(label, records)
        with self.assertRaisesRegex(BENCH.EvidenceError, "identity mismatch"):
            self.summarize()

    def test_trace_order_and_missing_semantic_fields_are_rejected(self):
        label = "candidate-compatibility-1"
        records = self.records(label)
        original = copy.deepcopy(records)
        records[0], records[1] = records[1], records[0]
        self.write_records(label, records)
        with self.assertRaisesRegex(BENCH.EvidenceError, "trace phases"):
            self.summarize()
        original[0]["output"].pop("live")
        self.write_records(label, original)
        with self.assertRaisesRegex(BENCH.EvidenceError, "dictionary keys differ"):
            self.summarize()

    def test_optional_rss_failure_is_explicit_and_not_zero(self):
        label = "candidate-2000-day-1"
        records = self.records(label)
        records[0]["currentRSSStatusAfter"] = 5
        records[0]["processCurrentRSSBytesAfterLoop"] = None
        self.write_records(label, records)
        result = self.summarize()
        memory = result["summary"][0]["byRole"]["candidate"]["processCurrentRSSBytesAfterLoop"]
        self.assertIsNone(memory["median"])
        self.assertEqual(memory["availableTrials"], 2)
        self.assertIsNone(result["summary"][0]["observedMedianReductionPercent"]["processCurrentRSSBytesAfterLoop"])

    def test_workflow_has_one_runner_and_provenance_precedes_fixture_injection(self):
        workflow = (ROOT / ".github/workflows/performance-compatibility.yml").read_text()
        self.assertEqual(workflow.count("runs-on:"), 1)
        self.assertIn("runs-on: macos-26", workflow)
        self.assertNotIn("matrix:", workflow)
        self.assertIn('[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]', workflow)
        self.assertIn('[[ "$BASELINE_SHA" =~ ^[0-9a-f]{40}$ ]]', workflow)
        self.assertLess(workflow.index('run_logged "$role-provenance-before"'), workflow.index('cp "$HARNESS/scripts/cloud/fixtures/SpeedEngineBenchmarkTests.swift"'))
        self.assertEqual(workflow.count('run_logged "$role-build" swift build --build-tests'), 1)
        self.assertIn("--skip-build", workflow)
        self.assertIn('for role in baseline candidate; do', workflow)
        self.assertIn('for responses in 2000 20000; do', workflow)
        self.assertIn('for shape in day dense; do', workflow)
        self.assertIn('for trial in 1 2 3; do', workflow)
        self.assertIn("if: always()", workflow)
        self.assertIn("actions/upload-artifact@", workflow)


if __name__ == "__main__":
    unittest.main()
