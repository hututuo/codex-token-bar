import assert from 'node:assert/strict';
import test from 'node:test';
import { activityChartPoints } from './activitySpeedChart.ts';
const point = (bucketStart, rate = 50, seconds = 10) => ({ bucketStart, value: { weightedOutput: rate * seconds, coveredSeconds: seconds } });
test('all plotted buckets share one exact half-hour viewport and split real gaps', () => {
  const result = activityChartPoints([point(7900), point(8200), point(8500), point(10000), point(10300)], 10000);
  assert.deepEqual(result.map(p => p.bucketStart), [8200, 8500, 10000]);
  assert.deepEqual(result.map(p => p.segment), [0, 0, 1]);
});
test('expiry does not invalidate point values produced for an earlier render', () => {
  const source = [point(8200), point(8500), point(8800)];
  const before = activityChartPoints(source, 10000), after = activityChartPoints(source, 10000.001);
  assert.deepEqual(before.map(p => p.bucketStart), [8200, 8500, 8800]);
  assert.deepEqual(after.map(p => p.bucketStart), [8500, 8800]);
});
test('invalid rates are omitted and valid zero remains', () => {
  assert.deepEqual(activityChartPoints([point(9700, NaN), point(9800, 1, 0), point(9900, 0)], 10000).map(p => p.rate), [0]);
  assert.deepEqual(activityChartPoints([], NaN), []);
});
