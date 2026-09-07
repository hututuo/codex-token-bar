import test from "node:test";
import assert from "node:assert/strict";
import { firstCompleteQuotaBucketStart, lastCompleteQuotaBucketEnd } from "./quotaPeriodBoundary.ts";

test("every reset second retains all complete buckets at both period edges", () => {
  const base = 1_800_000_000;
  for (let offset = 0; offset < 300; offset++) {
    assert.equal(firstCompleteQuotaBucketStart(base + offset), base + (offset === 0 ? 0 : 300));
    assert.equal(lastCompleteQuotaBucketEnd(base + 604800 + offset), base + 604800);
  }
});

import { partitionQuotaPeriodPoints } from "./quotaPeriodBoundary.ts";
import { estimateRecent7dAPICost } from "./statsStrip/savings.ts";

function detailedPoint(startUnix) {
  const minuteModelBreakdowns = Array.from({ length: 5 }, (_, index) => ({
    eventStartUnix: startUnix + index * 60, model: "gpt-6-astra",
    breakdown: { inputTokens: (index + 1) * 100, cachedInputTokens: (index + 1) * 20,
      outputTokens: index + 1, totalTokens: (index + 1) * 101, calls: 1 },
  }));
  return { label: "", startUnix, tokens: 1515, calls: 5, inputTokens: 1500,
    cachedInputTokens: 300, outputTokens: 15, cacheHitRate: 0.2,
    fiveHourRemainingPercent: null, sevenDayRemainingPercent: null,
    modelBreakdowns: [{ model: "gpt-6-astra", breakdown: { inputTokens: 1500,
      cachedInputTokens: 300, outputTokens: 15, totalTokens: 1515, calls: 5 } }],
    minuteModelBreakdowns };
}
const sumTokens = (points) => points.reduce((sum, point) => sum + point.tokens, 0);

test("every reset second retains all clear minutes at both period edges", () => {
  const base = 1_800_000_000;
  for (let offset = 0; offset < 300; offset++) {
    const partition = partitionQuotaPeriodPoints([detailedPoint(base), detailedPoint(base + 604800)],
      base + offset, base + 604800 + offset);
    const first = Math.ceil(offset / 60);
    const last = Math.floor(offset / 60);
    const expected = [0, 1, 2, 3, 4].reduce((sum, i) => sum + (i >= first || i < last ? (i + 1) * 101 : 0), 0);
    assert.equal(sumTokens(partition.included), expected, `offset ${offset}`);
    const ambiguous = offset % 60 === 0 ? 0 : (last + 1) * 101;
    assert.equal(sumTokens(partition.leading), ambiguous);
    assert.equal(sumTokens(partition.trailing), ambiguous);
  }
});

test("old snapshots and invalid minute detail retain coarse edge accounting", () => {
  const point = detailedPoint(1_800_000_000);
  for (const detail of [undefined, point.minuteModelBreakdowns.slice(1),
    [...point.minuteModelBreakdowns, point.minuteModelBreakdowns[0]]]) {
    const result = partitionQuotaPeriodPoints([{ ...point, minuteModelBreakdowns: detail }],
      point.startUnix + 88, point.startUnix + 604888);
    assert.equal(result.included.length, 0);
    assert.equal(sumTokens(result.leading), point.tokens);
  }
});

test("7d estimator prices retained minutes and separates only ambiguous minutes", () => {
  const base = 1_800_000_000;
  const result = estimateRecent7dAPICost({ points: [detailedPoint(base), detailedPoint(base + 604800)],
    resetAtUnix: base + 604888, priceModel: "gpt6Astra" });
  assert.ok(result);
  assert.equal(result.modelBreakdowns.reduce((sum, row) => sum + row.breakdown.totalTokens, 0), 1313);
  assert.equal(result.boundaryBreakdown.leading.totalTokens, 202);
  assert.equal(result.boundaryBreakdown.trailing.totalTokens, 202);
});
