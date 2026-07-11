import assert from "node:assert/strict";
import test from "node:test";
import { LONG_RECENT_POINT_COUNT, longRecentStarts } from "../../timeSeriesTimeline.ts";
import { withSsrModules } from "../../test/ssrHarness.mjs";

test("empty recent usage follows the shared long recent timeline without values", async () => {
  return withSsrModules(async (load) => {
    const { emptyRecentUsage } = await load("/src/api/fallback/timeSeriesFallback.ts");
    const now = new Date("2026-07-11T12:02:00Z");
    const points = emptyRecentUsage(now);
    const expectedStarts = longRecentStarts(now.getTime()).map((value) => value / 1_000);

    assert.equal(points.length, LONG_RECENT_POINT_COUNT);
    assert.equal(points[0].startUnix, expectedStarts[0]);
    assert.equal(points.at(-1).startUnix, expectedStarts.at(-1));
    assert.equal(points.every((point) => point.tokens === 0), true);
    assert.equal(points.every((point) => point.fiveHourRemainingPercent === null), true);
  });
});
