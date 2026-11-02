import importlib.util
import json
import os
from pathlib import Path
import signal
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

path = Path(__file__).resolve().parents[1] / 'check_backfill_scale.py'
spec = importlib.util.spec_from_file_location('backfill_scale', path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ScaleEvidenceTests(unittest.TestCase):
    def fixture(self, files=13, events_per_file=1, legacy_jobs=0, **changes):
        events = files * events_per_file
        tokens = module.expected_tokens(files, events_per_file)
        profile = dict(
            files=files,
            parsed=files,
            eventsPerFile=events_per_file,
            events=events,
            expectedEvents=events,
            tokens=tokens,
            expectedTokens=tokens,
            legacyJobs=legacy_jobs,
            complete=True,
            monotonic=True,
            rawAccountingDigestBefore="a" * 64,
            rawAccountingDigestAfter="a" * 64,
            mainObjectsBefore=15,
            mainObjectsAfter=15,
            mainObjectDelta=0,
            mainStoresBefore=3,
            mainStoresAfter=3,
            mainStoreDelta=0,
            unchangedSamples=module.UNCHANGED_SAMPLES,
            unchangedParserCalls=0,
            unchangedP95Seconds=0.004,
            writeLockCount=24,
            maximumWriteLockSeconds=0.2,
            totalWriteLockSeconds=0.4,
            preparationSeconds=1.0,
            bootstrapSeconds=1.0,
            backfillSeconds=2.0,
            largestProgressGapSeconds=.2,
            totalSeconds=4.0,
        )
        profile.update(changes)
        return module.MARKER + json.dumps(profile) + '\nTest Case ' + module.TEST + ' passed\n'

    def test_accepts_complete_profile_with_passed_test(self):
        profile = module.parse_profile(self.fixture(), 13)
        self.assertEqual(profile['events'], 13)
        self.assertEqual(profile['tokens'], 1638)

    def test_pressure_math_and_exact_profile_are_checked(self):
        files, events_per_file, legacy_jobs = 4124, 122, 6250
        expected_events = files * events_per_file
        expected_tokens = (120 * files + files * (files - 1) // 2) * events_per_file
        profile = module.parse_profile(
            self.fixture(files, events_per_file, legacy_jobs), files, events_per_file, legacy_jobs
        )
        self.assertEqual(profile['events'], expected_events)
        self.assertEqual(profile['tokens'], expected_tokens)
        for field, value in (
            ('events', expected_events - 1),
            ('expectedEvents', expected_events + 1),
            ('tokens', expected_tokens - 1),
            ('expectedTokens', expected_tokens + 1),
            ('eventsPerFile', 121),
            ('legacyJobs', 6249),
            ('mainObjectDelta', 1),
            ('mainStoresAfter', 4),
            ('unchangedSamples', 10),
            ('unchangedParserCalls', 1),
            ('unchangedP95Seconds', float('nan')),
            ('writeLockCount', 0),
            ('maximumWriteLockSeconds', float('inf')),
            ('totalWriteLockSeconds', -0.1),
            ('rawAccountingDigestBefore', ''),
            ('rawAccountingDigestAfter', 'b' * 64),
        ):
            with self.subTest(field=field), self.assertRaises(ValueError):
                module.parse_profile(
                    self.fixture(files, events_per_file, legacy_jobs, **{field: value}),
                    files, events_per_file, legacy_jobs
                )

    def test_pressure_case_is_appended_after_all_standard_sizes(self):
        cases = module.scale_cases((13, 128, 512, 4124), pressure=True)
        self.assertEqual([case['files'] for case in cases[:4]], [13, 128, 512, 4124])
        pressure = cases[-1]
        self.assertEqual(pressure['kind'], 'synthetic-pressure')
        self.assertEqual(pressure['files'], 4124)
        self.assertEqual(pressure['eventsPerFile'], 122)
        self.assertEqual(pressure['legacyJobs'], 6250)
        self.assertEqual(pressure['expectedEvents'], 4124 * 122)
        self.assertEqual(pressure['expectedTokens'], (120 * 4124 + 4124 * 4123 // 2) * 122)
        self.assertEqual(len(module.scale_cases((13, 128, 512, 4124), pressure=False)), 4)

    def test_rejects_missing_duplicated_or_failed_test(self):
        for text in ('', self.fixture() * 2, self.fixture().replace('passed', 'failed'),
                     self.fixture().split('\nTest Case')[0]):
            with self.subTest(text=text[:50]), self.assertRaises(ValueError):
                module.parse_profile(text, 13)

    def test_rejects_accounting_progress_and_timing_changes(self):
        for field, value in (
            ('tokens', 1637), ('events', 12), ('files', 12), ('parsed', 26),
            ('complete', False), ('monotonic', False), ('backfillSeconds', float('nan')),
            ('largestProgressGapSeconds', -1), ('totalSeconds', float('inf')),
            ('writeLockCount', True), ('writeLockCount', 1.5),
            ('maximumWriteLockSeconds', float('nan')), ('totalWriteLockSeconds', float('inf')),
        ):
            with self.subTest(field=field), self.assertRaises(ValueError):
                module.parse_profile(self.fixture(**{field: value}), 13)

    def test_failed_case_does_not_skip_later_sizes_or_pressure(self):
        case_specs = module.scale_cases((13, 128, 512, 4124), pressure=True)
        attempts = []
        outcomes = [
            {'code': 0},
            {'code': 1},  # A compile/test failure must be recorded; 512 and 4124 still run.
            {'code': 0},
            {'code': 0},
            {'code': 0},
        ]

        class FakeProcess:
            def __init__(self, outcome, stdout, env):
                self.outcome = outcome
                self.stdout = stdout
                self.env = env
                self.pid = 321000 + int(env['TOKENBAR_BACKFILL_FILE_COUNT'])
                self.returncode = None

            def wait(self, timeout=None):
                if self.returncode is not None:
                    return self.returncode
                if 'timeout' in self.outcome:
                    raise module.subprocess.TimeoutExpired('swift test', timeout)
                self.returncode = self.outcome['code']
                if self.returncode == 0:
                    files = int(self.env['TOKENBAR_BACKFILL_FILE_COUNT'])
                    events_per_file = int(self.env['TOKENBAR_BACKFILL_EVENTS_PER_FILE'])
                    legacy_jobs = int(self.env['TOKENBAR_BACKFILL_LEGACY_JOBS'])
                    self.stdout.write(ScaleEvidenceTests().fixture(files, events_per_file, legacy_jobs))
                return self.returncode

            def kill(self):
                self.returncode = -9

        def fake_popen(command, cwd, env, stdout, stderr, **options):
            index = len(attempts)
            attempts.append((command, env.copy(), options))
            return FakeProcess(outcomes[index], stdout, env)

        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'evidence'
            with patch.object(module.subprocess, 'check_output', return_value='source-sha\n'), \
                    patch.object(module.subprocess, 'Popen', side_effect=fake_popen):
                report = module.run_sizes(
                    Path(temporary), output, (13, 128, 512, 4124), 1200, 30, 600, pressure=True
                )

            self.assertEqual(len(attempts), 5)
            self.assertEqual(report['status'], 'FAIL')
            self.assertEqual([case['name'] for case in report['cases']], [case['name'] for case in case_specs])
            self.assertEqual([case['status'] for case in report['cases']], ['PASS', 'FAIL', 'PASS', 'PASS', 'PASS'])
            self.assertEqual(report['cases'][1]['error'], 'swift test returned 1; compile/test failure; see size-128.log')
            self.assertEqual(report['profiles'][-1]['events'], 4124 * 122)
            self.assertEqual(report['profiles'][-1]['legacyJobs'], 6250)
            self.assertTrue((output / 'report.json').exists())
            pressure_env = attempts[-1][1]
            self.assertEqual(pressure_env['TOKENBAR_BACKFILL_EVENTS_PER_FILE'], '122')
            self.assertEqual(pressure_env['TOKENBAR_BACKFILL_LEGACY_JOBS'], '6250')
            self.assertIn('--skip-build', attempts[1][0])
            self.assertNotIn('--skip-build', attempts[2][0], 'A failed case makes the next size rebuild explicitly')
            self.assertEqual(attempts[0][2].get('start_new_session'), True if os.name != 'nt' else None)

    def test_timeout_is_an_explicit_case_failure_and_following_case_runs(self):
        attempts = []

        class FakeProcess:
            def __init__(self, stdout, env, timeout_case):
                self.stdout = stdout
                self.env = env
                self.timeout_case = timeout_case
                self.pid = 987654
                self.returncode = None
                self.wait_count = 0

            def poll(self):
                return self.returncode

            def wait(self, timeout=None):
                self.wait_count += 1
                if self.returncode is not None:
                    return self.returncode
                if self.timeout_case and self.wait_count == 1:
                    raise module.subprocess.TimeoutExpired('swift test', timeout)
                if not self.timeout_case:
                    self.returncode = 0
                    return self.returncode
                self.returncode = -9
                return self.returncode

            def kill(self):
                self.returncode = -9

        def fake_popen(command, cwd, env, stdout, stderr, **options):
            timeout_case = not attempts
            attempts.append((command, options))
            if len(attempts) > 1:
                files = int(env['TOKENBAR_BACKFILL_FILE_COUNT'])
                stdout.write(self.fixture(files))
            return FakeProcess(stdout, env, timeout_case)

        killer = (patch.object(module.subprocess, 'run', return_value=SimpleNamespace(returncode=0))
                  if os.name == 'nt' else patch.object(module.os, 'killpg'))
        with tempfile.TemporaryDirectory() as temporary:
            with patch.object(module.subprocess, 'check_output', return_value='sha'), \
                    patch.object(module.subprocess, 'Popen', side_effect=fake_popen), killer as kill_mock:
                report = module.run_sizes(Path(temporary), Path(temporary) / 'evidence', (13, 128), 1, 30, 600)
        self.assertEqual([case['status'] for case in report['cases']], ['FAIL', 'PASS'])
        self.assertIn('1s execution deadline', report['cases'][0]['error'])
        self.assertEqual(len(attempts), 2)
        if os.name == 'nt':
            self.assertEqual(kill_mock.call_args.args[0], ['taskkill', '/PID', '987654', '/T', '/F'])
        else:
            kill_mock.assert_called_once_with(987654, signal.SIGKILL)

    def test_threshold_breaches_remain_in_report_and_do_not_skip_cases(self):
        attempts = []
        changes = [
            {'unchangedP95Seconds': 1.01},
            {'maximumWriteLockSeconds': 10.01},
            {},
        ]

        class FakeProcess:
            def __init__(self, stdout, env, override):
                self.stdout = stdout
                self.env = env
                self.override = override
                self.returncode = None

            def wait(self, timeout=None):
                files = int(self.env['TOKENBAR_BACKFILL_FILE_COUNT'])
                self.stdout.write(ScaleEvidenceTests().fixture(files, **self.override))
                self.returncode = 0
                return 0

        def fake_popen(command, cwd, env, stdout, stderr, **options):
            override = changes[len(attempts)]
            attempts.append((command, env.copy()))
            return FakeProcess(stdout, env, override)

        with tempfile.TemporaryDirectory() as temporary:
            with patch.object(module.subprocess, 'check_output', return_value='sha'), \
                    patch.object(module.subprocess, 'Popen', side_effect=fake_popen):
                report = module.run_sizes(Path(temporary), Path(temporary) / 'evidence',
                                          (13, 128, 512), 1200, 30, 600)
        self.assertEqual([case['status'] for case in report['cases']], ['FAIL', 'FAIL', 'PASS'])
        self.assertEqual(len(report['profiles']), 3, 'Valid profiles survive gate failures for evidence')
        self.assertIn('Unchanged p95', report['cases'][0]['error'])
        self.assertIn('Maximum write lock', report['cases'][1]['error'])
        self.assertEqual(report['budgets']['maxUnchangedP95Seconds'], 1.0)
        self.assertEqual(report['budgets']['maxWriteLockSeconds'], 10.0)
        self.assertEqual(len(attempts), 3)

    def test_windows_timeout_uses_taskkill_for_only_its_process_tree(self):
        class FakeProcess:
            pid = 424242

            def __init__(self):
                self.returncode = None
                self.waited = False

            def poll(self):
                return self.returncode

            def wait(self):
                self.waited = True
                self.returncode = -9
                return self.returncode

        process = FakeProcess()
        with patch.object(module.subprocess, 'run', return_value=SimpleNamespace(returncode=0)) as taskkill:
            issue = module._terminate_case_process_tree(process, windows=True)
        self.assertIsNone(issue)
        taskkill.assert_called_once_with(
            ['taskkill', '/PID', '424242', '/T', '/F'], check=False,
            stdout=module.subprocess.DEVNULL, stderr=module.subprocess.DEVNULL,
        )
        self.assertTrue(process.waited)

    @unittest.skipIf(os.name == 'nt', 'POSIX session groups are not available on Windows')
    def test_missing_posix_process_group_is_tolerated_and_reaped(self):
        class FakeProcess:
            pid = 424243

            def __init__(self):
                self.waited = False

            def wait(self):
                self.waited = True

        process = FakeProcess()
        with patch.object(module.os, 'killpg', side_effect=ProcessLookupError) as killpg:
            issue = module._terminate_case_process_tree(process, windows=False)
        self.assertIsNone(issue)
        killpg.assert_called_once_with(424243, signal.SIGKILL)
        self.assertTrue(process.waited)


if __name__ == '__main__':
    unittest.main()
