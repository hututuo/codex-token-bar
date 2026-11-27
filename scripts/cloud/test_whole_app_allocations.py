"""Stdlib-only allocation diagnostics checks; never build or launch an App."""
import ctypes
from contextlib import ExitStack
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

    def test_heap_selection_prioritizes_exact_data_and_array_types_beyond_the_largest_four(self):
        rows = [
            ("0x1", "malloc", 1048576),
            ("0x2", "__DataStorage._bytes (malloc) suffix", 786432),
            ("0x3", "Swift._ContiguousArrayStorage<Swift.String> suffix", 524288),
            ("0x4", "Swift._ContiguousArrayStorage<Swift.Float> suffix", 458752),
            ("0xd1", "__DataStorage._bytes (malloc)", 131072),
            ("0xd2", "__DataStorage._bytes (malloc)", 98304),
            ("0xd3", "__DataStorage._bytes (malloc)", 98305),
            ("0xd4", "__DataStorage._bytes (malloc)", 98304),
            ("0xe1", "Swift._ContiguousArrayStorage<Swift.String>", 393216),
            ("0xe2", "Swift._ContiguousArrayStorage<Swift.String>", 262144),
            ("0xf1", "Swift._ContiguousArrayStorage<Swift.Float>", 360448),
            ("0xf2", "Swift._ContiguousArrayStorage<Swift.Float>", 131072),
        ]
        text = "".join(f"{address}: {heap_type} ({size} bytes)\n" for address, heap_type, size in rows)
        text += "0xd0: __DataStorage._bytes (malloc) (2097152 bytes)"
        self.assertEqual([row["address"] for row in alloc.parse_heap_addresses(text)],
                         ["0x1", "0x2", "0x3", "0x4"])
        selected = alloc.select_heap_addresses(text)
        self.assertEqual([row["address"] for row in selected], ["0xd1", "0xd2", "0xe1", "0xf1"])
        self.assertEqual([row["heapAllocatedBytes"] for row in selected], [131072, 98304, 393216, 360448])
        self.assertEqual([row["selectionRole"] for row in selected],
                         ["data-largest", "data-exact-98304", "string-array-largest", "float-array-largest"])

    def test_heap_selection_deduplicates_roles_and_fills_from_remaining_largest_blocks(self):
        data_type = "__DataStorage._bytes (malloc)"
        string_type = "Swift._ContiguousArrayStorage<Swift.String>"
        float_type = "Swift._ContiguousArrayStorage<Swift.Float>"
        large = [("0x1", "malloc", 524288), ("0x2", "malloc", 393216),
                 ("0x3", "malloc", 262144), ("0x4", "malloc", 131072)]
        cases = [
            ("all preferred roles missing", large, ["0x1", "0x2", "0x3", "0x4"],
             ["fallback-largest"] * 4),
            ("only largest Data available", large + [("0xd1", data_type, 131072)],
             ["0xd1", "0x1", "0x2", "0x3"], ["data-largest"] + ["fallback-largest"] * 3),
            ("one exact Data address cannot fill two roles",
             large + [("0xd1", data_type, 98304), ("0xd1", data_type, 196608),
                      ("0xe1", string_type, 65536), ("0xf1", float_type, 65536)],
             ["0xd1", "0xe1", "0xf1", "0x1"],
             ["data-largest", "string-array-largest", "float-array-largest", "fallback-largest"]),
            ("second exact Data address fills its own role",
             large + [("0xd1", data_type, 98304), ("0xd2", data_type, 98304),
                      ("0xe1", string_type, 65536), ("0xf1", float_type, 65536)],
             ["0xd1", "0xd2", "0xe1", "0xf1"],
             ["data-largest", "data-exact-98304", "string-array-largest", "float-array-largest"]),
            ("fewer than four unique blocks", [("0xd1", data_type, 98304), ("0xf1", float_type, 65536)],
             ["0xd1", "0xf1"], ["data-largest", "float-array-largest"]),
        ]
        for label, rows, expected_addresses, expected_roles in cases:
            with self.subTest(case=label):
                text = "".join(f"{address}: {heap_type} ({size} bytes)\n" for address, heap_type, size in rows)
                selected = alloc.select_heap_addresses(text)
                self.assertEqual([row["address"] for row in selected], expected_addresses)
                self.assertEqual([row["selectionRole"] for row in selected], expected_roles)
                self.assertEqual(len({row["address"] for row in selected}), len(selected))
                if label == "one exact Data address cannot fill two roles":
                    self.assertEqual(selected[0]["heapAllocatedBytes"], 98304)

    def test_exact_64k_profile_spreads_across_the_entire_unique_pool(self):
        cases = [(0, []), (1, [0]), (2, [0, 1]), (3, [0, 1, 2]),
                 (4, [0, 1, 2, 3]), (5, [0, 1, 2, 4]), (10, [0, 3, 6, 9])]
        for count, ranks in cases:
            with self.subTest(pool_count=count):
                candidates = [(hex(0x1000 + index * 16), f"observed-label-{index}")
                              for index in range(count)]
                text = "0x1: larger noncandidate (1048576 bytes)\n"
                text += "".join(f"{address}: {label} (65536 bytes)\n"
                                for address, label in reversed(candidates))
                text += "0x2: smaller noncandidate (65535 bytes)\n0x3: larger noncandidate (65537 bytes)\n"
                selected = alloc.select_heap_addresses(text, profile=alloc.EXACT_64K_PROFILE)
                self.assertEqual([row["address"] for row in selected], [candidates[rank][0] for rank in ranks])
                self.assertEqual([row["heapType"] for row in selected], [candidates[rank][1] for rank in ranks])
                self.assertEqual([row["selectionRole"] for row in selected],
                                 [f"exact-64k-spread-{index + 1}" for index in range(len(ranks))])
                self.assertEqual([row["selectionPoolRank"] for row in selected], ranks)
                self.assertEqual([row["selectionPoolCount"] for row in selected], [count] * len(ranks))
                self.assertTrue(all(row["heapAllocatedBytes"] == 65536 for row in selected))
                self.assertEqual(len({row["address"] for row in selected}), len(selected))
                self.assertLessEqual(len(selected), 4)

    def test_exact_64k_profile_sorts_numeric_addresses_without_filtering_labels(self):
        rows = [("0x100", "malloc in MeCab::FreeList<mecab_node_t>::alloc()"),
                ("0x20", "__DataStorage._bytes (malloc)"),
                ("0x2", "Swift._DictionaryStorage<Swift.String, AgentSpeedCore.ResponseStorage>"),
                ("0x11", "malloc"), ("0x10", "misleading SharedSourceIO/rawRead label")]
        text = "".join(f"{address}: {label} (65536 bytes)\n" for address, label in rows)
        selected = alloc.select_heap_addresses(text, profile=alloc.EXACT_64K_PROFILE)
        self.assertEqual([row["address"] for row in selected], ["0x2", "0x10", "0x11", "0x100"])
        self.assertEqual([row["selectionPoolRank"] for row in selected], [0, 1, 2, 4])
        labels = dict(rows)
        self.assertEqual([row["heapType"] for row in selected],
                         [labels[address] for address in ("0x2", "0x10", "0x11", "0x100")])
        for row in selected:
            self.assertNotIn("owner", row)
            self.assertNotIn("allocationSite", row)

    def test_exact_64k_profile_uses_only_complete_positive_unique_address_records(self):
        text = ("0x10: first observed label (65536 bytes)\n"
                "0x010: duplicate label (65536 bytes)\n"
                "0x10: conflicting duplicate size (98304 bytes)\n"
                "0x0: zero address (65536 bytes)\n"
                "0x2: malloc in MeCab::FreeList<mecab_node_t>::alloc() (65536 bytes)\n"
                "0x20: third observed label (65536 bytes)\n"
                "0x30: first noncandidate size (65535 bytes)\n"
                "0x30: duplicate must not replace first record (65536 bytes)\n"
                "0x40: zero bytes (0 bytes)\n"
                "0x50: extra trailing text (65536 bytes) not a complete record\n"
                "prefix 0x60: not an address record (65536 bytes)\n"
                "0x70: incomplete final record (65536 bytes)")
        selected = alloc.select_heap_addresses(text, profile=alloc.EXACT_64K_PROFILE)
        self.assertEqual([row["address"] for row in selected], ["0x2", "0x10", "0x20"])
        self.assertEqual([row["selectionPoolRank"] for row in selected], [0, 1, 2])
        self.assertEqual([row["selectionPoolCount"] for row in selected], [3, 3, 3])
        self.assertEqual(selected[1]["heapType"], "first observed label")
        self.assertEqual(alloc.select_heap_addresses(
            "0x1: malloc (98304 bytes)\n0x2: malloc (131072 bytes)\n",
            profile=alloc.EXACT_64K_PROFILE), [])

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

    def test_large_heap_summary_keeps_complete_late_address_records(self):
        summary_line = b"     8192       524288      64.0  __NSCFString\n"
        repetitions = (2 * 1024 * 1024) // len(summary_line) + 1
        addresses = (
            b"0x1: malloc (1048576 bytes)\n"
            b"0x2: malloc (524288 bytes)\n"
            b"0xd1: __DataStorage._bytes (malloc) (131072 bytes)\n"
            b"0xd2: __DataStorage._bytes (malloc) (98304 bytes)\n"
            b"0xe1: Swift._ContiguousArrayStorage<Swift.String> (393216 bytes)\n"
            b"0xf1: Swift._ContiguousArrayStorage<Swift.Float> (360448 bytes)\n"
        )
        payload = summary_line * repetitions + addresses
        self.assertGreater(len(payload), 2 * 1024 * 1024)
        self.assertLess(len(payload), alloc.HEAP_BYTES)
        code = ("import sys; sys.stdout.buffer.write("
                f"{summary_line!r} * {repetitions} + {addresses!r}); sys.stdout.buffer.flush()")
        with tempfile.TemporaryDirectory() as tmp:
            destination = Path(tmp) / "large-heap.txt"
            entry = alloc.bounded_capture([sys.executable, "-c", code], {}, destination,
                                          timeout=3, max_bytes=alloc.HEAP_BYTES)
            self.assert_capture_record(entry, destination, payload, status="COLLECTED")
            selected = alloc.select_heap_addresses(destination.read_text())
        self.assertEqual(entry["returnCode"], 0)
        self.assertFalse(entry["timedOut"])
        self.assertFalse(entry["truncated"])
        self.assertEqual([row["address"] for row in selected], ["0xd1", "0xd2", "0xe1", "0xf1"])
        self.assertEqual([row["selectionRole"] for row in selected],
                         ["data-largest", "data-exact-98304", "string-array-largest", "float-array-largest"])

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

    def assert_selection_metadata(self, evidence, missing_roles):
        self.assertEqual(alloc.SELECTION_ROLES,
                         ("data-largest", "data-exact-98304", "string-array-largest", "float-array-largest"))
        self.assertEqual(evidence["selectionProfile"], "data-string-float-v1")
        self.assertEqual(evidence["selectionStrategy"], alloc.SELECTION_STRATEGY)
        for fragment in ("largest Data", "98304", "String array", "Float array", "remaining largest"):
            self.assertIn(fragment, evidence["selectionStrategy"])
        self.assertIsInstance(evidence["missingSelectionRoles"], list)
        self.assertEqual(evidence["missingSelectionRoles"], missing_roles)
        self.assertFalse(evidence["classSummaryRequested"])
        self.assertNotIn("bucketObserved", evidence)

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
            evidence = alloc.collect_allocations(process, Path(tmp), env, class_summary=False)
            self.assertEqual(evidence["status"], "COLLECTED")
            self.assertTrue(evidence["outsideMeasurement"])
            self.assertEqual(len(evidence["tools"]), 5)
            self.assertEqual([entry["address"] for entry in evidence["allocations"]],
                             ["0x8", "0x7", "0x6", "0x5"])
            self.assertEqual([entry["heapType"] for entry in evidence["allocations"]],
                             ["type-8", "type-7", "type-6", "type-5"])
            self.assertEqual([entry["heapAllocatedBytes"] for entry in evidence["allocations"]], [256, 224, 192, 160])
            self.assertEqual([entry["selectionRole"] for entry in evidence["allocations"]], ["fallback-largest"] * 4)
            self.assert_selection_metadata(evidence, list(alloc.SELECTION_ROLES))
            self.assertEqual(evidence["limits"], {
                "seconds": 120, "heapBytes": 8 * 1024 * 1024, "heapSeconds": 60,
                "historyBytesPerAddress": 64 * 1024, "historySecondsPerAddress": 10,
            })
            self.assertNotIn("classSummary", evidence)
            saved = json.loads((Path(tmp) / "allocation-diagnostics.json").read_text())
            self.assertEqual(saved["limits"], evidence["limits"])
            self.assert_selection_metadata(saved, list(alloc.SELECTION_ROLES))
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
            self.assertLessEqual(captured["timeout"], alloc.HISTORY_SECONDS)
            self.assertEqual(captured["max_bytes"], alloc.HISTORY_BYTES)
        self.assertGreater(captures[0]["timeout"], 0)
        self.assertLessEqual(captures[0]["timeout"], alloc.HEAP_SECONDS)
        self.assertEqual(captures[0]["max_bytes"], alloc.HEAP_BYTES)
        self.assertLessEqual(alloc.HEAP_SECONDS + alloc.MAX_ADDRESSES * alloc.HISTORY_SECONDS,
                             alloc.COLLECTION_SECONDS)
        self.assertLessEqual(sum(captured["timeout"] for captured in captures), alloc.COLLECTION_SECONDS)
        self.assertGreaterEqual(process.poll.call_count, len(captures))

    def test_selection_metadata_reports_only_unfilled_profile_roles(self):
        heap = (
            b"0x1: malloc (1048576 bytes)\n"
            b"0xd1: __DataStorage._bytes (malloc) (131072 bytes)\n"
            b"0xe1: Swift._ContiguousArrayStorage<Swift.String> (393216 bytes)\n"
            b"0xf1: Swift._ContiguousArrayStorage<Swift.Float> (360448 bytes)\n"
        )
        history = ("1 call for 32 bytes:\n" + self.FRAME).encode()
        cases = [
            ("complete profile", heap + b"0xd2: __DataStorage._bytes (malloc) (98304 bytes)\n",
             ["0xd1", "0xd2", "0xe1", "0xf1"], list(alloc.SELECTION_ROLES), []),
            ("missing exact Data", heap, ["0xd1", "0xe1", "0xf1", "0x1"],
             ["data-largest", "string-array-largest", "float-array-largest", "fallback-largest"],
             ["data-exact-98304"]),
        ]
        for label, payload, expected_addresses, expected_roles, missing_roles in cases:
            with self.subTest(case=label):
                captures, capture = self.capture_plan([{"payload": payload}] + [{"payload": history}] * 4)
                process = SimpleNamespace(pid=4321, poll=Mock(return_value=None))
                with tempfile.TemporaryDirectory() as tmp, patch.object(alloc, "bounded_capture", side_effect=capture):
                    evidence = alloc.collect_allocations(process, Path(tmp), {})
                    saved = json.loads((Path(tmp) / "allocation-diagnostics.json").read_text())
                self.assertEqual(evidence["status"], "COLLECTED")
                self.assertEqual([entry["address"] for entry in evidence["allocations"]], expected_addresses)
                self.assertEqual([entry["selectionRole"] for entry in evidence["allocations"]], expected_roles)
                self.assertEqual([capture["argv"][-1] for capture in captures[1:]], expected_addresses)
                self.assert_selection_metadata(evidence, missing_roles)
                self.assert_selection_metadata(saved, missing_roles)
                self.assertEqual([entry["selectionRole"] for entry in saved["allocations"]], expected_roles)

    def test_exact_64k_collector_persists_profile_pool_ranks_and_missing_roles_under_original_budgets(self):
        cases = [(0, []), (1, [0]), (2, [0, 1]), (3, [0, 1, 2]),
                 (4, [0, 1, 2, 3]), (5, [0, 1, 2, 4]), (10, [0, 3, 6, 9])]
        all_roles = [f"exact-64k-spread-{index}" for index in range(1, 5)]
        history = ("1 call for 65536 bytes:\n" + self.FRAME).encode()
        limits = {"seconds": 120, "heapBytes": 8 * 1024 * 1024, "heapSeconds": 60,
                  "historyBytesPerAddress": 64 * 1024, "historySecondsPerAddress": 10}
        for count, ranks in cases:
            with self.subTest(pool_count=count):
                heap = "0x1: noncandidate (1048576 bytes)\n"
                heap += "".join(f"{hex(0x1000 + index * 16)}: observed-type-{index} (65536 bytes)\n"
                                for index in reversed(range(count)))
                captures, capture = self.capture_plan([{"payload": heap.encode()}]
                                                     + [{"payload": history}] * len(ranks))
                process = SimpleNamespace(pid=4321, poll=Mock(return_value=None))
                env = {"PATH": "/usr/bin:/bin", "ALLOCATION_TEST_VALUE": "synthetic"}
                with tempfile.TemporaryDirectory() as tmp, patch.object(alloc, "bounded_capture", side_effect=capture):
                    evidence = alloc.collect_allocations(process, Path(tmp), env, profile=alloc.EXACT_64K_PROFILE)
                    saved = json.loads((Path(tmp) / "allocation-diagnostics.json").read_text())
                self.assertEqual(evidence["status"], "COLLECTED" if ranks else "UNAVAILABLE")
                self.assertEqual(len(captures), 1 + len(ranks))
                self.assertLessEqual(len(captures), 5)
                for record in (evidence, saved):
                    self.assertEqual(record["selectionProfile"], "exact-64k-spread-v1")
                    self.assertEqual(record["missingSelectionRoles"], all_roles[len(ranks):])
                    self.assertEqual(record["limits"], limits)
                    self.assertEqual(record["maxAddresses"], 4)
                    self.assertTrue(record["outsideMeasurement"])
                    self.assertEqual([row["selectionPoolRank"] for row in record["allocations"]], ranks)
                    self.assertEqual([row["selectionPoolCount"] for row in record["allocations"]],
                                     [count] * len(ranks))
                    self.assertEqual([row["selectionRole"] for row in record["allocations"]], all_roles[:len(ranks)])
                    self.assertEqual([row["heapType"] for row in record["allocations"]],
                                     [f"observed-type-{rank}" for rank in ranks])
                self.assertEqual([row["argv"][-1] for row in captures[1:]],
                                 [hex(0x1000 + rank * 16) for rank in ranks])
                self.assertEqual(captures[0]["argv"],
                                 ["/usr/bin/heap", "-s", "--noContent", "--addresses=" + alloc.HEAP_PATTERN, "4321"])
                self.assertEqual(captures[0]["max_bytes"], limits["heapBytes"])
                for captured in captures[1:]:
                    self.assertEqual(captured["argv"][:4],
                                     ["/usr/bin/malloc_history", "4321", "-allBySize", "-fullStacks"])
                    self.assertEqual(captured["max_bytes"], limits["historyBytesPerAddress"])
                    self.assertGreater(captured["timeout"], 0)
                    self.assertLessEqual(captured["timeout"], limits["historySecondsPerAddress"])
                self.assertTrue(all(captured["env"] is env for captured in captures))
                self.assertLessEqual(sum(captured["timeout"] for captured in captures), limits["seconds"])

    def test_exact_64k_collector_keeps_truncated_heap_pool_and_history_evidence_partial(self):
        heap = (b"0x10: observed first label (65536 bytes)\n"
                b"0x20: observed second label (65536 bytes)\n"
                b"0x30: incomplete final record (65536 bytes)")
        history = ("1 call for 65536 bytes:\n" + self.FRAME).encode()
        captures, capture = self.capture_plan([
            {"payload": heap, "truncated": True, "returnCode": -9},
            {"payload": history, "truncated": True, "returnCode": -9},
            {"payload": history},
        ])
        process = SimpleNamespace(pid=4321, poll=Mock(return_value=None))
        with tempfile.TemporaryDirectory() as tmp, patch.object(alloc, "bounded_capture", side_effect=capture):
            evidence = alloc.collect_allocations(process, Path(tmp), {}, profile=alloc.EXACT_64K_PROFILE)
            saved = json.loads((Path(tmp) / "allocation-diagnostics.json").read_text())
        for record in (evidence, saved):
            self.assertEqual(record["status"], "PARTIAL")
            self.assertTrue(record["incompleteCoverage"])
            self.assertEqual(record["recordedStackAddresses"], 2)
            self.assertEqual([row["selectionPoolCount"] for row in record["allocations"]], [2, 2])
            self.assertEqual([row["selectionPoolRank"] for row in record["allocations"]], [0, 1])
            self.assertEqual([row["status"] for row in record["allocations"]], ["COLLECTED", "COLLECTED"])
            self.assertEqual(record["missingSelectionRoles"], ["exact-64k-spread-3", "exact-64k-spread-4"])
        self.assertEqual([entry["argv"][-1] for entry in captures[1:]], ["0x10", "0x20"])

    def test_exact_64k_profile_and_missing_roles_are_persisted_when_the_child_already_exited(self):
        process = SimpleNamespace(pid=4321, poll=Mock(return_value=0))
        with tempfile.TemporaryDirectory() as tmp, patch.object(alloc, "bounded_capture") as capture:
            evidence = alloc.collect_allocations(process, Path(tmp), {}, profile=alloc.EXACT_64K_PROFILE)
            saved = json.loads((Path(tmp) / "allocation-diagnostics.json").read_text())
        for record in (evidence, saved):
            self.assertEqual(record["selectionProfile"], "exact-64k-spread-v1")
            self.assertEqual(record["status"], "UNAVAILABLE")
            self.assertEqual(record["tools"], [])
            self.assertEqual(record["allocations"], [])
            self.assertEqual(record["missingSelectionRoles"],
                             [f"exact-64k-spread-{index}" for index in range(1, 5)])
        capture.assert_not_called()

    def test_requested_class_summary_uses_clean_environment_original_deadline_and_bounded_output(self):
        heap = "".join(f"0x{index:x}: observed-label-{index} (65536 bytes)\n"
                       for index in range(1, 5)).encode()
        history = ("1 call for 65536 bytes:\n" + self.FRAME).encode()
        summary_payload = b"All zones: synthetic class summary\n"
        for elapsed_before_summary, expected_timeout in ((0.0, 60.0), (100.0, 20.0)):
            with self.subTest(elapsed_before_summary=elapsed_before_summary):
                captures, capture = self.capture_plan([{"payload": heap}] + [{"payload": history}] * 4
                                                     + [{"payload": summary_payload}])
                clock = SimpleNamespace(now=0.0)

                def advance_capture(*args, **kwargs):
                    record = capture(*args, **kwargs)
                    if len(captures) == 5:
                        clock.now = elapsed_before_summary
                    return record

                process = SimpleNamespace(pid=4321, poll=Mock(return_value=None))
                env = {"PATH": "/usr/bin:/bin", "ALLOCATION_TEST_VALUE": "synthetic"}
                with tempfile.TemporaryDirectory() as tmp, \
                        patch.object(alloc.time, "monotonic", side_effect=lambda: clock.now), \
                        patch.object(alloc, "bounded_capture", side_effect=advance_capture):
                    evidence = alloc.collect_allocations(process, Path(tmp), env,
                                                         profile=alloc.EXACT_64K_PROFILE, class_summary=True)
                    saved = json.loads((Path(tmp) / "allocation-diagnostics.json").read_text())
                    self.assertEqual((Path(tmp) / "allocation-heap-summary.txt").read_bytes(), summary_payload)
                    self.assertEqual(captures[-1]["destination"], Path(tmp) / "allocation-heap-summary.txt")
                self.assertEqual(len(captures), 6)
                self.assertEqual([entry["argv"][0] for entry in captures],
                                 ["/usr/bin/heap"] + ["/usr/bin/malloc_history"] * 4 + ["/usr/bin/heap"])
                self.assertEqual(captures[-1]["argv"], ["/usr/bin/heap", "-s", "--noContent", "4321"])
                self.assertEqual(captures[-1]["timeout"], expected_timeout)
                self.assertEqual(captures[-1]["max_bytes"], 8 * 1024 * 1024)
                self.assertTrue(all(captured["env"] is env for captured in captures))
                for record in (evidence, saved):
                    self.assertTrue(record["classSummaryRequested"])
                    self.assertEqual(record["status"], "COLLECTED")
                    self.assertEqual(record["recordedStackAddresses"], 4)
                    self.assertEqual(len(record["allocations"]), 4)
                    self.assertEqual(record["limits"], {
                        "seconds": 120, "heapBytes": 8 * 1024 * 1024, "heapSeconds": 60,
                        "historyBytesPerAddress": 64 * 1024, "historySecondsPerAddress": 10,
                        "classSummarySeconds": 60, "classSummaryBytes": 8 * 1024 * 1024,
                    })
                    self.assertEqual([tool["tool"] for tool in record["tools"]],
                                     ["heap"] + ["malloc_history"] * 4 + ["heap-summary"])
                    self.assertEqual(record["classSummary"], record["tools"][-1])
                    self.assertEqual(record["classSummary"]["bytes"], len(summary_payload))
                    self.assertEqual(record["classSummary"]["sha256"], hashlib.sha256(summary_payload).hexdigest())
                    self.assertEqual(record["classSummary"]["file"], "allocation-heap-summary.txt")
                self.assertEqual(env, {"PATH": "/usr/bin:/bin", "ALLOCATION_TEST_VALUE": "synthetic"})

    def test_class_summary_tool_outcomes_preserve_stacks_and_never_imply_success_without_stacks(self):
        outcomes = [
            ("timeout", {"returnCode": -9, "timedOut": True}, "UNAVAILABLE", "PARTIAL"),
            ("byte cap", {"returnCode": -9, "truncated": True}, "UNAVAILABLE", "PARTIAL"),
            ("nonzero exit", {"returnCode": 7}, "UNAVAILABLE", "PARTIAL"),
            ("killed without a cap flag", {"returnCode": -9}, "UNAVAILABLE", "PARTIAL"),
            ("successful summary", {"returnCode": 0}, "COLLECTED", "COLLECTED"),
        ]
        heap = b"0x10: observed label (65536 bytes)\n"
        for has_stack in (True, False):
            history = ("1 call for 65536 bytes:\n" + self.FRAME).encode() if has_stack else b"No stack logging data\n"
            for label, outcome, summary_status, status_with_stacks in outcomes:
                with self.subTest(summary_outcome=label, has_stack=has_stack):
                    captures, capture = self.capture_plan([
                        {"payload": heap}, {"payload": history},
                        {"payload": b"retained summary prefix\n", **outcome},
                    ])
                    process = SimpleNamespace(pid=4321, poll=Mock(return_value=None))
                    with tempfile.TemporaryDirectory() as tmp, patch.object(alloc, "bounded_capture", side_effect=capture):
                        evidence = alloc.collect_allocations(process, Path(tmp), {},
                                                             profile=alloc.EXACT_64K_PROFILE, class_summary=True)
                        saved = json.loads((Path(tmp) / "allocation-diagnostics.json").read_text())
                    self.assertEqual(len(captures), 3)
                    for record in (evidence, saved):
                        self.assertEqual(record["status"], status_with_stacks if has_stack else "UNAVAILABLE")
                        self.assertEqual(record["recordedStackAddresses"], int(has_stack))
                        self.assertEqual(len(record["allocations"]), 1)
                        self.assertEqual(record["allocations"][0]["status"], "COLLECTED" if has_stack else "UNAVAILABLE")
                        self.assertEqual(record["classSummary"]["status"], summary_status)
                        self.assertEqual(record["classSummary"]["returnCode"], outcome["returnCode"])
                        self.assertEqual(record["classSummary"], record["tools"][-1])
                        if has_stack:
                            self.assertTrue(any(self.FRAME.strip() in line for group in record["allocations"][0]["groups"]
                                                for line in group["frameLines"]))

    def test_class_summary_skips_queries_after_child_exit_or_exhausted_original_deadline(self):
        cases = [("child already exited", 0, False), ("child exits after history", 2, True),
                 ("deadline after heap", 1, False), ("deadline after history", 2, True)]
        heap = b"0x10: observed label (65536 bytes)\n"
        history = ("1 call for 65536 bytes:\n" + self.FRAME).encode()
        for label, expected_queries, has_stack in cases:
            with self.subTest(case=label):
                captures, capture = self.capture_plan([{"payload": heap}, {"payload": history}])
                clock = SimpleNamespace(now=0.0)

                def advance_capture(*args, **kwargs):
                    record = capture(*args, **kwargs)
                    if label.startswith("deadline") and len(captures) == expected_queries:
                        clock.now = 120.0
                    return record

                def poll():
                    if label == "child already exited" or (label == "child exits after history" and len(captures) >= 2):
                        return 0
                    return None

                process = SimpleNamespace(pid=4321, poll=Mock(side_effect=poll))
                with tempfile.TemporaryDirectory() as tmp, \
                        patch.object(alloc.time, "monotonic", side_effect=lambda: clock.now), \
                        patch.object(alloc, "bounded_capture", side_effect=advance_capture):
                    evidence = alloc.collect_allocations(process, Path(tmp), {},
                                                         profile=alloc.EXACT_64K_PROFILE, class_summary=True)
                    saved = json.loads((Path(tmp) / "allocation-diagnostics.json").read_text())
                self.assertEqual(len(captures), expected_queries)
                for record in (evidence, saved):
                    self.assertTrue(record["classSummaryRequested"])
                    self.assertEqual(record["status"], "PARTIAL" if has_stack else "UNAVAILABLE")
                    self.assertEqual(record["classSummary"]["status"], "SKIPPED")
                    self.assertTrue(record["classSummary"]["reason"])
                    self.assertNotIn("heap-summary", [tool["tool"] for tool in record["tools"]])
                self.assertTrue(all("--addresses=" + alloc.HEAP_PATTERN in captured["argv"]
                                    or captured["argv"][0] == "/usr/bin/malloc_history" for captured in captures))

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
        self.assert_selection_metadata(evidence, list(alloc.SELECTION_ROLES))
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

    def test_truncated_heap_with_zero_exit_queries_only_complete_addresses_and_stays_partial(self):
        heap = b"0x1234: malloc (65536 bytes)\n0x5678: malloc (81920 bytes)"
        history = ("1 call for 65536 bytes:\n" + self.FRAME).encode()
        captures, capture = self.capture_plan([
            {"payload": heap, "truncated": True, "returnCode": 0},
            {"payload": history},
        ])
        process = SimpleNamespace(pid=4321, poll=Mock(return_value=None))
        with tempfile.TemporaryDirectory() as tmp, patch.object(alloc, "bounded_capture", side_effect=capture):
            evidence = alloc.collect_allocations(process, Path(tmp), {})
            self.assertEqual(captures[0]["destination"].read_bytes(), heap)
            self.assertEqual(captures[1]["destination"].read_bytes(), history)
        self.assertEqual(evidence["status"], "PARTIAL")
        self.assertTrue(evidence["incompleteCoverage"])
        self.assertEqual(evidence["recordedStackAddresses"], 1)
        self.assertEqual(len(captures), 2)
        self.assertEqual(captures[1]["argv"][-1], "0x1234")
        self.assertEqual([row["address"] for row in evidence["allocations"]], ["0x1234"])
        self.assertEqual(evidence["allocations"][0]["status"], "COLLECTED")
        self.assertTrue(any(alloc.has_stack(group) for group in evidence["allocations"][0]["groups"]))
        self.assertEqual(evidence["tools"][0]["returnCode"], 0)
        self.assertTrue(evidence["tools"][0]["truncated"])
        self.assertEqual(evidence["tools"][0]["status"], "UNAVAILABLE")

    def test_zero_byte_timed_out_heap_is_unavailable_without_history_queries(self):
        captures, capture = self.capture_plan([{"payload": b"", "timedOut": True, "returnCode": -9}])
        process = SimpleNamespace(pid=4321, poll=Mock(return_value=None))
        with tempfile.TemporaryDirectory() as tmp, patch.object(alloc, "bounded_capture", side_effect=capture):
            evidence = alloc.collect_allocations(process, Path(tmp), {})
            self.assertEqual(captures[0]["destination"].read_bytes(), b"")
        self.assertEqual(evidence["status"], "UNAVAILABLE")
        self.assertTrue(evidence["incompleteCoverage"])
        self.assertEqual(evidence["recordedStackAddresses"], 0)
        self.assertEqual(evidence["allocations"], [])
        self.assert_selection_metadata(evidence, list(alloc.SELECTION_ROLES))
        self.assertEqual(len(captures), 1)
        self.assertEqual(len(evidence["tools"]), 1)
        heap = evidence["tools"][0]
        self.assertEqual(heap["bytes"], 0)
        self.assertEqual(heap["sha256"], hashlib.sha256(b"").hexdigest())
        self.assertEqual(heap["returnCode"], -9)
        self.assertTrue(heap["timedOut"])
        self.assertFalse(heap["truncated"])
        self.assertEqual(heap["status"], "UNAVAILABLE")

    def test_collection_deadline_limits_history_timeout_and_skips_remaining_addresses(self):
        heap = b"0x1: malloc (32 bytes)\n0x2: malloc (64 bytes)\n0x3: malloc (96 bytes)\n"
        history = ("1 call for 96 bytes:\n" + self.FRAME).encode()
        captures, capture = self.capture_plan([{"payload": heap}, {"payload": history}])
        clock = SimpleNamespace(now=0.0)

        def advance_capture(*args, **kwargs):
            record = capture(*args, **kwargs)
            clock.now = 60.0 if len(captures) == 1 else 65.0
            return record

        process = SimpleNamespace(pid=4321, poll=Mock(return_value=None))
        with tempfile.TemporaryDirectory() as tmp, \
                patch.object(alloc, "COLLECTION_SECONDS", 65), \
                patch.object(alloc.time, "monotonic", side_effect=lambda: clock.now), \
                patch.object(alloc, "bounded_capture", side_effect=advance_capture):
            evidence = alloc.collect_allocations(process, Path(tmp), {})
        self.assertEqual([captured["timeout"] for captured in captures], [alloc.HEAP_SECONDS, 5.0])
        self.assertEqual(sum(captured["timeout"] for captured in captures), 65.0)
        self.assertEqual(evidence["status"], "PARTIAL")
        self.assertEqual(evidence["limits"]["seconds"], 65)
        self.assertEqual([row["status"] for row in evidence["allocations"]],
                         ["COLLECTED", "SKIPPED", "SKIPPED"])
        self.assertEqual(captures[1]["argv"][-1], "0x3")

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
        self.assertEqual(args.selection_profile, "data-string-float-v1")
        self.assertFalse(args.class_summary)
        self.assertEqual((args.responses, args.trials, args.warmup, args.duration), ([20000], 1, 120, 120))
        self.assertFalse(args.retained_graph)
        self.assertFalse(hasattr(args, "baseline_app"))

    def test_cli_accepts_explicit_exact_64k_profile_without_changing_the_workload(self):
        args = alloc.parse_arguments(["--candidate-app", "/synthetic/candidate.app", "--output-dir", "/synthetic/evidence",
                                      "--selection-profile", "exact-64k-spread-v1"])
        self.assertEqual(args.selection_profile, alloc.EXACT_64K_PROFILE)
        self.assertFalse(args.class_summary)
        self.assertEqual((args.responses, args.trials, args.warmup, args.duration), ([20000], 1, 120, 120))
        self.assertFalse(args.retained_graph)

    def test_cli_accepts_optional_class_summary_with_the_original_workload_and_default_profile(self):
        args = alloc.parse_arguments(["--candidate-app", "/synthetic/candidate.app", "--output-dir", "/synthetic/evidence",
                                      "--class-summary"])
        self.assertTrue(args.class_summary)
        self.assertEqual(args.selection_profile, "data-string-float-v1")
        self.assertEqual((args.responses, args.trials, args.warmup, args.duration), ([20000], 1, 120, 120))
        self.assertFalse(args.retained_graph)

    def test_cli_rejects_unknown_profiles_before_starting_any_process_or_native_framework(self):
        with patch.object(subprocess, "Popen") as popen, patch.object(subprocess, "run") as run, \
                patch.object(ctypes, "CDLL") as cdll, patch.object(sys, "stderr"):
            with self.assertRaises(SystemExit) as raised:
                alloc.main(["--candidate-app", "/missing/candidate.app", "--output-dir", "/synthetic/evidence",
                            "--selection-profile", "not-a-profile"])
        self.assertEqual(raised.exception.code, 2)
        popen.assert_not_called()
        run.assert_not_called()
        cdll.assert_not_called()

    def test_main_binds_requested_profile_into_the_callback_and_saved_summary(self):
        cases = [(profile, class_summary) for profile in ("data-string-float-v1", "exact-64k-spread-v1")
                 for class_summary in (False, True)]
        for profile, class_summary in cases:
            with self.subTest(profile=profile, class_summary=class_summary), tempfile.TemporaryDirectory() as tmp:
                home, runner = Path(tmp) / "home", Path(tmp) / "runner"
                home.mkdir()
                runner.mkdir()
                output = runner / "evidence"
                process = SimpleNamespace(pid=4321)
                environment = {"PATH": "/usr/bin:/bin", "ALLOCATION_TEST_VALUE": "synthetic"}
                diagnostic = {"status": "COLLECTED", "selectionProfile": profile, "classSummaryRequested": class_summary}
                display = Mock(record={"synthetic": True})
                noon = alloc.dt.datetime.combine(alloc.dt.date.today(), alloc.dt.time(12)).timestamp()
                callback_arguments = (process, output / "synthetic-trial", environment)

                def trial(*args, **kwargs):
                    self.assertEqual(kwargs["app_env"], dict(environment, MallocStackLogging="1"))
                    return {"postMeasurementMemoryDiagnostics": kwargs["post_sample"](*callback_arguments)}

                with ExitStack() as stack:
                    for replacement in (
                            patch.object(alloc.bench, "guard_host", return_value=(home, runner)),
                            patch.object(alloc.bench, "clean_environment", return_value=environment),
                            patch.object(alloc.bench, "command", return_value=SimpleNamespace(returncode=0)),
                            patch.object(alloc.bench, "bundle_manifest", return_value={"bundleID": "synthetic"}),
                            patch.object(alloc.bench, "export_defaults", return_value=None),
                            patch.object(alloc.bench, "product_processes", return_value=[]),
                            patch.object(alloc.bench, "VisibleWindowProbe"),
                            patch.object(alloc.bench, "BenchmarkDisplay", return_value=display),
                            patch.object(alloc.bench, "generate_fixture", return_value={"synthetic": True}),
                            patch.object(alloc.bench, "run_trial", side_effect=trial),
                            patch.object(alloc.time, "time", return_value=noon),
                            patch.object(alloc.platform, "platform", return_value="synthetic-macOS"),
                            patch.object(alloc.platform, "machine", return_value="arm64"),
                            patch.dict(os.environ, {}, clear=True), patch("builtins.print")):
                        stack.enter_context(replacement)
                    collector = stack.enter_context(patch.object(alloc, "collect_allocations", return_value=diagnostic))
                    popen = stack.enter_context(patch.object(subprocess, "Popen"))
                    run = stack.enter_context(patch.object(subprocess, "run"))
                    cdll = stack.enter_context(patch.object(ctypes, "CDLL"))
                    arguments = ["--candidate-app", "/synthetic/candidate.app", "--output-dir", str(output),
                                 "--selection-profile", profile]
                    status = alloc.main(arguments + (["--class-summary"] if class_summary else []))
                self.assertEqual(status, 0)
                collector.assert_called_once()
                self.assertEqual(collector.call_args.args[:3], callback_arguments)
                forwarded_profile = (collector.call_args.args[3] if len(collector.call_args.args) > 3
                                     else collector.call_args.kwargs.get("profile"))
                self.assertEqual(forwarded_profile, profile)
                forwarded_class_summary = (collector.call_args.args[4] if len(collector.call_args.args) > 4
                                           else collector.call_args.kwargs.get("class_summary"))
                self.assertIs(forwarded_class_summary, class_summary)
                summary = json.loads((output / "summary.json").read_text())
                self.assertEqual(summary["selectionProfile"], profile)
                self.assertIs(summary["classSummaryRequested"], class_summary)
                self.assertEqual(summary["results"][0]["postMeasurementMemoryDiagnostics"]["selectionProfile"], profile)
                self.assertIs(summary["results"][0]["postMeasurementMemoryDiagnostics"]["classSummaryRequested"], class_summary)
                self.assertFalse(summary["performanceComparable"])
                self.assertFalse(summary["metricsEligibleForHalvingAcceptance"])
                self.assertEqual(summary["performanceVerdict"], "NOT_EVALUATED")
                display.restore.assert_called_once()
                popen.assert_not_called()
                run.assert_not_called()
                cdll.assert_not_called()

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
