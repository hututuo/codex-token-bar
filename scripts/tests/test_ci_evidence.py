import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/cloud"))
from ci_evidence import make_ci_evidence, read_evidence, validate_ci_evidence, validate_recovery_verdict
import release_packet

SHA = "a" * 40
RUN = "12345"


def verdict():
    return {
        "source_sha": SHA, "run_id": RUN, "passed": True,
        "jobs": {name: "success" for name in
                 ["source", "harness-contracts", "public-v097", "readers", "formed-release", "swift-formed-release", "rust-backfill-scale", "swift-backfill-scale"]},
        "public_release": "0.9.7",
        "public_release_sha": "0219554ce444b0013987da7b82e3c2e891f4afdb",
        "formed_releases": ["0.9.8", "0.9.9", "0.9.10", "0.9.11"],
        "formed_runtime": "Rust production, not native Swift formed-release evidence",
        "swift_formed_releases": ["0.9.8", "0.9.9", "0.9.10", "0.9.11"],
        "swift_formed_runtime": "native-swift-xctest-production-apis",
        "swift_backfill_sizes": [13, 128, 512, 4124],
        "rust_backfill_sizes": [13, 128, 512, 4124],
        "rust_backfill_profile": "release",
        "rust_backfill_runtime": "non-cfg-test-production-apis-windows-macos",
        "scope": "Synthetic unit-test evidence; no native run is claimed",
    }


class CIEvidenceTests(unittest.TestCase):
    def test_complete_native_verdict_is_retained_and_bound(self):
        source = verdict()
        sealed = make_ci_evidence(source, SHA, RUN)
        self.assertEqual(sealed["database_recovery"], source)
        self.assertEqual(validate_ci_evidence(sealed, SHA, RUN), sealed)

    def test_flag_only_or_old_evidence_is_rejected(self):
        for value in [
            {"source_sha": SHA, "run_id": RUN, "passed": True},
            {"source_sha": SHA, "run_id": RUN, "passed": True, "database_recovery_required": True},
        ]:
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "required recovery proof"):
                validate_ci_evidence(value, SHA, RUN)

    def test_every_unverified_job_status_and_omission_is_rejected(self):
        for name in verdict()["jobs"]:
            for status in ["failure", "cancelled", "skipped", None, ""]:
                value = verdict()
                value["jobs"][name] = status
                with self.subTest(name=name, status=status), self.assertRaises(ValueError):
                    validate_recovery_verdict(value, SHA, RUN)
            value = verdict()
            del value["jobs"][name]
            with self.subTest(omitted=name), self.assertRaises(ValueError):
                validate_recovery_verdict(value, SHA, RUN)
        value = verdict()
        value["jobs"]["unexpected"] = "success"
        with self.assertRaises(ValueError):
            validate_recovery_verdict(value, SHA, RUN)

    def test_outer_and_nested_source_and_run_must_both_match(self):
        for target in ["outer", "nested"]:
            for key, wrong in [("source_sha", "b" * 40), ("run_id", "54321"), ("run_id", 12345)]:
                value = make_ci_evidence(verdict(), SHA, RUN)
                (value if target == "outer" else value["database_recovery"])[key] = wrong
                with self.subTest(target=target, key=key), self.assertRaises(ValueError):
                    validate_ci_evidence(value, SHA, RUN)

    def test_pass_is_a_boolean_not_a_truthy_value(self):
        for target in ["outer", "nested"]:
            for wrong in [False, 1, "true", None]:
                value = make_ci_evidence(verdict(), SHA, RUN)
                (value if target == "outer" else value["database_recovery"])["passed"] = wrong
                with self.subTest(target=target, wrong=wrong), self.assertRaises(ValueError):
                    validate_ci_evidence(value, SHA, RUN)
        value = make_ci_evidence(verdict(), SHA, RUN)
        value["database_recovery_required"] = False
        with self.assertRaises(ValueError):
            validate_ci_evidence(value, SHA, RUN)

    def test_partial_duplicate_or_relabelled_matrices_are_rejected(self):
        for key, wrong in [
            ("public_release", None), ("public_release", "0.9.8"),
            ("public_release_sha", "b" * 40),
            ("formed_releases", ["0.9.8", "0.9.9", "0.9.10"]),
            ("formed_releases", ["0.9.8", "0.9.9", "0.9.10", "0.9.10"]),
            ("swift_formed_releases", ["0.9.8", "0.9.9", "0.9.10"]),
            ("swift_formed_releases", ["0.9.8", "0.9.9", "0.9.10", "0.9.10"]),
            ("swift_formed_runtime", "macOS Rust"),
            ("swift_formed_runtime", None),
            ("swift_backfill_sizes", [13, 128, 512]),
            ("swift_backfill_sizes", [13, 128, 512, 512]),
            ("swift_backfill_sizes", [13, 128, 512, 4124.0]),
            ("rust_backfill_sizes", None),
            ("rust_backfill_sizes", [13, 128, 512]),
            ("rust_backfill_sizes", [13, 128, 512, 512]),
            ("rust_backfill_sizes", [13, 128, 512, 4124.0]),
            ("rust_backfill_profile", "dev"), ("rust_backfill_profile", None),
            ("rust_backfill_runtime", "cfg-test"), ("rust_backfill_runtime", "Linux"),
            ("formed_runtime", ""), ("scope", None),
        ]:
            value = verdict()
            value[key] = wrong
            with self.subTest(key=key, wrong=wrong), self.assertRaises(ValueError):
                validate_recovery_verdict(value, SHA, RUN)

    def test_invalid_source_or_run_is_not_accepted(self):
        for sha, run in [("main", RUN), (SHA, "0"), (SHA, "1;unsafe"), (SHA, 12345)]:
            with self.subTest(sha=sha, run=run), self.assertRaises(ValueError):
                make_ci_evidence(verdict(), sha, run)

    def test_cli_seal_and_verify_downloaded_proof_without_overwriting(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            original, sealed = directory / "recovery-checked-source.json", directory / "checked-source.json"
            original.write_text(json.dumps(verdict()))
            base = [sys.executable, str(ROOT / "scripts/cloud/ci_evidence.py")]
            seal = [*base, "seal", "--source-sha", SHA, "--run-id", RUN,
                    "--input", str(original), "--output", str(sealed)]
            result = subprocess.run(seal, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            retained = sealed.read_bytes()
            result = subprocess.run([*base, "verify", "--source-sha", SHA, "--run-id", RUN,
                                     "--input", str(sealed)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotEqual(subprocess.run(seal, capture_output=True).returncode, 0)
            self.assertEqual(sealed.read_bytes(), retained)
            self.assertNotEqual(subprocess.run([*base, "verify", "--source-sha", SHA,
                "--run-id", "999", "--input", str(sealed)], capture_output=True).returncode, 0)

    def test_failed_verdict_never_produces_a_sealed_success_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            original, sealed = directory / "verdict.json", directory / "checked-source.json"
            value = verdict()
            value["jobs"]["swift-backfill-scale"] = "skipped"
            original.write_text(json.dumps(value))
            result = subprocess.run([sys.executable, str(ROOT / "scripts/cloud/ci_evidence.py"),
                "seal", "--source-sha", SHA, "--run-id", RUN, "--input", str(original),
                "--output", str(sealed)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(sealed.exists())

    def test_missing_file_and_symlink_cannot_supply_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with self.assertRaises(ValueError):
                read_evidence(directory / "missing")
            original, link = directory / "original", directory / "link"
            original.write_text(json.dumps(verdict()))
            try:
                link.symlink_to(original)
            except OSError:
                self.skipTest("This host cannot create test symlinks")
            with self.assertRaises(ValueError):
                read_evidence(link)

    def test_signer_rejects_flag_only_evidence_before_secrets_or_network(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            evidence = directory / "checked-source.json"
            evidence.write_text(json.dumps({"source_sha": SHA, "run_id": RUN, "passed": True,
                                            "database_recovery_required": True}))
            args = SimpleNamespace(source_sha=SHA, build_run="123", ci_run=RUN,
                macos=directory / "mac", windows=directory / "windows", ci_evidence=evidence,
                output=directory / "packet")
            version = json.loads((ROOT / "tauri-app/package.json").read_text())["version"]
            with patch.object(release_packet, "run", return_value=SHA + "\n"), \
                    patch.object(release_packet, "load_verified", return_value={"version": version}), \
                    patch.object(release_packet, "api") as api, \
                    patch.object(release_packet, "write_signing_key") as write_key:
                with self.assertRaisesRegex(ValueError, "required recovery proof"):
                    release_packet.sign(args)
                api.assert_not_called()
                write_key.assert_not_called()
            self.assertFalse(args.output.exists())

    def test_publication_packet_rechecks_nested_proof_even_when_hashes_match(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            version = "0.9.12"
            names = release_packet.public_names(version)
            for name in names + release_packet.SUPPORT:
                (directory / name).write_text("synthetic unit test; no real signatures")
            invalid = make_ci_evidence(verdict(), SHA, RUN)
            invalid["database_recovery"]["run_id"] = "999"
            (directory / "checked-source.json").write_text(json.dumps(invalid))
            manifest = {"schema": 2, "source_sha": SHA, "version": version, "ci_run_id": RUN,
                "update_signed": True, "public_release": False, "public_assets": names,
                "files": [{"name": path.name, "bytes": path.stat().st_size,
                           "sha256": release_packet.digest(path)} for path in directory.iterdir()]}
            (directory / "release-manifest.json").write_text(json.dumps(manifest))
            with patch.object(release_packet, "verify_sparkle") as verify_signature:
                with self.assertRaisesRegex(ValueError, "Native recovery verdict"):
                    release_packet.verify_packet(directory, SHA)
                verify_signature.assert_not_called()

    def test_old_signed_packet_schema_cannot_bypass_recovery_requirement(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "release-manifest.json").write_text(json.dumps({"schema": 1, "version": "0.9.11"}))
            with self.assertRaisesRegex(ValueError, "new recovery-verified signing packet"):
                release_packet.verify_packet(directory, SHA)


if __name__ == "__main__":
    unittest.main()
