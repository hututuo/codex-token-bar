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

    def test_matrix_requires_both_states_and_both_process_restarts(self):
        results = [dict(status='PASS', scenario=scenario, phase=phase)
                   for scenario in probe.SCENARIOS for phase in probe.PHASES]
        probe.validate_matrix(results)
        for broken in (results[:-1], results + [results[0]],
                       [dict(item, status='FAIL') if n == 1 else item for n, item in enumerate(results)],
                       [results[0]] * 4):
            with self.subTest(results=broken), self.assertRaises(ValueError):
                probe.validate_matrix(broken)

    def test_first_scenario_failure_does_not_hide_independent_second_state(self):
        visited, saved = [], []
        report = {'scenarios': []}
        def operation(scenario):
            visited.append(scenario)
            if scenario == 'committed':
                raise RuntimeError('committed producer failed')
            return [dict(status='PASS', scenario=scenario, phase=phase) for phase in probe.PHASES]
        with self.assertRaisesRegex(ValueError, 'committed producer failed'):
            probe.collect_scenarios(operation, report, lambda: saved.append(len(report['scenarios'])))
        self.assertEqual(visited, ['committed', 'interrupted'])
        self.assertEqual(saved, [2, 4])
        self.assertEqual([item['status'] for item in report['scenarios']], ['FAIL', 'FAIL', 'PASS', 'PASS'])

    def test_failed_resume_still_captures_reopen_and_preserves_synthetic_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            output = base / 'evidence'; output.mkdir()
            root = base / 'committed'
            phases = []
            def execute(command, cwd, env, log, **options):
                phase = command[-1]; phases.append(phase)
                log.write_text(phase)
                if phase == 'committed':
                    quota = root / 'support/quota.sqlite'; quota.write_bytes(b'synthetic')
                    (root / 'formed-state.json').write_text(json.dumps(dict(
                        producerVersion='0.9.8', cfgTest=False, phase='committed',
                        proofs={'synthetic': {}}, formedExact=True, formedB=True, legacyQuota=str(quota))))
                    return ''
                if phase == 'resume':
                    raise RuntimeError('resume failed')
                return self.report(phase='reopen')
            with patch.object(probe, 'execute', side_effect=execute):
                results = probe.run_scenario(base, '0.9.8', 'committed', root, base,
                    {'release': Path('old'), 'candidate': Path('new')}, output)
            self.assertEqual(phases, ['committed', 'resume', 'reopen'])
            self.assertEqual([item['status'] for item in results], ['FAIL', 'PASS'])
            self.assertTrue((output / 'committed-synthetic-state.zip').is_file())
            self.assertTrue((output / 'committed-resume.log').is_file())

    def test_producer_metadata_cannot_redirect_late_quota_write_outside_fixture(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            output = base / 'evidence'; output.mkdir()
            root = base / 'interrupted'
            outside = base / 'outside.sqlite'; outside.write_bytes(b'preserve')
            def execute(command, cwd, env, log, **options):
                (root / 'formed-state.json').write_text(json.dumps(dict(
                    producerVersion='0.9.8', cfgTest=False, phase='interrupted',
                    proofs={'synthetic': {}}, formedExact=False, formedB=False, legacyQuota=str(outside))))
                return ''
            with patch.object(probe, 'execute', side_effect=execute) as runner:
                results = probe.run_scenario(base, '0.9.8', 'interrupted', root, base,
                    {'release': Path('old'), 'candidate': Path('new')}, output)
            self.assertEqual(runner.call_count, 1)
            self.assertTrue(all(item['status'] == 'FAIL' and 'escapes' in item['error'] for item in results))
            self.assertEqual(outside.read_bytes(), b'preserve')

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
        self.assertIn('Container::snapshot_digest_path',source)
        self.assertIn('actual.schema_digest,actual.rows_digest',source)
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

    def test_runner_temp_in_home_falls_back_without_weakening_native_isolation(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root).resolve()
            home = root / "home"; home.mkdir()
            runner = home / "work-temp"; runner.mkdir()
            external = root / "os-temp"; external.mkdir()
            self.assertEqual(probe.external_temporary_base([runner, external], home), external)
            for candidate in (home, runner, root, root / "missing"):
                with self.subTest(path=candidate), self.assertRaises(ValueError):
                    probe.external_temporary_base([candidate], home)
            environment = probe.probe_environment(external)
            self.assertTrue(all(environment[key] == str(external) for key in ("TMPDIR", "TMP", "TEMP")))

    @unittest.skipIf(sys.platform == "win32", "unprivileged Windows symlink creation not required")
    def test_temp_symlink_cannot_disguise_a_real_home(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root).resolve(); home = root / "home"; home.mkdir()
            alias = root / "not-home"; alias.symlink_to(home, target_is_directory=True)
            with self.assertRaises(ValueError): probe.external_temporary_base([alias], home)
