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
                             ('largestProgressGapSeconds', -1), ('totalSeconds', float('inf'))):
            with self.subTest(field=field), self.assertRaises(ValueError):
                module.parse_profile(self.fixture(**{field: value}), 13)
