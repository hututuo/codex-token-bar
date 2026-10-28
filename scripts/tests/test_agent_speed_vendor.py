import contextlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
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
        self.lock = {'schemaVersion': 2, 'repository': vendor_tool.REPOSITORY,
                     'commit': SHA, 'files': vendor_tool.local_hashes(self.vendor), 'patches': {}, 'additions': {}}
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

    def test_local_addition_has_explicit_hash_and_reason(self):
        file = self.vendor / vendor_tool.SCOPES[0] / 'local-adaptation.txt'
        file.write_text('Token Bar local source observation adapter\n', encoding='utf-8')
        name = file.relative_to(self.vendor).as_posix()
        self.lock['additions'][name] = {
            'sha256': vendor_tool.digest(file, self.vendor),
            'reason': 'Token Bar local source-read observation adapter; not upstream code',
        }
        self.save()
        self.assertEqual(self.run_tool('check'), 0)
        self.lock['additions'][name]['reason'] = ''
        self.save()
        self.assertEqual(self.run_tool('check'), 1)
        self.lock['additions'][name]['reason'] = 'Token Bar local source-read observation adapter; not upstream code'
        self.lock['additions'][name]['sha256'] = 'b' * 64
        self.save()
        self.assertEqual(self.run_tool('check'), 1)

    def test_only_agent_speed_project_build_outputs_are_excluded(self):
        obj_file = self.vendor / 'windows/src/AgentSpeed.Core/obj/Debug/net10.0/generated.cs'
        bin_file = self.vendor / 'windows/src/AgentSpeed.Core/bin/Debug/net10.0/AgentSpeed.Core.dll'
        source_file = self.vendor / 'windows/src/AgentSpeed.Core/GeneratedSource.cs'
        obj_file.parent.mkdir(parents=True, exist_ok=True)
        bin_file.parent.mkdir(parents=True, exist_ok=True)
        obj_file.write_text('build generated\n', encoding='utf-8')
        bin_file.write_bytes(b'compiled output')
        source_file.write_text('source file\n', encoding='utf-8')
        inventory = vendor_tool.local_hashes(self.vendor)
        self.assertNotIn('windows/src/AgentSpeed.Core/obj/Debug/net10.0/generated.cs', inventory)
        self.assertNotIn('windows/src/AgentSpeed.Core/bin/Debug/net10.0/AgentSpeed.Core.dll', inventory)
        self.assertIn('windows/src/AgentSpeed.Core/GeneratedSource.cs', inventory)
        self.assertIn('windows/src/AgentSpeed.Core/fixture.txt', inventory)
        self.assertFalse(vendor_tool.allowed('windows/src/AgentSpeed.Core/obj/Debug/generated.cs'))
        self.assertFalse(vendor_tool.allowed('windows/src/AgentSpeed.Core/bin/Debug/generated.dll'))
        self.assertTrue(vendor_tool.allowed('windows/src/AgentSpeed.Core/Parsing/obj/source.cs'))

        obj_file.unlink()
        bin_file.unlink()
        source_file.unlink()
        self.assertEqual(self.run_tool('check'), 0)

    def test_additions_cannot_claim_an_upstream_or_patched_path(self):
        name = next(iter(self.lock['files']))
        self.lock['additions'][name] = {'sha256': 'b' * 64, 'reason': 'local'}
        self.save()
        self.assertEqual(self.run_tool('check'), 1)

    def test_schema_v1_is_rejected_after_v2_migration(self):
        self.lock['schemaVersion'] = 1
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

    def test_record_separates_reviewed_local_additions_from_upstream_patches(self):
        upstream = Path(self.temp.name) / 'upstream'
        upstream.mkdir()
        for name in vendor_tool.local_hashes(self.vendor):
            source = self.vendor / name
            target = upstream / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
        subprocess.run(['git', '-C', str(upstream), 'init', '-q'], check=True)
        subprocess.run(['git', '-C', str(upstream), 'config', 'user.email', 'test@example.invalid'], check=True)
        subprocess.run(['git', '-C', str(upstream), 'config', 'user.name', 'Fixture'], check=True)
        subprocess.run(['git', '-C', str(upstream), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(upstream), 'commit', '-qm', 'fixture upstream'], check=True)
        commit = subprocess.check_output(['git', '-C', str(upstream), 'rev-parse', 'HEAD'], text=True).strip()
        (self.vendor / 'VENDOR.md').write_text('Upstream commit: ' + commit, encoding='utf-8')

        local_file = self.vendor / vendor_tool.SCOPES[0] / 'fixture.txt'
        local_file.write_text('reviewed local patch\n', encoding='utf-8')
        local_addition = self.vendor / vendor_tool.SCOPES[0] / 'local-adaptation.txt'
        local_addition.write_text('local-only file\n', encoding='utf-8')

        patch_reasons = Path(self.temp.name) / 'patch-reasons.json'
        patch_reasons.write_text(json.dumps({
            f'{vendor_tool.SCOPES[0]}/fixture.txt': 'Product-specific compatibility patch',
        }), encoding='utf-8')
        addition_reasons = Path(self.temp.name) / 'addition-reasons.json'
        addition_reasons.write_text(json.dumps({
            f'{vendor_tool.SCOPES[0]}/local-adaptation.txt': 'Token Bar local-only adapter; not upstream code',
        }), encoding='utf-8')

        self.assertEqual(self.run_tool(
            'record', '--upstream', str(upstream), '--commit', commit,
            '--patch-reasons', str(patch_reasons), '--addition-reasons', str(addition_reasons), '--reviewed',
        ), 0)
        recorded = json.loads((self.vendor / 'UPSTREAM.json').read_text(encoding='utf-8'))
        self.assertEqual(recorded['schemaVersion'], 2)
        self.assertNotIn(f'{vendor_tool.SCOPES[0]}/local-adaptation.txt', recorded['files'])
        self.assertIn(f'{vendor_tool.SCOPES[0]}/local-adaptation.txt', recorded['additions'])
        self.assertIn(f'{vendor_tool.SCOPES[0]}/fixture.txt', recorded['patches'])
        self.assertEqual(self.run_tool('check'), 0)

    def test_record_rejects_missing_addition_reason_without_rewriting_lock(self):
        upstream = Path(self.temp.name) / 'upstream'
        upstream.mkdir()
        for name in vendor_tool.local_hashes(self.vendor):
            source = self.vendor / name
            target = upstream / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
        subprocess.run(['git', '-C', str(upstream), 'init', '-q'], check=True)
        subprocess.run(['git', '-C', str(upstream), 'config', 'user.email', 'test@example.invalid'], check=True)
        subprocess.run(['git', '-C', str(upstream), 'config', 'user.name', 'Fixture'], check=True)
        subprocess.run(['git', '-C', str(upstream), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(upstream), 'commit', '-qm', 'fixture upstream'], check=True)
        commit = subprocess.check_output(['git', '-C', str(upstream), 'rev-parse', 'HEAD'], text=True).strip()
        (self.vendor / 'VENDOR.md').write_text('Upstream commit: ' + commit, encoding='utf-8')
        (self.vendor / vendor_tool.SCOPES[0] / 'extra.txt').write_text('unexplained addition\n', encoding='utf-8')
        patch_reasons = Path(self.temp.name) / 'patch-reasons.json'
        addition_reasons = Path(self.temp.name) / 'addition-reasons.json'
        patch_reasons.write_text('{}', encoding='utf-8')
        addition_reasons.write_text('{}', encoding='utf-8')
        before = (self.vendor / 'UPSTREAM.json').read_bytes()
        self.assertEqual(self.run_tool(
            'record', '--upstream', str(upstream), '--commit', commit,
            '--patch-reasons', str(patch_reasons), '--addition-reasons', str(addition_reasons), '--reviewed',
        ), 1)
        self.assertEqual((self.vendor / 'UPSTREAM.json').read_bytes(), before)

    def test_diff_inventory_and_excluded_research(self):
        self.assertFalse(vendor_tool.allowed('spec/research/private.md'))
        self.assertFalse(vendor_tool.allowed('spec/prototypes/example.html'))
        self.assertFalse(vendor_tool.allowed('/absolute'))
        self.assertEqual(vendor_tool.changes({'keep':'x','edit':'a','gone':'b'}, {'keep':'x','edit':'b','new':'c'}),
                         {'added':['new'], 'removed':['gone'], 'modified':['edit']})


if __name__ == '__main__':
    unittest.main()
