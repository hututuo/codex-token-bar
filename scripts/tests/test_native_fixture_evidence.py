"""Real filesystem/subprocess tests of the harness, not native Rust evidence."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from native_fixture_evidence import (FixtureAttempt, OVERRIDES, execute_native,
    fixture_temporary_base, native_path, _cross_api_identity, _identity)
from test_business_store_fixture_harness import complete_native_report, fixture, STAGE_PROOFS

SPEC = importlib.util.spec_from_file_location("native_cloud_fixture", Path(__file__).resolve().parents[1] / "cloud/run-business-store-fixture.py")
cloud = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cloud)


class NativeFixtureEvidenceTests(unittest.TestCase):
    def temporary_directory(self):
        # Hosted runner temp paths are not necessarily outside the real home.
        return tempfile.TemporaryDirectory(dir=fixture_temporary_base())

    def create(self, temporary, label="test"):
        root = Path(temporary)
        attempt = FixtureAttempt(root / "latest.json", label=label)
        env = attempt.create_root(root, prefix="tokenbar-fixture-test-", slugs=("s", "c", "ss", "sc", "uc"))
        return attempt, env

    def test_real_child_receives_five_existing_unique_owned_override_directories(self):
        with self.temporary_directory() as temporary:
            attempt, env = self.create(temporary)
            code = """import json,os,pathlib,sys
root=pathlib.Path(sys.argv[1]).resolve(strict=True)
names=json.loads(sys.argv[2]);paths=[pathlib.Path(os.environ[name]).resolve(strict=True) for name in names]
assert len(set(paths))==5
assert all(path.is_dir() and path.parent==root and path!=root for path in paths)
assert not root.is_relative_to(pathlib.Path.home().resolve())
(paths[0]/'synthetic.sqlite').write_bytes(b'owned synthetic state')
print(json.dumps({'directories':len(paths),'scope':'python-harness-contract-only'}))
"""
            result = execute_native([sys.executable, "-c", code, native_path(attempt.root), json.dumps(OVERRIDES)],
                cwd=Path(temporary), env=env, timeout=10, log_directory=attempt.directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["directories"], 5)
            attempt.logs(result.stdout, result.stderr)
            root = attempt.root
            attempt.succeed({"status": "PASS", "scope": "python-harness-contract-only"})
            self.assertFalse(root.exists())
            self.assertFalse(json.loads(attempt.report_path.read_text())["fixtureRootRetained"])

    def test_failed_and_repeated_attempts_keep_original_roots_reports_logs_and_state(self):
        with self.temporary_directory() as temporary:
            attempt, _ = self.create(temporary)
            (attempt.root / "s/history.sqlite").write_bytes(b"first synthetic historical image")
            attempt.logs("first stdout", "first stderr")
            attempt.fail(ValueError("invalid actual proof"), phase="validate-native-proof")
            first = json.loads(attempt.report_path.read_text())
            proof_bytes = (attempt.directory / "report.json").read_bytes()
            archive_bytes = Path(first["failureArchive"]).read_bytes()
            self.assertTrue(attempt.root.is_dir())
            with zipfile.ZipFile(first["failureArchive"]) as archive:
                self.assertEqual(archive.read("state/s/history.sqlite"), b"first synthetic historical image")
                self.assertIn("state/uc/", archive.namelist())
                self.assertTrue(json.loads(archive.read("archive-manifest.json"))["files"])
            following, _ = self.create(temporary)
            following.fail(RuntimeError("later failure"), phase="native-execution")
            self.assertNotEqual(following.id, attempt.id)
            self.assertNotEqual(following.root, attempt.root)
            self.assertEqual((attempt.directory / "report.json").read_bytes(), proof_bytes)
            self.assertEqual(Path(first["failureArchive"]).read_bytes(), archive_bytes)
            self.assertEqual(json.loads((following.directory / "previous-report.json").read_text()), first)
            self.assertIn("first stderr", (following.directory / "previous-native.log").read_text())
            self.assertEqual(json.loads(following.report_path.read_text())["error"], "later failure")

    def test_archive_does_not_read_external_symlinks_directories_or_hardlinks(self):
        with self.temporary_directory() as temporary:
            attempt, _ = self.create(temporary)
            outside = Path(temporary) / "outside"
            outside.mkdir()
            secret = b"outside content must never be included"
            target = outside / "unrelated.txt"; target.write_bytes(secret)
            (attempt.root / "s/inside.sqlite").write_bytes(b"synthetic database")
            try:
                (attempt.root / "external-file").symlink_to(target)
                (attempt.root / "external-directory").symlink_to(outside, target_is_directory=True)
            except (NotImplementedError, OSError) as error:
                if os.name != "nt":
                    raise
                # Windows directory junctions do not require Developer Mode.
                junction = attempt.root / "external-junction"
                result = subprocess.run(["cmd", "/c", "mklink", "/J", str(junction), str(outside)], capture_output=True)
                self.assertEqual(result.returncode, 0, str(error))
            os.link(target, attempt.root / "external-hardlink")
            os.link(attempt.root / "s/inside.sqlite", attempt.root / "s/inside-copy.sqlite")
            attempt.fail(RuntimeError("synthetic failed probe"), phase="native-execution")
            report = json.loads(attempt.report_path.read_text())
            self.assertFalse(report["archiveComplete"])
            with zipfile.ZipFile(report["failureArchive"]) as archive:
                payloads = [archive.read(name) for name in archive.namelist()]
                self.assertFalse(any(secret in payload for payload in payloads))
                self.assertEqual(archive.read("state/s/inside.sqlite"), b"synthetic database")
                self.assertEqual(archive.read("state/s/inside-copy.sqlite"), b"synthetic database")
                skipped = json.loads(archive.read("archive-manifest.json"))["skipped"]
                self.assertTrue(any(item["path"] == "external-hardlink" for item in skipped))
                self.assertTrue(any("symlink" in item["reason"] for item in skipped))
            self.assertEqual(target.read_bytes(), secret)

    def test_real_timeout_preserves_partial_output_and_created_synthetic_state(self):
        with self.temporary_directory() as temporary:
            attempt, env = self.create(temporary)
            code = "import pathlib,sys,time;pathlib.Path(sys.argv[1]).write_text('retained');print('before timeout',flush=True);print('stderr before timeout',file=sys.stderr,flush=True);time.sleep(30)"
            with self.assertRaises(subprocess.TimeoutExpired) as caught:
                execute_native([sys.executable, "-c", code, str(attempt.root / "s/partial.sqlite")],
                    cwd=Path(temporary), env=env, timeout=1, log_directory=attempt.directory)
            attempt.fail(caught.exception, phase="native-execution")
            report = json.loads(attempt.report_path.read_text())
            self.assertIs(report["timedOut"], True)
            self.assertTrue(attempt.root.exists())
            self.assertIn("before timeout", (attempt.directory / "native.log").read_text())
            self.assertIn("stderr before timeout", (attempt.directory / "stderr.log").read_text())
            with zipfile.ZipFile(report["failureArchive"]) as archive:
                self.assertEqual(archive.read("state/s/partial.sqlite"), b"retained")

    def test_source_identity_failure_invalidates_old_pass_and_keeps_previous_result(self):
        with self.temporary_directory() as temporary:
            repository = Path(temporary) / "repository"; (repository / "scripts").mkdir(parents=True)
            latest = repository / "native-production-readers.json"
            latest.write_text(json.dumps({"status": "PASS", "source_sha": "old"}))
            with patch.object(fixture, "__file__", str(repository / "scripts/check_business_store_fixture.py")), \
                 patch.object(fixture.subprocess, "check_output", side_effect=RuntimeError("git unavailable")), \
                 self.assertRaises(SystemExit):
                fixture.main()
            report = json.loads(latest.read_text())
            self.assertEqual(report["status"], "FAIL")
            self.assertEqual(report["phase"], "source-identity")
            self.assertEqual(json.loads((Path(report["artifactDirectory"]) / "previous-report.json").read_text())["source_sha"], "old")

    def test_cloud_launcher_precreates_overrides_and_enforces_all_required_stage_proofs(self):
        for rejected in (False, True):
            with self.subTest(rejected=rejected), self.temporary_directory() as temporary:
                root = Path(temporary)
                report_path = root / "runtime.json"
                observed = []
                def native(command, *, env, **_):
                    owned = Path(command[-1]).resolve(strict=True)
                    observed.append(owned)
                    paths = [Path(env[key]).resolve(strict=True) for key in OVERRIDES]
                    self.assertEqual(len(set(paths)), 5)
                    self.assertTrue(all(path.is_dir() and path.parent == owned for path in paths))
                    (paths[0] / "diagnostic.sqlite").write_bytes(b"synthetic cloud failure state")
                    result = complete_native_report()
                    if rejected:
                        runtime = next(check for check in result["checks"] if check["name"] == "runtime-recovery-production-path")
                        del runtime["unsealedPreservationMutationRejected"]
                    return SimpleNamespace(returncode=0, stdout=json.dumps(result), stderr="cloud native diagnostic")
                with patch.object(sys, "argv", ["launcher", "synthetic-binary", "--output", str(report_path)]), \
                     patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "RUNNER_TEMP": temporary}), \
                     patch.object(cloud.subprocess, "check_output", side_effect=lambda args, **_: "d" * 40 if args[1] == "rev-parse" else ""), \
                     patch.object(cloud, "execute_native", side_effect=native), patch("builtins.print"):
                    if rejected:
                        with self.assertRaises(SystemExit): cloud.main()
                    else: cloud.main()
                report = json.loads(report_path.read_text())
                self.assertEqual(report["status"], "FAIL" if rejected else "PASS")
                self.assertEqual(len(STAGE_PROOFS), 11)
                self.assertEqual(observed[0].exists(), rejected)
                if rejected:
                    self.assertTrue(Path(report["failureArchive"]).is_file())

    def test_windows_native_path_spelling_handles_drive_unc_and_already_verbatim(self):
        self.assertEqual(native_path(r"D:\agent\temp\fixture", windows=True), "\\\\?\\D:\\agent\\temp\\fixture")
        self.assertEqual(native_path(r"\\server\share\fixture", windows=True), "\\\\?\\UNC\\server\\share\\fixture")
        self.assertEqual(native_path(r"\\?\D:\fixture", windows=True), r"\\?\D:\fixture")

    def test_home_nested_runner_and_default_temp_fall_back_to_external_system_temp(self):
        # Put the simulated home outside the system temp base, as hosted POSIX
        # runners do. A home inside /tmp would correctly make /tmp ineligible.
        with tempfile.TemporaryDirectory(prefix="tokenbar-home-layout-", dir=Path(__file__).resolve().parents[1]) as temporary:
            home = Path(temporary) / "home"
            nested = home / "work/_temp"
            nested.mkdir(parents=True)
            with patch.object(Path, "home", return_value=home), \
                 patch.dict(os.environ, {"RUNNER_TEMP": str(nested), "TOKENBAR_FIXTURE_TEMP_BASE": ""}), \
                 patch("native_fixture_evidence.tempfile.gettempdir", return_value=str(nested)):
                base = fixture_temporary_base()
                self.assertFalse(base.is_relative_to(home))
                self.assertFalse(home.is_relative_to(base))
                attempt = FixtureAttempt(Path(temporary) / "latest.json", label="home-nested-runner")
                with self.assertRaises(ValueError):
                    attempt.create_root(nested, prefix="unsafe-", slugs=("s", "c", "ss", "sc", "uc"))
                attempt.create_root(base, prefix="tokenbar-external-test-", slugs=("s", "c", "ss", "sc", "uc"))
                self.assertFalse(attempt.root.is_relative_to(home))
                attempt.succeed({"scope": "python-harness-contract-only"})

    def test_explicit_home_or_home_ancestor_override_is_rejected(self):
        with self.temporary_directory() as temporary:
            home = Path(temporary) / "home"
            nested = home / "temp"
            nested.mkdir(parents=True)
            for candidate in (home, nested, home.parent):
                with self.subTest(candidate=candidate), patch.object(Path, "home", return_value=home), \
                     patch.dict(os.environ, {"TOKENBAR_FIXTURE_TEMP_BASE": str(candidate)}), \
                     self.assertRaises(ValueError):
                    fixture_temporary_base()

    def test_windows_cross_api_birthtime_does_not_disable_same_api_change_checks(self):
        fields = dict(st_dev=7, st_ino=19, st_size=20, st_mtime_ns=1000, st_nlink=1, st_birthtime_ns=100)
        by_path = SimpleNamespace(**fields, st_ctime_ns=100)
        by_handle = SimpleNamespace(**fields, st_ctime_ns=900)
        self.assertEqual(_cross_api_identity(by_path, windows=True), _cross_api_identity(by_handle, windows=True))
        self.assertNotEqual(_cross_api_identity(by_path, windows=False), _cross_api_identity(by_handle, windows=False))
        self.assertNotEqual(_identity(by_path), _identity(by_handle))
        for key in fields:
            changed = SimpleNamespace(**{**fields, key: fields[key] + 1}, st_ctime_ns=900)
            self.assertNotEqual(_cross_api_identity(changed, windows=True), _cross_api_identity(by_handle, windows=True), key)
        changed_after_open = SimpleNamespace(**fields, st_ctime_ns=901)
        self.assertNotEqual(_identity(changed_after_open), _identity(by_handle))

    def test_archive_keeps_complete_rewritten_file_using_real_path_and_handle_metadata(self):
        with self.temporary_directory() as temporary:
            attempt, _ = self.create(temporary)
            target = attempt.root / "s/rewritten.sqlite"
            target.write_bytes(b"initial synthetic history")
            target.write_bytes(b"newly committed synthetic history")
            os.utime(target, ns=(123_000_000_000, 456_000_000_000))
            attempt.fail(RuntimeError("retain rewritten fixture"), phase="native-execution")
            report = json.loads(attempt.report_path.read_text())
            self.assertTrue(report["archiveComplete"], report.get("archiveSkipped"))
            with zipfile.ZipFile(report["failureArchive"]) as archive:
                self.assertEqual(archive.read("state/s/rewritten.sqlite"), target.read_bytes())


if __name__ == "__main__":
    unittest.main()
