import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'agent_speed_vendor.py'
spec = importlib.util.spec_from_file_location('agent_speed_vendor', SCRIPT)
vendor_tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vendor_tool)
SHA = 'a' * 40


class AgentSpeedVendorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.vendor = Path(self.temp.name) / 'vendor'
        for scope in vendor_tool.SCOPES:
            file = self.vendor / scope / 'fixture.txt'
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text('upstream fixture\n', encoding='utf-8')
        (self.vendor / 'LICENSE').write_text('MIT License\nPermission is hereby granted\n', encoding='utf-8')
        (self.vendor / 'VENDOR.md').write_text('Upstream commit: ' + SHA, encoding='utf-8')
        self.lock = {'schemaVersion': 1, 'repository': vendor_tool.REPOSITORY,
                     'commit': SHA, 'files': vendor_tool.local_hashes(self.vendor), 'patches': {}}
        self.save()

    def save(self):
        (self.vendor / 'UPSTREAM.json').write_text(json.dumps(self.lock), encoding='utf-8')

    def run_tool(self, *args):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return vendor_tool.main([*args, '--vendor', str(self.vendor)])

    def test_default_check_is_offline_and_detects_content_added_and_removed_files(self):
        with patch.object(vendor_tool, 'remote_head', side_effect=AssertionError('no network')):
            self.assertEqual(self.run_tool('check'), 0)
        file = self.vendor / vendor_tool.SCOPES[0] / 'fixture.txt'
        file.write_text('modified', encoding='utf-8')
        self.assertEqual(self.run_tool('check'), 1)
        file.unlink()
        self.assertEqual(self.run_tool('check'), 1)
        extra = self.vendor / vendor_tool.SCOPES[0] / 'unexpected.txt'
        extra.write_text('extra', encoding='utf-8')
        self.assertEqual(self.run_tool('check'), 1)

    def test_patch_has_explicit_hash_and_reason(self):
        file = self.vendor / vendor_tool.SCOPES[0] / 'fixture.txt'
        file.write_text('local identity adaptation', encoding='utf-8')
        name = file.relative_to(self.vendor).as_posix()
        self.lock['patches'][name] = {'sha256': vendor_tool.digest(file, self.vendor), 'reason': 'client identity'}
        self.save()
        self.assertEqual(self.run_tool('check'), 0)
        self.lock['patches'][name]['reason'] = ''
        self.save()
        self.assertEqual(self.run_tool('check'), 1)

    def test_pin_license_and_unsafe_paths_fail_closed(self):
        self.lock['files']['../outside'] = 'b' * 64
        self.save()
        self.assertEqual(self.run_tool('check'), 1)
        self.lock['files'].pop('../outside')
        self.save()
        (self.vendor / 'VENDOR.md').write_text('different commit', encoding='utf-8')
        self.assertEqual(self.run_tool('check'), 1)

    def test_symlink_is_not_followed(self):
        target = Path(self.temp.name) / 'outside'
        target.write_text('do not read', encoding='utf-8')
        file = self.vendor / vendor_tool.SCOPES[0] / 'fixture.txt'
        file.unlink()
        file.symlink_to(target)
        self.assertEqual(self.run_tool('check'), 1)

    def test_release_remote_check_requires_current_pin(self):
        with patch.object(vendor_tool, 'remote_head', return_value=SHA):
            self.assertEqual(self.run_tool('check', '--remote'), 0)
        with patch.object(vendor_tool, 'remote_head', return_value='b' * 40):
            self.assertEqual(self.run_tool('check', '--remote'), 1)

    def test_record_requires_review_and_does_not_change_existing_lock(self):
        before = (self.vendor / 'UPSTREAM.json').read_bytes()
        self.assertEqual(self.run_tool('record'), 1)
        self.assertEqual((self.vendor / 'UPSTREAM.json').read_bytes(), before)

    def test_diff_inventory_and_excluded_research(self):
        self.assertFalse(vendor_tool.allowed('spec/research/private.md'))
        self.assertFalse(vendor_tool.allowed('spec/prototypes/example.html'))
        self.assertFalse(vendor_tool.allowed('/absolute'))
        self.assertEqual(vendor_tool.changes({'keep':'x','edit':'a','gone':'b'}, {'keep':'x','edit':'b','new':'c'}),
                         {'added':['new'], 'removed':['gone'], 'modified':['edit']})


if __name__ == '__main__':
    unittest.main()
