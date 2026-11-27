"""Stdlib-only harness checks. These tests never launch or build an App."""
import ctypes
import datetime as dt
import importlib.util
import json
from pathlib import Path
import plistlib
import sqlite3
import tempfile
from types import SimpleNamespace
import unittest
import warnings
from unittest.mock import Mock, call, patch

SPEC = importlib.util.spec_from_file_location("whole_app_benchmark", Path(__file__).with_name("whole_app_benchmark.py"))
bench = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bench)


class WholeAppHarnessTests(unittest.TestCase):
    def test_absent_defaults_domain_can_export_an_empty_plist(self):
        exported = SimpleNamespace(returncode=0, stdout=plistlib.dumps({}))
        absent = SimpleNamespace(returncode=1, stdout=b"")
        env = {"HOME": "/synthetic-home"}
        with patch.object(bench, "command", side_effect=[exported, absent]) as command:
            self.assertIsNone(bench.export_defaults(env))
        self.assertEqual(command.call_count, 2)
        self.assertEqual(command.call_args.args[0], ["/usr/bin/defaults", "read", bench.BUNDLE_ID])
        self.assertEqual(command.call_args.kwargs, {"env": env, "check": False})

    def test_existing_empty_defaults_domain_remains_present(self):
        exported = SimpleNamespace(returncode=0, stdout=plistlib.dumps({}))
        existing = SimpleNamespace(returncode=0, stdout=b"{}")
        with patch.object(bench, "command", side_effect=[exported, existing]):
            self.assertEqual(bench.export_defaults({}), {})

    def test_nonempty_defaults_domain_preserves_values_without_another_query(self):
        value = {"fixture": True}
        with patch.object(bench, "command", return_value=SimpleNamespace(returncode=0, stdout=plistlib.dumps(value))) as command:
            self.assertEqual(bench.export_defaults({}), value)
        command.assert_called_once()

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

    def test_fixture_gives_every_response_an_explicit_start_and_completion(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "source"
            fixture = bench.generate_fixture(root, 2000, 1800000000)
            completed = 0
            ids = set()
            for path in (root / "claudeCode").glob("*.jsonl"):
                rows = [json.loads(line) for line in path.read_bytes().splitlines()]
                self.assertEqual(len(rows) % 2, 0)
                for user, assistant in zip(rows[::2], rows[1::2]):
                    self.assertEqual(user["type"], "user")
                    self.assertEqual(assistant["type"], "assistant")
                    self.assertEqual(user["sessionId"], assistant["sessionId"])
                    self.assertEqual(assistant["message"]["stop_reason"], "end_turn")
                    duration = (dt.datetime.fromisoformat(assistant["timestamp"]) - dt.datetime.fromisoformat(user["timestamp"])).total_seconds()
                    self.assertEqual(duration, 1)
                    ids.add(assistant["message"]["id"])
                    completed += 1
            self.assertEqual(completed, fixture["responses"])
            self.assertEqual(len(ids), completed)
            self.assertEqual(fixture["completedResponses"], completed)
            self.assertEqual(fixture["fixtureSchemaVersion"], 2)

    def test_frame_seed_centers_the_same_viewport_in_the_actual_screen(self):
        geometry = {"frame": {"x": 0, "y": 0, "width": 1920, "height": 1080},
                    "visible": {"x": 0, "y": 48, "width": 1920, "height": 1007}}
        frame = bench.dashboard_frame_seed(geometry)
        self.assertEqual(frame, "340 146 1240 812 0 0 1920 1080 ")
        # Same target rectangle in CG's top-left coordinates.
        window = {"x": 340, "y": 122, "width": 1240, "height": 812}
        self.assertTrue(bench.dashboard_window_fits(window, geometry))
        for key, value in (("x", -1), ("y", 0), ("width", 2000), ("height", 1100), ("x", None)):
            with self.subTest(key=key, value=value):
                self.assertFalse(bench.dashboard_window_fits({**window, key: value}, geometry))
        with self.assertRaisesRegex(bench.BenchError, "cannot contain") as failure:
            bench.dashboard_frame_seed({"frame": geometry["frame"],
                                        "visible": {"x": 0, "y": 0, "width": 1024, "height": 737}})
        self.assertEqual(failure.exception.status, "NOT_RUN")

    def test_display_geometry_reads_only_metadata_and_rejects_invalid_geometry(self):
        geometry = {"frame": {"x": 0, "y": 0, "width": 1920, "height": 1080},
                    "visible": {"x": 0, "y": 48, "width": 1920, "height": 1007}}
        env = {"HOME": "/synthetic-home"}
        with patch.object(bench, "command", return_value=SimpleNamespace(stdout=bench.canonical(geometry))) as command:
            self.assertEqual(bench.display_geometry(env), geometry)
        self.assertEqual(command.call_args.args[0][:3], ["/usr/bin/osascript", "-l", "JavaScript"])
        self.assertNotIn("System Events", command.call_args.args[0][-1])
        self.assertNotIn("setFrame", command.call_args.args[0][-1])
        self.assertEqual(command.call_args.kwargs, {"env": env})
        geometry["visible"]["width"] = "not a number"
        with patch.object(bench, "command", return_value=SimpleNamespace(stdout=bench.canonical(geometry))):
            with self.assertRaisesRegex(bench.BenchError, "invalid main-screen"):
                bench.display_geometry(env)

    def test_native_frame_preference_is_identical_for_both_roles(self):
        with tempfile.TemporaryDirectory() as tmp:
            fixture = Path(tmp) / "fixture"
            bench.generate_fixture(fixture, 20, 1800000000)
            frame = "340 146 1240 812 0 0 1920 1080 "
            seeded = bench.preference_seed(fixture, dashboard_frame=frame)
            self.assertEqual(seeded["NSWindow Frame dashboard"], frame)
            baseline = bench.preference_seed(fixture)
            self.assertEqual({k: v for k, v in seeded.items() if k != "NSWindow Frame dashboard"}, baseline)
            self.assertEqual(plistlib.loads(plistlib.dumps(seeded)), seeded)

    def test_display_mode_stays_owned_until_restore_even_when_frame_validation_fails(self):
        small = {"frame": {"x": 0, "y": 0, "width": 1024, "height": 768},
                 "visible": {"x": 0, "y": 0, "width": 1024, "height": 737}}
        large = {"frame": {"x": 0, "y": 0, "width": 1920, "height": 1080},
                 "visible": {"x": 0, "y": 48, "width": 1920, "height": 1007}}
        for actual in (large, small):
            with self.subTest(frame_validation_succeeds=actual == large):
                widths, heights = {20: 1024, 30: 1920}, {20: 768, 30: 1080}
                cg = SimpleNamespace(
                    CGMainDisplayID=Mock(return_value=1), CGDisplayCopyDisplayMode=Mock(return_value=10),
                    CGDisplayCopyAllDisplayModes=Mock(return_value=100),
                    CGDisplayModeGetWidth=Mock(side_effect=widths.__getitem__),
                    CGDisplayModeGetHeight=Mock(side_effect=heights.__getitem__),
                    CGDisplaySetDisplayMode=Mock(return_value=0), CGDisplayModeRelease=Mock())
                cf = SimpleNamespace(CFArrayGetCount=Mock(return_value=2),
                                     CFArrayGetValueAtIndex=Mock(side_effect=[20, 30]), CFRelease=Mock())
                display = bench.BenchmarkDisplay(SimpleNamespace(cg=cg, cf=cf), {})
                with patch.object(bench, "display_geometry", side_effect=[small, actual]):
                    try:
                        if actual == large:
                            record = display.configure()
                            self.assertTrue(record["modeChanged"])
                            self.assertEqual(record["requestedMode"], {"width": 1920, "height": 1080})
                        else:
                            with self.assertRaises(bench.BenchError) as failure:
                                display.configure()
                            self.assertEqual(failure.exception.status, "NOT_RUN")
                        cg.CGDisplayModeRelease.assert_not_called()
                        cg.CGDisplaySetDisplayMode.assert_called_once_with(1, 30, None)
                    finally:
                        display.restore()
                self.assertEqual(cg.CGDisplaySetDisplayMode.call_args_list,
                                 [call(1, 30, None), call(1, 10, None)])
                cg.CGDisplayModeRelease.assert_called_once_with(10)
                cf.CFRelease.assert_called_once_with(100)
                display.restore()  # A second cleanup cannot release the saved mode twice.
                cg.CGDisplayModeRelease.assert_called_once_with(10)

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

    def test_memory_diagnostics_are_unprivileged_and_preserve_raw_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            completed = SimpleNamespace(returncode=0, stdout=b"synthetic allocation summary\n", stderr=b"warning\n")
            env = {"HOME": "/synthetic-home"}
            with patch.object(bench, "command", return_value=completed) as command:
                evidence = bench.post_measurement_memory_diagnostics(123, root, env)
            self.assertTrue(evidence["outsideMeasurement"])
            self.assertLessEqual(evidence["startedMonotonicNS"], evidence["finishedMonotonicNS"])
            self.assertEqual([call.args[0] for call in command.call_args_list], [
                ["/usr/bin/vmmap", "-summary", "123"], ["/usr/bin/heap", "-s", "--noContent", "123"]])
            for call in command.call_args_list:
                self.assertEqual(call.kwargs, {"env": env, "check": False})
            for entry in evidence["tools"]:
                payload = (root / entry["file"]).read_bytes()
                self.assertEqual(payload, completed.stdout + completed.stderr)
                self.assertEqual(entry["sha256"], bench.digest(payload))
                self.assertEqual(entry["bytes"], len(payload))
                self.assertEqual(entry["status"], "PASS")

    def test_memory_diagnostic_failure_remains_supplemental_and_runs_next_tool(self):
        with tempfile.TemporaryDirectory() as tmp:
            with patch.object(bench, "command", side_effect=[
                    bench.subprocess.TimeoutExpired("vmmap", 30),
                    SimpleNamespace(returncode=1, stdout=b"", stderr=b"permission denied")]) as command:
                evidence = bench.post_measurement_memory_diagnostics(123, Path(tmp), {})
            self.assertEqual(command.call_count, 2)
            self.assertTrue(evidence["outsideMeasurement"])
            self.assertEqual([entry["status"] for entry in evidence["tools"]], ["UNAVAILABLE", "UNAVAILABLE"])
            self.assertEqual((Path(tmp) / "post-measurement-heap.txt").read_bytes(), b"permission denied")

    def test_retained_graph_is_opt_in_and_does_not_change_the_resource_protocol(self):
        argv = ["--baseline-app", "/synthetic/baseline.app", "--candidate-app", "/synthetic/candidate.app",
                "--output-dir", "/synthetic/evidence"]
        original = vars(bench.parse_arguments(argv))
        diagnostic = vars(bench.parse_arguments(argv + ["--retained-graph"]))
        self.assertFalse(original.pop("retained_graph"))
        self.assertTrue(diagnostic.pop("retained_graph"))
        self.assertEqual(diagnostic, original)
        self.assertEqual(original["responses"], [2000, 20000])
        self.assertEqual((original["trials"], original["warmup"], original["duration"]), (3, 120, 120))

    def test_retained_graph_preserves_no_content_output_and_exact_tool_arguments(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            payload = b"synthetic no-content reference tree: 0x1234 owner\n"
            completed = SimpleNamespace(returncode=0, stdout=payload, stderr=b"")
            env = {"HOME": "/synthetic-home"}
            with patch.object(bench, "command", return_value=completed) as command:
                evidence = bench.post_measurement_memory_diagnostics(123, root, env, retained_graph=True)
            self.assertTrue(evidence["outsideMeasurement"])
            self.assertEqual([call.args[0] for call in command.call_args_list], [
                ["/usr/bin/vmmap", "-summary", "123"], ["/usr/bin/heap", "-s", "--noContent", "123"],
                ["/usr/bin/leaks", "--noContent", "--nostacks", "--groupByType", "--referenceTree", "123"]])
            for call in command.call_args_list:
                self.assertEqual(call.kwargs, {"env": env, "check": False})
            graph = evidence["tools"][-1]
            self.assertEqual(graph["tool"], "retained-graph")
            self.assertEqual(graph["status"], "PASS")
            self.assertFalse(graph["leaksDetectedByTool"])
            self.assertIn("not all retaining references", graph["relationshipModel"])
            self.assertEqual(graph["bytes"], len(payload))
            self.assertEqual(graph["sha256"], bench.digest(payload))
            self.assertEqual((root / graph["file"]).read_bytes(), payload)

    def test_retained_graph_unavailability_does_not_fail_completed_measurements(self):
        for failure in (SimpleNamespace(returncode=2, stdout=b"partial tree\n", stderr=b"unavailable\n"),
                        bench.subprocess.TimeoutExpired("leaks", 30, output=b"partial tree\n")):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as tmp:
                ok = SimpleNamespace(returncode=0, stdout=b"summary\n", stderr=b"")
                with patch.object(bench, "command", side_effect=[ok, ok, failure]) as command:
                    evidence = bench.post_measurement_memory_diagnostics(123, Path(tmp), {}, retained_graph=True)
                self.assertEqual(command.call_count, 3)
                self.assertEqual([x["status"] for x in evidence["tools"]], ["PASS", "PASS", "UNAVAILABLE"])
                graph = evidence["tools"][-1]
                raw = (Path(tmp) / graph["file"]).read_bytes()
                self.assertTrue(raw.startswith(b"partial tree\n"))
                self.assertEqual(graph["sha256"], bench.digest(raw))
                self.assertEqual(graph["bytes"], len(raw))

    def test_retained_graph_keeps_a_completed_leak_finding_distinct_from_collection_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            ok = SimpleNamespace(returncode=0, stdout=b"summary\n", stderr=b"")
            finding = SimpleNamespace(returncode=1, stdout=b"synthetic reference tree\n", stderr=b"")
            with patch.object(bench, "command", side_effect=[ok, ok, finding]):
                evidence = bench.post_measurement_memory_diagnostics(123, Path(tmp), {}, retained_graph=True)
            graph = evidence["tools"][-1]
            self.assertEqual(graph["status"], "PASS")
            self.assertEqual(graph["returnCode"], 1)
            self.assertTrue(graph["leaksDetectedByTool"])

    def test_first_rejected_window_is_preserved_before_the_gate_raises(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app, home, output, fixture_root = [root / name for name in ("source.app", "home", "out", "fixture")]
            app.mkdir()
            home.mkdir()
            output.mkdir()
            fixture = bench.generate_fixture(fixture_root, 20, 1800000000)
            geometry = {"frame": {"x": 0, "y": 0, "width": 1920, "height": 1080},
                        "visible": {"x": 0, "y": 48, "width": 1920, "height": 1007}}
            display = SimpleNamespace(frame_seed=bench.dashboard_frame_seed(geometry), record={"after": geometry})
            seed = bench.preference_seed(fixture_root, dashboard_frame=display.frame_seed)
            rejected = {"x": 0, "y": -75, "width": 1080, "height": 812}
            process = Mock(pid=123, returncode=-15)
            process.poll.return_value = None
            process.wait.return_value = -15
            args = SimpleNamespace(startup_timeout=300, warmup=120, duration=120)
            with patch.object(bench, "product_processes", return_value=[]), \
                    patch.object(bench, "export_defaults", side_effect=[None, seed]), \
                    patch.object(bench, "command"), \
                    patch.object(bench, "bundle_manifest", return_value={"executable": "CodexTokenBar"}), \
                    patch.object(bench.subprocess, "Popen", return_value=process), \
                    patch.object(bench, "ProcessSampler", return_value=SimpleNamespace(sample=lambda: {"cpuNS": 0})), \
                    patch.object(bench, "startup_ready", return_value={"ready": True}), \
                    patch.object(bench, "ledger_truth", return_value={"complete": True}), \
                    patch.object(bench, "archive_state", return_value={"archived": True}), \
                    patch.object(bench, "post_measurement_memory_diagnostics") as diagnostics:
                with self.assertRaisesRegex(bench.BenchError, "dimensions differ") as failure:
                    bench.run_trial("baseline", 1, app, root / "runtime.app", home, fixture_root,
                                    fixture, {}, args, output, SimpleNamespace(windows=lambda _: [rejected]), display)
            self.assertEqual(failure.exception.status, "NOT_RUN")
            diagnostics.assert_not_called()
            run = output / "20-1-baseline"
            samples = [json.loads(line) for line in (run / "metrics.jsonl").read_text().splitlines()]
            self.assertEqual(len(samples), 1)
            self.assertEqual(samples[0]["dashboardWindows"], [rejected])
            self.assertEqual(samples[0]["phase"], "bootstrap")
            self.assertEqual(json.loads((run / "result.json").read_text())["status"], "NOT_RUN")

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

    def test_pair_rejects_diagnostic_or_instrumented_results_before_comparing_metrics(self):
        for marker in ({"purpose": "allocation-diagnostic"}, {"performanceComparable": False},
                       {"instrumentation": {"MallocStackLogging": "1"}}):
            with self.subTest(marker=marker), self.assertRaisesRegex(bench.BenchError, "diagnostic trials"):
                bench.paired_summary([marker])

    def test_instrumented_trial_launch_isolated_from_helpers_and_capture_after_last_sample(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app, home, output, fixture_root = [root / name for name in ("source.app", "home", "out", "fixture")]
            app.mkdir()
            home.mkdir()
            output.mkdir()
            fixture = bench.generate_fixture(fixture_root, 20, 1800000000)
            geometry = {"frame": {"x": 0, "y": 0, "width": 1920, "height": 1080},
                        "visible": {"x": 0, "y": 48, "width": 1920, "height": 1007}}
            display = SimpleNamespace(frame_seed=bench.dashboard_frame_seed(geometry), record={"after": geometry})
            seed = bench.preference_seed(fixture_root, dashboard_frame=display.frame_seed)
            visible = [{"x": 340, "y": 122, **bench.DASHBOARD_WINDOW}]
            process = Mock(pid=123, returncode=-15)
            process.poll.return_value = None
            process.wait.return_value = -15
            rows = [{"monotonicNS": i * 1000000000, "cpuNS": i * 1000,
                     "rssBytes": 10, "footprintBytes": 20, "lifetimePeakFootprintBytes": 30} for i in range(3)]
            sampler = Mock(side_effect=rows)
            env = {"HOME": str(home)}
            app_env = dict(env, MallocStackLogging="1")
            run = output / "20-1-candidate"

            def capture(child, directory, helper_env):
                self.assertIs(child, process)
                self.assertEqual(directory, run)
                self.assertIs(helper_env, env)
                self.assertEqual(sampler.call_count, 3)
                self.assertEqual(len((run / "metrics.jsonl").read_text().splitlines()), 3)
                return {"status": "COLLECTED", "startedMonotonicNS": 3000000000}

            with patch.object(bench, "product_processes", return_value=[]), \
                    patch.object(bench, "export_defaults", side_effect=[None, seed]), \
                    patch.object(bench, "command") as command, \
                    patch.object(bench, "bundle_manifest", return_value={"executable": "CodexTokenBar"}), \
                    patch.object(bench.subprocess, "Popen", return_value=process) as launch, \
                    patch.object(bench, "ProcessSampler", return_value=SimpleNamespace(sample=sampler)), \
                    patch.object(bench, "startup_ready", return_value={"ready": True}), \
                    patch.object(bench, "ledger_truth", return_value={"complete": True}), \
                    patch.object(bench, "archive_state", return_value={"archived": True}), \
                    patch.object(bench.time, "sleep"), \
                    patch.object(bench.time, "monotonic", side_effect=range(30)):
                result = bench.run_trial("candidate", 1, app, root / "runtime.app", home, fixture_root,
                                         fixture, env, SimpleNamespace(startup_timeout=300, warmup=0, duration=1),
                                         output, SimpleNamespace(windows=lambda _: visible), display,
                                         app_env=app_env, post_sample=capture, purpose="allocation-diagnostic")
            self.assertIs(launch.call_args.kwargs["env"], app_env)
            self.assertIs(command.call_args.kwargs["env"], env)
            self.assertNotIn("MallocStackLogging", env)
            self.assertEqual(sampler.call_count, 3)
            self.assertLess(result["measurementEndedMonotonicNS"],
                            result["postMeasurementMemoryDiagnostics"]["startedMonotonicNS"])
            self.assertFalse(result["performanceComparable"])
            self.assertEqual(result["performanceVerdict"], "NOT_EVALUATED")
            self.assertEqual(result["instrumentation"], {"MallocStackLogging": "1"})
            self.assertEqual(len((run / "metrics.jsonl").read_text().splitlines()), 3)

    def test_logging_cannot_be_enabled_in_a_normal_acceptance_trial(self):
        with self.assertRaisesRegex(bench.BenchError, "resource acceptance"):
            bench.run_trial(None, None, None, None, None, None, None, {}, None, None, None, None,
                            app_env={"MallocStackLogging": "1"})


if __name__ == "__main__":
    unittest.main()
