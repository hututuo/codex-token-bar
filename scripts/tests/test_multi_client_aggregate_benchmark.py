"""Lightweight controls only: these never compile/run Rust or assert real timings."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
CLOUD = ROOT / "scripts/cloud"
sys.path.insert(0, str(CLOUD))
import summarize_multi_client_aggregate_benchmark as BENCH

SPEC = importlib.util.spec_from_file_location("run_multi_client_aggregate_benchmark", CLOUD / "run_multi_client_aggregate_benchmark.py")
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class AggregateBenchmarkControls(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.fixture = CLOUD / "fixtures/MultiClientAggregateBenchmark.rs"
        fixture_sha = BENCH.sha256(self.fixture)
        self.size = 48
        seed = RUNNER.seed_database(self.root / "synthetic.sqlite", self.size)
        self.manifest = {
            "schemaVersion": 1, "status": "COMPLETE", "singleHostedRunner": True,
            "freshProcessPerCase": True, "fixtureSha256": fixture_sha,
            "nowUnix": BENCH.NOW, "timezone": "UTC", "sizes": [self.size], "trials": 2,
            "iterations": {"cold": 3, "cache-hit": 25},
            "witnessExpectations": {"baseline": "canonical", "candidate": "staged"},
            "seeds": {str(self.size): seed}, "sources": {}, "executionOrder": [],
            "harnessInputs": {path.name: BENCH.sha256(path) for path in (
                self.fixture, CLOUD / "run_multi_client_aggregate_benchmark.py", CLOUD / "summarize_multi_client_aggregate_benchmark.py")},
        }
        for role in ("baseline", "candidate"):
            binary = self.root / (role + "-binary")
            binary.write_bytes(b"synthetic validator control; not a real native executable\n")
            self.manifest["sources"][role] = {
                "sha": ("a" if role == "baseline" else "b") * 40,
                "sourceSha256": "c" * 64, "injectedSourceSha256": "d" * 64,
                "sqlSha256": "e" * 64, "pricesSha256": "f" * 64,
                "fixtureSha256": fixture_sha, "restoredSourceSha256": "c" * 64,
                "binarySha256": BENCH.sha256(binary), "binaryArtifact": binary.name, "cleanAfter": True,
            }
            self.command(role + "-build", "", ["cargo", "test", "--lib", "--release", "--locked", "--no-run", "--message-format=json"])
            self.command(role + "-list", BENCH.TEST + ": test\n", [str(binary), "--list", "--exact", BENCH.TEST])
        for phase in BENCH.PHASES:
            for trial in (1, 2):
                for role in (("baseline", "candidate") if trial % 2 else ("candidate", "baseline")):
                    label = f"{role}-{self.size}-{phase}-{trial}"
                    self.manifest["executionOrder"].append(label)
                    record = self.record(role, phase, trial)
                    self.command(label, self.log(record), [role + "-binary", "--exact", BENCH.TEST, "--nocapture", "--test-threads=1"])
        self.save_manifest()

    def output(self, changed=False):
        value = {"updatedAt": "2027-01-15T09:00:00.001Z" if changed else "2027-01-15T09:00:00Z"}
        for array in BENCH.ARRAYS:
            rows = []
            for key, counters in sorted(BENCH.expected_groups(self.size, array, changed).items()):
                row = {"client": key[0], "model": key[-1], **counters}
                row["apiCostUSD" if array in BENCH.SUMMARY_ARRAYS else "apiCostMicroUSD"] = None if key[-1] == "synthetic-unknown" else 0.125
                row["unpricedRequests"] = counters["requests"] if key[-1] == "synthetic-unknown" else 0
                if array in BENCH.SUMMARY_ARRAYS:
                    row.update({"presentation": {"canonicalModel": key[-1]}, "lastSeen": "2027-01-15T09:00:00Z"})
                else:
                    row["startUnix"] = key[1]
                rows.append(row)
            value[array] = rows
        return value

    def record(self, role, phase, trial):
        provenance = self.manifest["sources"][role]
        seed = self.manifest["seeds"][str(self.size)]
        iterations = self.manifest["iterations"][phase]
        output = self.output()
        serialized = json.dumps(output, separators=(",", ":"), sort_keys=True)
        witness = {"statements": 20, "profiles": 20, "vmSteps": 1_000,
                   "canonicalStatements": 0, "stagingCreates": 0, "stagedReads": 0}
        if phase == "cold":
            witness.update({"canonicalStatements": 9 if role == "baseline" else 1,
                            "stagingCreates": 0 if role == "baseline" else 1,
                            "stagedReads": 0 if role == "baseline" else 9})
        duration = 10 if role == "baseline" else 5
        return {"schemaVersion": 1, "source": provenance["sha"], "trial": trial,
                "fixtureSha256": provenance["fixtureSha256"], "productionSourceSha256": provenance["injectedSourceSha256"],
                "sqlSha256": provenance["sqlSha256"], "pricesSha256": provenance["pricesSha256"],
                "logicalRows": self.size, "physicalRows": seed["physicalRows"], "databaseSha256": seed["sha256"],
                "phase": phase, "iterations": iterations, "productionEntryPoint": "read_cached_multi_client_aggregates",
                "cacheHitDelta": iterations if phase == "cache-hit" else 0, "checksums": [hashlib.sha256(serialized.encode()).hexdigest()] * iterations,
                "witness": witness, "outputJSON": serialized, "output": output, "afterMutation": self.output(True),
                "measurement": {"wallMilliseconds": duration + 1, "userMilliseconds": duration - 1,
                                "systemMilliseconds": 1, "cpuMilliseconds": duration,
                                "processPeakRSSBytesBeforeFixture": 1_000, "processPeakRSSBytesBeforeLoop": 2_000,
                                "processPeakRSSBytesAfterLoop": 2_100}}

    def log(self, record):
        return BENCH.PREFIX + json.dumps(record) + "\ntest result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 10 filtered out\n"

    def command(self, label, text, argv):
        (self.root / (label + ".log")).write_text(text)
        RUNNER.save_json(self.root / (label + ".exit.json"), {"commandExitCode": 0, "logExitCode": 0, "argv": argv})

    def save_manifest(self):
        RUNNER.save_json(self.root / "manifest.json", self.manifest)

    def summarize(self):
        return BENCH.validate_and_summarize(self.root, self.fixture)

    def mutate(self, role="candidate", phase="cold", trial=1, change=lambda value: None):
        path = self.root / f"{role}-{self.size}-{phase}-{trial}.log"
        record = json.loads(path.read_text().split(BENCH.PREFIX, 1)[1].splitlines()[0])
        change(record)
        path.write_text(self.log(record))

    def test_complete_control_validates_full_semantics_and_separate_phases(self):
        result = self.summarize()
        self.assertEqual(result["status"], "PASS")
        self.assertEqual(result["cases"], 8)
        self.assertEqual(len(result["summary"]), 2)
        self.assertEqual(result["summary"][0]["candidateToBaselineRatio"]["cpuMilliseconds"], 0.5)
        self.assertTrue(any("lifetime process peak" in item for item in result["limitations"]))

    def test_schema2_seed_is_synthetic_byte_identical_and_copied_responses_are_present(self):
        second = self.root / "second.sqlite"
        seed = RUNNER.seed_database(second, self.size)
        self.assertEqual(seed["sha256"], self.manifest["seeds"][str(self.size)]["sha256"])
        self.assertEqual(seed["physicalRows"], self.size + self.size // 3)
        with sqlite3.connect(second) as connection:
            self.assertEqual(connection.execute("PRAGMA user_version").fetchone(), (2,))
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM client_usage_events WHERE length(event_id)=135").fetchone()[0], self.size * 2 // 3)
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM client_usage_revisions").fetchone()[0], seed["physicalRows"])
        with self.assertRaisesRegex(BENCH.EvidenceError, "overwrite"):
            RUNNER.seed_database(second, self.size)

    def test_zero_skipped_or_incomplete_native_test_success_is_rejected(self):
        path = self.root / f"candidate-{self.size}-cold-1.log"
        original = path.read_text()
        for replacement in ("0 passed; 0 failed; 0 ignored;", "0 passed; 0 failed; 1 ignored;", "1 passed; 0 failed;"):
            with self.subTest(replacement=replacement):
                path.write_text(original.replace("1 passed; 0 failed; 0 ignored;", replacement))
                with self.assertRaisesRegex(BENCH.EvidenceError, "one-test success"):
                    self.summarize()

    def test_nonempty_totals_are_independently_checked_even_if_both_roles_agree(self):
        for label in self.manifest["executionOrder"]:
            path = self.root / (label + ".log")
            record = json.loads(path.read_text().split(BENCH.PREFIX, 1)[1].splitlines()[0])
            record["output"]["summaries"][0]["inputTokens"] += 1
            record["outputJSON"] = json.dumps(record["output"], separators=(",", ":"), sort_keys=True)
            record["checksums"] = [hashlib.sha256(record["outputJSON"].encode()).hexdigest()] * record["iterations"]
            path.write_text(self.log(record))
        with self.assertRaisesRegex(BENCH.EvidenceError, "independent oracle"):
            self.summarize()

    def test_full_price_and_presentation_semantics_are_compared_without_field_dropping(self):
        self.mutate(change=lambda record: record["afterMutation"]["summaries"][0].update({"presentation": {"unexpected": True}}))
        with self.assertRaisesRegex(BENCH.EvidenceError, "paired.*presentation"):
            self.summarize()

    def test_stub_or_missing_sqlite_witness_is_rejected(self):
        self.mutate(change=lambda record: record["witness"].update({"profiles": 0, "vmSteps": 0}))
        with self.assertRaisesRegex(BENCH.EvidenceError, "no real SQLite witness"):
            self.summarize()

    def test_candidate_must_execute_staging_and_hit_must_avoid_projection(self):
        self.mutate(change=lambda record: record["witness"].update({"stagingCreates": 0}))
        with self.assertRaisesRegex(BENCH.EvidenceError, "staging absent"):
            self.summarize()
        self.mutate(change=lambda record: record["witness"].update({"stagingCreates": 1}))
        self.mutate(phase="cache-hit", change=lambda record: record["witness"].update({"canonicalStatements": 1}))
        with self.assertRaisesRegex(BENCH.EvidenceError, "cache hit rebuilt"):
            self.summarize()

    def test_cache_counter_mutation_and_complete_arrays_are_required(self):
        for change, message in ((lambda record: record.update({"cacheHitDelta": 0}), "cache-hit proof"),
                                (lambda record: record["afterMutation"].update({"updatedAt": record["output"]["updatedAt"]}), "metadata mutation"),
                                (lambda record: record["afterMutation"].pop("dailyBuckets"), "complete aggregate")):
            with self.subTest(message=message):
                record = self.record("candidate", "cache-hit", 1)
                change(record)
                (self.root / f"candidate-{self.size}-cache-hit-1.log").write_text(self.log(record))
                with self.assertRaisesRegex(BENCH.EvidenceError, message):
                    self.summarize()

    def test_runtime_compiled_source_and_fixture_hashes_must_match_build(self):
        for field in ("fixtureSha256", "productionSourceSha256", "sqlSha256", "pricesSha256"):
            self.mutate(change=lambda record, field=field: record.update({field: "0" * 64}))
            with self.assertRaisesRegex(BENCH.EvidenceError, "identity"):
                self.summarize()
            (self.root / f"candidate-{self.size}-cold-1.log").write_text(self.log(self.record("candidate", "cold", 1)))

    def test_binary_seed_and_fixture_drift_are_rejected(self):
        for target, message in ((self.root / "candidate-binary", "binary missing/drifted"),
                                (self.root / "synthetic.sqlite", "seed artifact drift")):
            original = target.read_bytes()
            target.write_bytes(original + b"drift")
            with self.assertRaisesRegex(BENCH.EvidenceError, message):
                self.summarize()
            target.write_bytes(original)
        self.manifest["fixtureSha256"] = "0" * 64
        self.save_manifest()
        with self.assertRaisesRegex(BENCH.EvidenceError, "fixture SHA-256"):
            self.summarize()

    def test_failed_commands_nonfinite_metrics_bad_checksum_and_pair_order_are_rejected(self):
        status = self.root / f"candidate-{self.size}-cold-1.exit.json"
        original = status.read_text()
        value = json.loads(original)
        value["commandExitCode"] = 1
        RUNNER.save_json(status, value)
        with self.assertRaisesRegex(BENCH.EvidenceError, "command failed"):
            self.summarize()
        status.write_text(original)
        self.mutate(change=lambda record: record["measurement"].update({"cpuMilliseconds": float("nan")}))
        with self.assertRaisesRegex(BENCH.EvidenceError, "invalid cpuMilliseconds"):
            self.summarize()
        (self.root / f"candidate-{self.size}-cold-1.log").write_text(self.log(self.record("candidate", "cold", 1)))
        self.mutate(change=lambda record: record.update({"checksums": ["0" * 64] * 3}))
        with self.assertRaisesRegex(BENCH.EvidenceError, "repeat checksum"):
            self.summarize()
        (self.root / f"candidate-{self.size}-cold-1.log").write_text(self.log(self.record("candidate", "cold", 1)))
        self.manifest["executionOrder"].reverse()
        self.save_manifest()
        with self.assertRaisesRegex(BENCH.EvidenceError, "execution order"):
            self.summarize()

    def test_source_provenance_rejects_dirty_untracked_and_wrong_commit(self):
        with patch.object(RUNNER, "git", side_effect=["a" * 40, "?? stub.rs"]):
            with self.assertRaisesRegex(BENCH.EvidenceError, "including untracked"):
                RUNNER.source_provenance(self.root, "a" * 40)
        with patch.object(RUNNER, "git", return_value="b" * 40):
            with self.assertRaisesRegex(BENCH.EvidenceError, "requested SHA"):
                RUNNER.source_provenance(self.root, "a" * 40)

    def test_failed_cloud_build_restores_only_exact_fixture_injection(self):
        checkout = self.root / "product"
        source = checkout / RUNNER.SOURCE
        source.parent.mkdir(parents=True)
        original = b"// synthetic restoration control; no Rust compilation\n"
        source.write_bytes(original)
        provenance = {"sourceSha256": hashlib.sha256(original).hexdigest()}
        with patch.object(RUNNER, "git", return_value=""), patch.object(RUNNER, "logged", side_effect=["", "", BENCH.EvidenceError("controlled build failure")]):
            with self.assertRaisesRegex(BENCH.EvidenceError, "controlled build failure"):
                RUNNER.build(checkout, "baseline", provenance, self.root, self.fixture)
        self.assertEqual(source.read_bytes(), original)
        self.assertFalse((checkout / RUNNER.INJECTED).exists())
        self.assertTrue(provenance["cleanAfter"])

        def changed_during_build(*args, **kwargs):
            if args[1] == "baseline-build":
                source.write_bytes(b"// a concurrent edit must survive\n")
                raise BENCH.EvidenceError("controlled failure")
            return ""
        with patch.object(RUNNER, "git", return_value=""), patch.object(RUNNER, "logged", side_effect=changed_during_build):
            with self.assertRaisesRegex(BENCH.EvidenceError, "unsafe restoration"):
                RUNNER.build(checkout, "baseline", {"sourceSha256": hashlib.sha256(original).hexdigest()}, self.root, self.fixture)
        self.assertEqual(source.read_bytes(), b"// a concurrent edit must survive\n")
        self.assertTrue((checkout / RUNNER.INJECTED).exists())

    def test_runner_rejects_local_native_build_before_creating_evidence(self):
        evidence = self.root / "must-not-exist"
        arguments = [sys.executable, str(CLOUD / "run_multi_client_aggregate_benchmark.py"),
                     "--baseline", str(self.root / "base"), "--baseline-sha", "a" * 40,
                     "--candidate", str(self.root / "candidate"), "--candidate-sha", "b" * 40,
                     "--evidence", str(evidence)]
        result = subprocess.run(arguments, env={**os.environ, "GITHUB_ACTIONS": "false"}, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cloud runner", result.stderr)
        self.assertFalse(evidence.exists())

    def test_fixture_has_real_entrypoint_no_extracted_sql_and_untimed_witness(self):
        source = self.fixture.read_text()
        self.assertGreaterEqual(source.count("read_cached_multi_client_aggregates("), 4)
        self.assertNotIn("fn read_cached_multi_client_aggregates", source)
        self.assertNotIn("effective_usage_query(", source)
        self.assertLess(source.index("let after_loop = usage()"), source.index("sqlite3_trace_v2"))
        self.assertIn('include_bytes!("multi_client_usage.rs")', source)
        self.assertIn("total_output(&expected) + 77", source)


if __name__ == "__main__":
    unittest.main()
