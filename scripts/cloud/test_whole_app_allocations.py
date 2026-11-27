"""Stdlib-only allocation diagnostics checks; never build or launch an App."""
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch


SCRIPT_DIR = Path(__file__).parent


def load_allocations(name="whole_app_allocations_test_subject"):
    spec = importlib.util.spec_from_file_location(name, SCRIPT_DIR / "whole_app_allocations.py")
    module = importlib.util.module_from_spec(spec)
    with patch.object(sys, "path", [str(SCRIPT_DIR), *sys.path]):
        spec.loader.exec_module(module)
    return module


with patch.object(subprocess, "Popen", side_effect=AssertionError("import attempted to launch a process")), \
        patch.object(subprocess, "run", side_effect=AssertionError("import attempted to run a command")), \
        patch.object(ctypes, "CDLL", side_effect=AssertionError("import attempted to load native code")):
    alloc = load_allocations()


class AllocationParserTests(unittest.TestCase):
    def test_heap_parser_accepts_only_closed_address_records(self):
        text = (
            "Process 4321: 40 zones, 262144 bytes\n"
            "  0x1234: malloc (262144 bytes)\n"
            "0x5678: Swift object (48 bytes)\n"
            "0xabcdef: malloc (0 bytes)\n"
            "0x90: malloc (16 bytes) trailing object contents\n"
            "0xzz: malloc (16 bytes)\n"
            "0x91: malloc (-1 bytes)\n"
            "0x92: malloc (1,024 bytes)\n"
            "prefix 0x93: malloc (16 bytes)\n"
            "0x94: malloc (16 bytes)"
        )
        self.assertEqual(alloc.parse_heap_addresses(text), [
            {"address": "0x1234", "heapType": "malloc", "heapAllocatedBytes": 262144},
            {"address": "0x5678", "heapType": "Swift object", "heapAllocatedBytes": 48},
            {"address": "0xabcdef", "heapType": "malloc", "heapAllocatedBytes": 0},
        ])

    def test_heap_addresses_are_deduplicated_and_capped_at_four(self):
        text = "0x1: first type (16 bytes)\n0x1: duplicate type (32 bytes)\n" + "".join(
            f"0x{number:x}: malloc ({number * 16} bytes)\n" for number in range(2, 10)
        )
        self.assertEqual([row["address"] for row in alloc.parse_heap_addresses(text)],
                         ["0x9", "0x8", "0x7", "0x6"])
        duplicate = alloc.parse_heap_addresses("0x1: first type (16 bytes)\n0x1: duplicate type (32 bytes)\n")
        self.assertEqual(duplicate, [{"address": "0x1", "heapType": "first type", "heapAllocatedBytes": 16}])
        self.assertEqual(len(alloc.parse_heap_addresses(text, limit=2)), 2)
        self.assertEqual(len(alloc.parse_heap_addresses(text, limit=100)), 4)
        self.assertEqual(alloc.parse_heap_addresses(text, limit=0), [])

    def test_heap_parser_does_not_use_numbers_or_summary_rows_as_addresses(self):
        self.assertEqual(alloc.parse_heap_addresses(
            "262144 bytes in 20 allocations\n"
            "0x1234 is mentioned in a diagnostic\n"
            "malloc 0x2345 (16 bytes)\n"
            "0x1234: malloc (16 bytes)"
        ), [])

    def test_heap_selection_preserves_near_80k_and_exact_64k_beyond_the_largest_four(self):
        rows = [("0x1", 1048576), ("0x2", 524288), ("0x3", 262144), ("0x4", 131072),
                ("0x80a", 90112), ("0x80b", 81921), ("0x80c", 77824), ("0x64", 65536)]
        text = "".join(f"{address}: malloc ({size} bytes)\n" for address, size in rows)
        self.assertEqual([row["address"] for row in alloc.parse_heap_addresses(text)],
                         ["0x1", "0x2", "0x3", "0x4"])
        selected = alloc.select_heap_addresses(text)
        self.assertEqual([row["address"] for row in selected], ["0x1", "0x2", "0x80b", "0x64"])
        self.assertEqual([row["heapAllocatedBytes"] for row in selected], [1048576, 524288, 81921, 65536])

    def test_heap_selection_fills_missing_buckets_from_remaining_largest_blocks(self):
        large = [("0x1", 524288), ("0x2", 393216), ("0x3", 262144), ("0x4", 131072)]
        cases = [
            ("both buckets missing", large, ["0x1", "0x2", "0x3", "0x4"]),
            ("80k missing", large + [("0x64", 65536)], ["0x1", "0x2", "0x64", "0x3"]),
            ("64k missing", large + [("0x80", 86016)], ["0x1", "0x2", "0x80", "0x3"]),
            ("fewer than four unique blocks", [("0x1", 524288), ("0x80", 81920), ("0x64", 65536)],
             ["0x1", "0x80", "0x64"]),
        ]
        for label, rows, expected in cases:
            with self.subTest(case=label):
                text = "".join(f"{address}: malloc ({size} bytes)\n" for address, size in rows)
                self.assertEqual([row["address"] for row in alloc.select_heap_addresses(text)], expected)

    def test_history_keeps_group_counts_bytes_and_original_frames(self):
        first_frame = "    0 libswiftCore.dylib 0x1234 swift_allocObject + 8"
        second_frame = "    1 CodexTokenBar 0x5678 fixtureFunction + 24"
        groups = alloc.parse_history_groups(
            "malloc_history output for process 4321\n"
            "1 call for 32 bytes:\n" + first_frame + "\n" + second_frame + "\n"
            "\n2 calls for 96 bytes:\n" + first_frame + "\n"
        )
        self.assertEqual(len(groups), 2)
        self.assertEqual((groups[0]["allocationCount"], groups[0]["totalBytes"]), (1, 32))
        self.assertEqual((groups[1]["allocationCount"], groups[1]["totalBytes"]), (2, 96))
        self.assertIn(first_frame, groups[0]["frameLines"])
        self.assertIn(second_frame, groups[0]["frameLines"])
        self.assertTrue(all(alloc.has_stack(group) for group in groups))

    def test_history_accepts_inline_frames_but_does_not_invent_empty_stacks(self):
        inline = "0 libswiftCore.dylib 0x1234 swift_allocObject + 8"
        groups = alloc.parse_history_groups(
            "3 calls for 144 bytes: " + inline + "\n"
            "1 call for 16 bytes:\nNo stack logging data\n"
        )
        self.assertEqual(len(groups), 2)
        self.assertTrue(alloc.has_stack(groups[0]))
        self.assertTrue(any(inline in line for line in groups[0]["frameLines"]))
        self.assertFalse(alloc.has_stack(groups[1]))

    def test_history_rejects_malformed_headers_and_incomplete_final_frames(self):
        self.assertEqual(alloc.parse_history_groups(
            "1 allocations for 32 bytes:\n"
            "    0 libswiftCore.dylib 0x1234 swift_allocObject + 8\n"
            "2 calls for -32 bytes:\n"
            "2 calls for 1,024 bytes:\n"
            "2 calls for 32 bytes"
        ), [])
        groups = alloc.parse_history_groups(
            "1 call for 16 bytes:\n"
            "    0 libswiftCore.dylib 0x1234 swift_allocObject + 8"
        )
        self.assertEqual(len(groups), 1)
        self.assertFalse(alloc.has_stack(groups[0]))

    def test_error_messages_with_hex_addresses_do_not_count_as_stack_frames(self):
        groups = alloc.parse_history_groups(
            "1 call for 32 bytes:\n"
            "No stack logging data for 0x1234\n"
            "Cannot examine 0x1234: permission denied\n"
            "Error: 0 libswiftCore.dylib 0x1234 swift_allocObject + 8\n"
        )
        self.assertEqual(len(groups), 1)
        self.assertFalse(alloc.has_stack(groups[0]))


class BoundedCaptureTests(unittest.TestCase):
    def assert_capture_record(self, entry, destination, payload, *, status):
        self.assertEqual(destination.read_bytes(), payload)
        self.assertEqual(entry["bytes"], len(payload))
        self.assertEqual(entry["sha256"], hashlib.sha256(payload).hexdigest())
        self.assertEqual(Path(entry["file"]).name, destination.name)
        self.assertEqual(entry["status"], status)
        self.assertIsInstance(entry["startedMonotonicNS"], int)
        self.assertIsInstance(entry["finishedMonotonicNS"], int)
        self.assertLessEqual(entry["startedMonotonicNS"], entry["finishedMonotonicNS"])

    def test_stdout_and_stderr_share_the_same_bounded_raw_evidence(self):
        argv = [sys.executable, "-c",
                "import os; os.write(1, b'stdout-line\\n'); os.write(2, b'stderr-line\\n')"]
        with tempfile.TemporaryDirectory() as tmp:
            destination = Path(tmp) / "capture.txt"
            entry = alloc.bounded_capture(argv, {}, destination, timeout=3, max_bytes=1024)
            payload = destination.read_bytes()
            self.assert_capture_record(entry, destination, payload, status="COLLECTED")
            self.assertCountEqual(payload.splitlines(), [b"stdout-line", b"stderr-line"])
        self.assertEqual(entry["argv"], argv)
        self.assertEqual(entry["returnCode"], 0)
        self.assertFalse(entry["timedOut"])
        self.assertFalse(entry["truncated"])

    def test_nonzero_exit_keeps_stderr_and_is_unavailable(self):
        argv = [sys.executable, "-c", "import os,sys; os.write(2,b'permission denied\\n'); sys.exit(7)"]
        with tempfile.TemporaryDirectory() as tmp:
            destination = Path(tmp) / "denied.txt"
            entry = alloc.bounded_capture(argv, {}, destination, timeout=3, max_bytes=1024)
            self.assert_capture_record(entry, destination, b"permission denied\n", status="UNAVAILABLE")
        self.assertEqual(entry["returnCode"], 7)
        self.assertFalse(entry["timedOut"])
        self.assertFalse(entry["truncated"])

    def test_exact_output_limit_is_not_a_truncation(self):
        limit = 4096
        argv = [sys.executable, "-c", f"import os; os.write(1,b'x'*{limit})"]
        with tempfile.TemporaryDirectory() as tmp:
            destination = Path(tmp) / "exact.txt"
            entry = alloc.bounded_capture(argv, {}, destination, timeout=3, max_bytes=limit)
            self.assert_capture_record(entry, destination, b"x" * limit, status="COLLECTED")
        self.assertFalse(entry["truncated"])

    def test_overflow_preserves_only_the_allowed_raw_prefix(self):
        limit = 4096
        argv = [sys.executable, "-c", "import os; os.write(1,b'x'*2097152)"]
        with tempfile.TemporaryDirectory() as tmp:
            destination = Path(tmp) / "overflow.txt"
            entry = alloc.bounded_capture(argv, {}, destination, timeout=3, max_bytes=limit)
            self.assert_capture_record(entry, destination, b"x" * limit, status="UNAVAILABLE")
        self.assertTrue(entry["truncated"])
        self.assertLessEqual(entry["bytes"], limit)

    def test_stdout_and_stderr_use_one_shared_limit(self):
        limit = 4096
        argv = [sys.executable, "-c", "import os; os.write(1,b'x'*2048); os.write(2,b'y'*65536)"]
        with tempfile.TemporaryDirectory() as tmp:
            destination = Path(tmp) / "combined-overflow.txt"
            entry = alloc.bounded_capture(argv, {}, destination, timeout=3, max_bytes=limit)
            payload = destination.read_bytes()
            self.assert_capture_record(entry, destination, payload, status="UNAVAILABLE")
        self.assertTrue(entry["truncated"])
        self.assertEqual(len(payload), limit)
        self.assertLessEqual(payload.count(b"x"), 2048)
        self.assertEqual(payload.count(b"x") + payload.count(b"y"), limit)

    def test_timeout_kills_and_reaps_the_exact_harmless_child(self):
        argv = [sys.executable, "-c",
                "import os,time; os.write(1,('pid:'+str(os.getpid())+'\\n').encode()); time.sleep(30)"]
        with tempfile.TemporaryDirectory() as tmp:
            destination = Path(tmp) / "timeout.txt"
            started = time.monotonic()
            entry = alloc.bounded_capture(argv, {}, destination, timeout=0.5, max_bytes=1024)
            elapsed = time.monotonic() - started
            payload = destination.read_bytes()
            self.assert_capture_record(entry, destination, payload, status="UNAVAILABLE")
        self.assertTrue(entry["timedOut"])
        self.assertFalse(entry["truncated"])
        self.assertIsNotNone(entry["returnCode"])
        self.assertLess(elapsed, 5)
        self.assertTrue(payload.startswith(b"pid:"))
        child_pid = int(payload.removeprefix(b"pid:").strip())
        with self.assertRaises(ProcessLookupError):
            os.kill(child_pid, 0)

    def test_supplied_environment_does_not_inherit_parent_variables(self):
        code = ("import json,os; print(json.dumps({'requested':os.environ.get('ALLOCATION_TEST_VALUE'),"
                "'parent':os.environ.get('ALLOCATION_TEST_PARENT_ONLY')}))")
        env = {"ALLOCATION_TEST_VALUE": "synthetic"}
        with tempfile.TemporaryDirectory() as tmp:
            destination = Path(tmp) / "environment.txt"
            with patch.dict(os.environ, {"ALLOCATION_TEST_PARENT_ONLY": "must-not-leak"}):
                entry = alloc.bounded_capture([sys.executable, "-c", code], env, destination,
                                              timeout=3, max_bytes=1024)
            self.assertEqual(json.loads(destination.read_bytes()), {"requested": "synthetic", "parent": None})
        self.assertEqual(entry["status"], "COLLECTED")
        self.assertEqual(env, {"ALLOCATION_TEST_VALUE": "synthetic"})

    def test_missing_executable_is_unavailable_with_bounded_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            destination = Path(tmp) / "missing.txt"
            entry = alloc.bounded_capture([str(Path(tmp) / "does-not-exist")], {}, destination,
                                          timeout=3, max_bytes=128)
            payload = destination.read_bytes()
            self.assert_capture_record(entry, destination, payload, status="UNAVAILABLE")
        self.assertLessEqual(len(payload), 128)
        self.assertFalse(entry["timedOut"])


class AllocationCollectorTests(unittest.TestCase):
    FRAME = "    0 libswiftCore.dylib 0x1234 swift_allocObject + 8\n"

    def capture_plan(self, specifications):
        captures = []

        def capture(argv, env, destination, timeout, max_bytes):
            index = len(captures)
            self.assertLess(index, len(specifications), "collector exceeded the planned tool calls")
            specification = specifications[index]
            payload = specification.get("payload", b"")
            destination = Path(destination)
            destination.write_bytes(payload)
            return_code = specification.get("returnCode", 0)
            truncated = specification.get("truncated", False)
            timed_out = specification.get("timedOut", False)
            started = time.monotonic_ns()
            record = {"argv": list(argv), "file": destination.name, "bytes": len(payload),
                      "sha256": hashlib.sha256(payload).hexdigest(), "returnCode": return_code,
                      "timedOut": timed_out, "truncated": truncated,
                      "status": "COLLECTED" if return_code == 0 and not truncated and not timed_out else "UNAVAILABLE",
                      "startedMonotonicNS": started, "finishedMonotonicNS": time.monotonic_ns()}
            captures.append({"argv": list(argv), "env": env, "destination": destination,
                             "timeout": timeout, "max_bytes": max_bytes, "record": record})
            return record

        return captures, capture

    def test_collection_queries_no_more_than_four_exact_addresses_with_clean_env(self):
        heap = "".join(f"0x{number:x}: type-{number} ({number * 32} bytes)\n" for number in range(1, 9))
        history = ("1 call for 32 bytes:\n" + self.FRAME).encode()
        captures, capture = self.capture_plan([{"payload": heap.encode()}] + [{"payload": history}] * 4)
        process = SimpleNamespace(pid=4321, poll=Mock(return_value=None))
        env = {"HOME": "/synthetic-home", "PATH": "/usr/bin:/bin"}
        before = dict(env)
        with tempfile.TemporaryDirectory() as tmp, patch.object(alloc, "bounded_capture", side_effect=capture):
            evidence = alloc.collect_allocations(process, Path(tmp), env)
            self.assertEqual(evidence["status"], "COLLECTED")
            self.assertTrue(evidence["outsideMeasurement"])
            self.assertEqual(len(evidence["tools"]), 5)
            self.assertEqual([entry["address"] for entry in evidence["allocations"]],
                             ["0x8", "0x7", "0x6", "0x5"])
            self.assertEqual([entry["heapType"] for entry in evidence["allocations"]],
                             ["type-8", "type-7", "type-6", "type-5"])
            self.assertEqual([entry["heapAllocatedBytes"] for entry in evidence["allocations"]], [256, 224, 192, 160])
            for captured in captures:
                self.assertIs(captured["env"], env)
                self.assertEqual(captured["destination"].stat().st_size, captured["record"]["bytes"])
        self.assertEqual(env, before)
        self.assertNotIn("MallocStackLogging", env)
        self.assertEqual(captures[0]["argv"][:3], ["/usr/bin/heap", "-s", "--noContent"])
        self.assertEqual(captures[0]["argv"][-1], str(process.pid))
        self.assertTrue(any(argument.startswith("--addresses=") for argument in captures[0]["argv"]))
        for captured, address in zip(captures[1:], ("0x8", "0x7", "0x6", "0x5")):
            self.assertEqual(captured["argv"], ["/usr/bin/malloc_history", str(process.pid),
                                                "-allBySize", "-fullStacks", address])
            self.assertGreater(captured["timeout"], 0)
            self.assertLessEqual(captured["timeout"], 5)
            self.assertLessEqual(captured["max_bytes"], 64 * 1024)
        self.assertGreater(captures[0]["timeout"], 0)
        self.assertLessEqual(captures[0]["timeout"], 10)
        self.assertLessEqual(captures[0]["max_bytes"], 128 * 1024)
        self.assertLessEqual(sum(captured["timeout"] for captured in captures), 30)
        self.assertGreaterEqual(process.poll.call_count, len(captures))

    def test_heap_denial_never_qualifies_as_a_collected_stack(self):
        captures, capture = self.capture_plan([{"payload": b"permission denied\n", "returnCode": 1}])
        process = SimpleNamespace(pid=4321, poll=Mock(return_value=None))
        with tempfile.TemporaryDirectory() as tmp, patch.object(alloc, "bounded_capture", side_effect=capture):
            evidence = alloc.collect_allocations(process, Path(tmp), {})
            self.assertEqual(evidence["status"], "UNAVAILABLE")
            self.assertEqual(len(evidence["tools"]), 1)
            self.assertEqual(evidence["allocations"], [])
            self.assertEqual(captures[0]["destination"].read_bytes(), b"permission denied\n")
        self.assertEqual(len(captures), 1)

    def test_zero_exit_without_heap_addresses_is_unavailable(self):
        captures, capture = self.capture_plan([{"payload": b"Process 4321: 20 allocations, 4096 bytes\n"}])
        process = SimpleNamespace(pid=4321, poll=Mock(return_value=None))
        with tempfile.TemporaryDirectory() as tmp, patch.object(alloc, "bounded_capture", side_effect=capture):
            evidence = alloc.collect_allocations(process, Path(tmp), {})
        self.assertEqual(evidence["status"], "UNAVAILABLE")
        self.assertEqual(evidence["allocations"], [])
        self.assertEqual(len(captures), 1)

    def test_zero_exit_without_history_frames_remains_unavailable(self):
        for history in (b"No stack logging data\n", b"1 call for 32 bytes:\nNo stack logging data\n"):
            with self.subTest(history=history):
                captures, capture = self.capture_plan([
                    {"payload": b"0x1234: malloc (32 bytes)\n"}, {"payload": history},
                ])
                process = SimpleNamespace(pid=4321, poll=Mock(return_value=None))
                with tempfile.TemporaryDirectory() as tmp, patch.object(alloc, "bounded_capture", side_effect=capture):
                    evidence = alloc.collect_allocations(process, Path(tmp), {})
                self.assertEqual(evidence["status"], "UNAVAILABLE")
                self.assertEqual(len(captures), 2)

    def test_history_permission_denial_does_not_become_a_zero_allocation_result(self):
        captures, capture = self.capture_plan([
            {"payload": b"0x1234: malloc (32 bytes)\n"},
            {"payload": b"Cannot examine process 4321: permission denied\n", "returnCode": 1},
        ])
        process = SimpleNamespace(pid=4321, poll=Mock(return_value=None))
        with tempfile.TemporaryDirectory() as tmp, patch.object(alloc, "bounded_capture", side_effect=capture):
            evidence = alloc.collect_allocations(process, Path(tmp), {})
            self.assertEqual(captures[1]["destination"].read_bytes(), b"Cannot examine process 4321: permission denied\n")
        self.assertEqual(evidence["status"], "UNAVAILABLE")
        self.assertEqual(evidence["tools"][1]["returnCode"], 1)

    def test_a_real_stack_with_other_failed_addresses_is_partial(self):
        heap = b"0x1: malloc (32 bytes)\n0x2: malloc (64 bytes)\n0x3: malloc (96 bytes)\n0x4: malloc (128 bytes)\n"
        captures, capture = self.capture_plan([
            {"payload": heap}, {"payload": ("1 call for 32 bytes:\n" + self.FRAME).encode()},
            {"payload": b"permission denied\n", "returnCode": 1},
            {"payload": b"No stack logging data\n"},
            {"payload": b"No stack logging data\n"},
        ])
        process = SimpleNamespace(pid=4321, poll=Mock(return_value=None))
        with tempfile.TemporaryDirectory() as tmp, patch.object(alloc, "bounded_capture", side_effect=capture):
            evidence = alloc.collect_allocations(process, Path(tmp), {})
        self.assertEqual(evidence["status"], "PARTIAL")
        self.assertEqual(len(captures), 5)
        self.assertTrue(any(alloc.has_stack(group) for row in evidence["allocations"] for group in row["groups"]))

    def test_truncated_history_preserves_complete_frames_as_partial_evidence(self):
        history = ("1 call for 32 bytes:\n" + self.FRAME + "    1 incomplete 0x9999").encode()
        captures, capture = self.capture_plan([
            {"payload": b"0x1234: malloc (32 bytes)\n"},
            {"payload": history, "truncated": True, "returnCode": -15},
        ])
        process = SimpleNamespace(pid=4321, poll=Mock(return_value=None))
        with tempfile.TemporaryDirectory() as tmp, patch.object(alloc, "bounded_capture", side_effect=capture):
            evidence = alloc.collect_allocations(process, Path(tmp), {})
            self.assertEqual(captures[1]["destination"].read_bytes(), history)
        self.assertEqual(evidence["status"], "PARTIAL")
        groups = [group for row in evidence["allocations"] for group in row["groups"]]
        self.assertTrue(any(alloc.has_stack(group) for group in groups))
        self.assertFalse(any("incomplete" in line for group in groups for line in group["frameLines"]))

    def test_timed_out_heap_keeps_complete_addresses_for_partial_stack_capture(self):
        heap = b"0x1234: malloc (65536 bytes)\n0x5678: malloc (81920 bytes)"
        history = ("1 call for 65536 bytes:\n" + self.FRAME).encode()
        captures, capture = self.capture_plan([
            {"payload": heap, "timedOut": True, "returnCode": -9},
            {"payload": history},
        ])
        process = SimpleNamespace(pid=4321, poll=Mock(return_value=None))
        with tempfile.TemporaryDirectory() as tmp, patch.object(alloc, "bounded_capture", side_effect=capture):
            evidence = alloc.collect_allocations(process, Path(tmp), {})
            self.assertEqual(captures[0]["destination"].read_bytes(), heap)
            self.assertEqual(captures[1]["destination"].read_bytes(), history)
        self.assertEqual(evidence["status"], "PARTIAL")
        self.assertTrue(evidence["incompleteCoverage"])
        self.assertEqual(len(captures), 2)
        self.assertEqual(captures[1]["argv"][-1], "0x1234")
        self.assertEqual([row["address"] for row in evidence["allocations"]], ["0x1234"])
        self.assertEqual(evidence["allocations"][0]["status"], "COLLECTED")
        self.assertTrue(any(alloc.has_stack(group) for group in evidence["allocations"][0]["groups"]))
        self.assertTrue(evidence["tools"][0]["timedOut"])
        self.assertEqual(evidence["tools"][0]["returnCode"], -9)

    def test_an_exited_exact_child_is_not_inspected(self):
        process = SimpleNamespace(pid=4321, poll=Mock(return_value=0))
        with tempfile.TemporaryDirectory() as tmp, patch.object(alloc, "bounded_capture") as capture:
            evidence = alloc.collect_allocations(process, Path(tmp), {})
        self.assertEqual(evidence["status"], "UNAVAILABLE")
        self.assertEqual(evidence["tools"], [])
        capture.assert_not_called()

    def test_child_exit_after_heap_prevents_history_queries(self):
        captures, capture = self.capture_plan([{"payload": b"0x1234: malloc (32 bytes)\n"}])
        process = SimpleNamespace(pid=4321, poll=Mock(side_effect=lambda: 0 if captures else None))
        with tempfile.TemporaryDirectory() as tmp, patch.object(alloc, "bounded_capture", side_effect=capture):
            evidence = alloc.collect_allocations(process, Path(tmp), {})
        self.assertEqual(evidence["status"], "UNAVAILABLE")
        self.assertEqual(len(captures), 1)


class AllocationSafetyTests(unittest.TestCase):
    def test_cli_fixes_a_single_candidate_diagnostic_at_the_required_workload(self):
        args = alloc.parse_arguments(["--candidate-app", "/synthetic/candidate.app", "--output-dir", "/synthetic/evidence"])
        self.assertEqual(args.candidate_app, Path("/synthetic/candidate.app"))
        self.assertEqual((args.responses, args.trials, args.warmup, args.duration), ([20000], 1, 120, 120))
        self.assertFalse(args.retained_graph)
        self.assertFalse(hasattr(args, "baseline_app"))

    def test_import_does_not_start_processes_or_load_native_frameworks(self):
        with patch.dict(sys.modules):
            sys.modules.pop("whole_app_benchmark", None)
            with patch.object(subprocess, "Popen") as popen, \
                    patch.object(subprocess, "run") as run, \
                    patch.object(ctypes, "CDLL") as cdll:
                imported = load_allocations("whole_app_allocations_import_safety")
            self.assertTrue(callable(imported.main))
            popen.assert_not_called()
            run.assert_not_called()
            cdll.assert_not_called()

    def test_local_invocation_refuses_without_starting_a_process(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "new-output"
            with patch.object(alloc.bench.platform, "system", return_value="Darwin"), \
                    patch.dict(os.environ, {}, clear=True), \
                    patch.object(subprocess, "Popen") as popen, \
                    patch.object(subprocess, "run") as run, \
                    patch.object(ctypes, "CDLL") as cdll, patch("builtins.print"):
                status = alloc.main(["--candidate-app", "/missing/candidate.app", "--output-dir", str(output)])
            self.assertEqual(status, 2)
            self.assertFalse(output.exists())
            popen.assert_not_called()
            run.assert_not_called()
            cdll.assert_not_called()

    def test_existing_output_is_preserved_when_the_real_guard_refuses(self):
        with tempfile.TemporaryDirectory() as tmp:
            home, runner = Path(tmp) / "home", Path(tmp) / "runner"
            home.mkdir()
            runner.mkdir()
            output = runner / "evidence"
            output.mkdir()
            sentinel = output / "summary.json"
            sentinel.write_bytes(b"preserve prior evidence\n")
            env = {"GITHUB_ACTIONS": "true", "RUNNER_OS": "macOS", "RUNNER_TEMP": str(runner), "HOME": str(home)}
            with patch.object(alloc.bench.platform, "system", return_value="Darwin"), \
                    patch.object(alloc.bench.os, "getuid", return_value=501), \
                    patch.dict(os.environ, env, clear=True), \
                    patch.object(subprocess, "Popen") as popen, \
                    patch.object(subprocess, "run") as run, \
                    patch.object(ctypes, "CDLL") as cdll, patch("builtins.print"):
                status = alloc.main(["--candidate-app", "/missing/candidate.app", "--output-dir", str(output)])
            self.assertEqual(status, 2)
            self.assertEqual(sentinel.read_bytes(), b"preserve prior evidence\n")
            self.assertEqual(list(output.iterdir()), [sentinel])
            popen.assert_not_called()
            run.assert_not_called()
            cdll.assert_not_called()


if __name__ == "__main__":
    unittest.main()
