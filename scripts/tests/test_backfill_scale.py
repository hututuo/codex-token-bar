import importlib.util
import json
from pathlib import Path
import unittest

path = Path(__file__).resolve().parents[1] / 'check_backfill_scale.py'
spec = importlib.util.spec_from_file_location('backfill_scale', path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class ScaleEvidenceTests(unittest.TestCase):
    def fixture(self, **changes):
        profile = dict(files=13, parsed=13, events=13, tokens=1638, complete=True, monotonic=True,
                       bootstrapSeconds=1.0, backfillSeconds=2.0, largestProgressGapSeconds=.2, totalSeconds=4.0)
        profile.update(changes)
        return module.MARKER + json.dumps(profile) + '\nTest Case ' + module.TEST + ' passed\n'

    def test_accepts_complete_profile_with_passed_test(self):
        self.assertEqual(module.parse_profile(self.fixture(), 13)['events'], 13)

    def test_rejects_missing_duplicated_or_failed_test(self):
        for text in ('', self.fixture() * 2, self.fixture().replace('passed', 'failed'),
                     self.fixture().split('\nTest Case')[0]):
            with self.subTest(text=text[:50]), self.assertRaises(ValueError):
                module.parse_profile(text, 13)

    def test_rejects_accounting_progress_and_timing_changes(self):
        for field, value in (('tokens', 1637), ('events', 12), ('files', 12), ('parsed', 26),
                             ('complete', False), ('monotonic', False), ('backfillSeconds', float('nan')),
                             ('largestProgressGapSeconds', -1), ('totalSeconds', float('inf')),
                             ('bootstrapSeconds', True)):
            with self.subTest(field=field), self.assertRaises(ValueError):
                module.parse_profile(self.fixture(**{field: value}), 13)

    def test_empty_duplicate_and_nonfinite_budgets_cannot_bypass_scale_gate(self):
        module.validate_options((13, 128, 512, 4124), 1500, 30, 600)
        invalid = [((), 1500, 30, 600), ((13, 13), 1500, 30, 600),
                   ((13,), 1500, float('nan'), 600), ((13,), 1500, 30, float('inf')),
                   ((13,), 0, 30, 600), ((13,), True, 30, 600), ((13.0,), 1500, 30, 600)]
        for options in invalid:
            with self.subTest(options=options), self.assertRaises(ValueError):
                module.validate_options(*options)

    def test_partial_or_over_budget_scale_results_cannot_pass(self):
        profiles = [dict(files=size, largestProgressGapSeconds=.2, backfillSeconds=2)
                    for size in (13, 128, 512, 4124)]
        module.validate_profiles(profiles, (13, 128, 512, 4124), 30, 600)
        for broken in (profiles[:-1], profiles[::-1], profiles + [profiles[0]]):
            with self.subTest(profiles=broken), self.assertRaises(ValueError):
                module.validate_profiles(broken, (13, 128, 512, 4124), 30, 600)
        for field, value in [('largestProgressGapSeconds', 30.1), ('backfillSeconds', 600.1)]:
            changed = [dict(profile) for profile in profiles]
            changed[-1][field] = value
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                module.validate_profiles(changed, (13, 128, 512, 4124), 30, 600)
