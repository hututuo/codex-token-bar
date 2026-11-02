import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

scripts = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(scripts))
import check_formed_release_upgrade as probe

class FormedEvidenceTests(unittest.TestCase):
    def report(self, **changes):
        value = dict(status='PASS', phase='resume', producerVersion='0.9.8', scenario='committed',
            cfgTest=False, totals=[162, 310], oldTypedProofsPreserved=True, crashWALPreserved=True,
            rawDisappearanceRetainsHistory=True, oldBPreserved=True)
        value.update(changes)
        return probe.PREFIX + json.dumps(value)

    def test_proof_requires_actual_release_and_every_preservation_property(self):
        self.assertEqual(probe.parse_report(self.report(), 'resume', '0.9.8', 'committed')['totals'], [162,310])
        for field, value in [('cfgTest', True), ('totals', [155,310]), ('producerVersion','0.9.7'),
                             ('oldTypedProofsPreserved',False), ('oldBPreserved',False),
                             ('crashWALPreserved',False), ('rawDisappearanceRetainsHistory',False)]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                probe.parse_report(self.report(**{field:value}), 'resume', '0.9.8', 'committed')

    def test_no_duplicate_or_absent_proof_can_pass(self):
        for text in ('', self.report()+'\n'+self.report()):
            with self.assertRaises(ValueError):
                probe.parse_report(text, 'resume', '0.9.8', 'committed')

    def test_wrong_tag_cannot_silently_test_another_release(self):
        with patch.object(probe.subprocess, 'check_output', return_value='0'*40+'\n'):
            with self.assertRaises(ValueError): probe.pinned_revision(Path('.'), '0.9.8')

    def test_archive_refuses_existing_destination(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaises(ValueError): probe.inject(Path('.'), '0'*40, Path(root))

    def test_injection_is_additive_and_production_paths_are_explicit(self):
        self.assertEqual(len(probe.OVERRIDES), 5)
        source=(scripts/'fixtures/formed_release_probe.rs').read_text()
        self.assertIn('route::bootstrap()',source)
        self.assertIn('std::process::exit(86)',source)
        self.assertIn('Container::snapshot_proof_path',source)
        self.assertIn('fs::canonicalize',source)
        self.assertNotIn('std::env::set_var',source)
        self.assertNotIn('#[cfg(test)]',source)
        self.assertEqual(set(probe.INJECTION),{'tauri-app/src-tauri/src/lib.rs','tauri-app/src-tauri/Cargo.toml',
            'tauri-app/src-tauri/src/formed_release_probe.rs','tauri-app/src-tauri/examples/formed-release-probe.rs'})

    def test_execution_cannot_ignore_exit_status(self):
        with tempfile.TemporaryDirectory() as root:
            log=Path(root)/'log'
            with self.assertRaises(RuntimeError):
                probe.execute([sys.executable,'-c','raise SystemExit(3)'],Path(root),{},log)
            self.assertTrue(log.is_file())
