"""Stdlib-only harness checks. These tests never launch or build an App."""
import ctypes
import importlib.util
import json
from pathlib import Path
import plistlib
import sqlite3
import tempfile
from types import SimpleNamespace
import unittest
import warnings
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("whole_app_benchmark", Path(__file__).with_name("whole_app_benchmark.py"))
bench = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bench)


class WholeAppHarnessTests(unittest.TestCase):
    def test_rusage_abi_has_uuid_and_35_uint64_fields(self):
        self.assertEqual(len(bench.RU_FIELDS), 35)
        self.assertEqual(ctypes.sizeof(bench.RUsage), 296)

    def test_local_invocation_refuses_before_any_process_call(self):
        with patch.object(bench.platform, "system", return_value="Darwin"), patch.dict(bench.os.environ, {}, clear=True), patch.object(bench.subprocess, "run") as run:
            with self.assertRaisesRegex(bench.BenchError, "disposable GitHub Actions"):
                bench.guard_host(Path("/tmp/output"))
            run.assert_not_called()

    def test_refusal_cannot_write_into_existing_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp)
            sentinel = output / "summary.json"
            sentinel.write_text("preserve this")
            with patch.object(bench.platform, "system", return_value="Other"), patch("builtins.print"):
                status = bench.main(["--baseline-app", "/missing/baseline.app", "--candidate-app", "/missing/candidate.app",
                                     "--output-dir", str(output)])
            self.assertEqual(status, 2)
            self.assertEqual(sentinel.read_text(), "preserve this")

    def test_missing_gui_records_not_run_without_launching_app(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            home, runner_temp, output = root / "home", root / "runner", root / "evidence"
            home.mkdir()
            runner_temp.mkdir()
            with patch.object(bench, "guard_host", return_value=(home, runner_temp)), patch.object(bench, "command", return_value=SimpleNamespace(returncode=1)), patch.object(bench.subprocess, "Popen") as launch, patch("builtins.print"):
                status = bench.main(["--baseline-app", "/missing/baseline.app", "--candidate-app", "/missing/candidate.app",
                                     "--output-dir", str(output)])
            self.assertEqual(status, 2)
            self.assertEqual(json.loads((output / "summary.json").read_text())["status"], "NOT_RUN")
            launch.assert_not_called()

    def test_fixture_is_deterministic_and_has_no_credentials(self):
        with tempfile.TemporaryDirectory() as tmp:
            a, b = Path(tmp) / "a", Path(tmp) / "b"
            fixture = bench.generate_fixture(a, 2000, 1800000000)
            other = bench.generate_fixture(b, 2000, 1800000000)
            self.assertEqual(fixture["expectedLedgerSha256"], other["expectedLedgerSha256"])
            self.assertEqual(fixture["expectedTotals"]["count"], 2000)
            self.assertEqual(len(list(a.rglob("*.jsonl"))), 20)
            self.assertFalse(any("auth" in p.name or "credential" in p.name for p in a.rglob("*")))
            for path in a.rglob("*.jsonl"):
                self.assertEqual(path.read_bytes(), (b / path.relative_to(a)).read_bytes())
            with self.assertRaises(bench.BenchError):
                bench.generate_fixture(a, 2000, 1800000000)
            before = fixture["source"]
            (a / "claudeCode/session-00.jsonl").write_bytes(b"changed\n")
            self.assertNotEqual(before, bench.source_inventory(a))

    def test_preference_seed_uses_explicit_sources_and_normal_defaults(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "fixture"
            bench.generate_fixture(root, 20, 1800000000)
            seed = bench.preference_seed(root)
            clients = json.loads(seed["multiClientUsage.preferences.v1"])
            self.assertEqual([r["client"] for r in clients if r["enabled"]], ["claudeCode"])
            self.assertTrue(all(r["path"] == str(root / r["client"]) for r in clients))
            self.assertTrue(clients[0]["showSidebar"] and clients[0]["showMenuBar"] and clients[0]["showQuota"])
            self.assertEqual(seed["CodexTokenBar.selectedCodexHomeDeviceID"], str((root / "empty-codex").stat().st_dev))
            self.assertEqual(seed["CodexTokenBar.selectedCodexHomeFileID"], str((root / "empty-codex").stat().st_ino))
            self.assertFalse(seed["agentSpeedReporting.enabled.v1"])
            self.assertNotIn("SUEnableAutomaticChecks", seed)
            self.assertEqual(plistlib.loads(plistlib.dumps(seed)), seed)
            env = bench.clean_environment(Path(tmp), root, Path("/tmp"))
            self.assertEqual(env["HOME"], tmp)
            self.assertNotIn("GITHUB_TOKEN", env)
            self.assertNotIn("OPENAI_API_KEY", env)
            self.assertNotIn("HTTPS_PROXY", env)
            self.assertEqual(env["CODEX_HOME"], str(root / "empty-codex"))

    def test_ledger_digest_includes_all_stable_columns_and_rejects_wrong_totals(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fixture = bench.generate_fixture(root / "source", 2000, 1800000000)
            path = root / "synthetic.sqlite"
            connection = sqlite3.connect(path)
            connection.execute("CREATE TABLE client_usage_events (client,event_id,session_id,model,timestamp,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,reasoning_tokens)")
            rows = bench.expected_rows(2000, 1800000000)
            connection.executemany("INSERT INTO client_usage_events VALUES (?,?,?,?,?,?,?,?,?,?)",
                                   [row[:4] + [row[4] / 1000] + row[5:] for row in rows])
            connection.commit()
            with warnings.catch_warnings():
                warnings.simplefilter("error", ResourceWarning)
                truth = bench.ledger_truth(path, fixture)
            self.assertTrue(truth["complete"])
            self.assertEqual(truth["sha256"], fixture["expectedLedgerSha256"])
            connection.execute("UPDATE client_usage_events SET output_tokens=output_tokens+1 WHERE rowid=1")
            connection.commit()
            self.assertFalse(bench.ledger_truth(path, fixture)["complete"])
            connection.close()

    def test_ready_requires_started_event_for_exact_pid_and_session(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            journal = root / "events-one.jsonl"
            ready = {"area": "startup", "phase": "ready", "session": "right"}
            started = {"area": "startup", "phase": "started", "session": "right", "metrics": {"pid": 123}}
            journal.write_bytes(bench.canonical(ready) + b"\n")
            self.assertIsNone(bench.startup_ready(root, 123))
            journal.write_bytes(bench.canonical(started) + b"\n" + bench.canonical(ready) + b"\n{partial")
            self.assertEqual(bench.startup_ready(root, 123), ready)
            self.assertIsNone(bench.startup_ready(root, 124))

    def test_owned_paths_do_not_include_other_apps(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            ours = root / "Library/Application Support/CodexTokenBarSwift"
            other = root / "Library/Application Support/OtherApp"
            ours.mkdir(parents=True)
            other.mkdir()
            self.assertEqual(bench.owned_paths(root), [ours])

    def test_archive_renames_only_generated_product_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            home = root / "home"
            state = home / "Library/Application Support/CodexTokenBar"
            state.mkdir(parents=True)
            (state / "synthetic.txt").write_text("synthetic only")
            before = (state / "synthetic.txt").stat().st_ino
            with patch.object(bench, "export_defaults", side_effect=[{"fixture": True}, None]), patch.object(bench, "command") as command:
                result = bench.archive_state(home, root / "archive", {})
            archived = root / "archive/Library/Application Support/CodexTokenBar/synthetic.txt"
            self.assertEqual(archived.stat().st_ino, before)
            self.assertFalse(state.exists())
            self.assertEqual(result["renamed"], ["Library/Application Support/CodexTokenBar"])
            self.assertEqual(plistlib.loads((root / "archive/defaults-export.plist").read_bytes()), {"fixture": True})
            command.assert_called_once()

    def test_process_inventory_excludes_unrelated_arguments(self):
        text = b"1 /sbin/launchd\n2 /tmp/runtime/Codex Token Bar.app/Contents/MacOS/CodexTokenBar\n3 /tmp/runtime/Codex Token Bar.app/Contents/XPCServices/helper\n4 /Applications/Other.app/Contents/MacOS/Other\n"
        with patch.object(bench, "command", return_value=SimpleNamespace(stdout=text)):
            rows = bench.product_processes(Path("/tmp/runtime/Codex Token Bar.app"))
        self.assertEqual([r["pid"] for r in rows], [2, 3])

    def test_statistics_use_counter_deltas_and_report_gaps(self):
        rows = [{"monotonicNS": i * 1000000000, "cpuNS": i * 200000000,
                 "rssBytes": v, "footprintBytes": v * 2} for i, v in enumerate([10, 20, 30, 40])]
        result = bench.summarize(rows)
        self.assertEqual(result["cpuSeconds"], 0.6)
        self.assertEqual(result["averageCPUPercentOneCore"], 20)
        self.assertEqual(result["rssBytes"]["median"], 25)
        self.assertEqual(result["rssBytes"]["p95"], 40)
        self.assertEqual(result["maxGapSeconds"], 1)

    def test_pair_requires_same_settings_sources_and_window(self):
        def row(role):
            return {"role": role, "responses": 2000, "trial": 1,
                    "settingsSeedSha256": "settings", "sourceSha256": "source",
                    "dashboardWindow": {"width": 1240, "height": 1000},
                    "measurement": {"cpuSeconds": 2, "footprintBytes": {"median": 10}, "rssBytes": {"median": 12}}}
        a, b = row("baseline"), row("candidate")
        self.assertEqual(bench.paired_summary([a, b])[0]["cpuSecondsRatio"], 1)
        b["sourceSha256"] = "different"
        with self.assertRaisesRegex(bench.BenchError, "sourceSha256"):
            bench.paired_summary([a, b])


if __name__ == "__main__":
    unittest.main()
