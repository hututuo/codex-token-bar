import assert from "node:assert/strict";
import test from "node:test";
import {
  hoverIndexForX,
  optionalSmoothPath,
  percentText,
  prepareRecentChartData,
  smoothPath,
} from "./model.ts";

function point(startUnix, overrides = {}) {
  return {
    label: "00:00",
    startUnix,
    tokens: 0,
    calls: 0,
    inputTokens: 0,
    cachedInputTokens: 0,
    cacheHitRate: null,
    fiveHourRemainingPercent: null,
    sevenDayRemainingPercent: null,
    ...overrides,
  };
}

test("prepareRecentChartData selects range-specific points and carries cache hit rate", () => {
  const data = prepareRecentChartData("7d", {
    recentUsage24h: [point(0, { tokens: 10 })],
    recentUsage7d: [
      point(0, { calls: 1, cacheHitRate: 0.8, fiveHourRemainingPercent: 0.7 }),
      point(3600, { calls: 0, cacheHitRate: null }),
      point(7200, { calls: 1, cacheHitRate: 0.9, sevenDayRemainingPercent: 0.6 }),
    ],
    recentUsage30d: [point(0, { tokens: 30 })],
  });

  assert.equal(data.title, "最近 7 天");
  assert.equal(data.points.length, 3);
  assert.deepEqual(data.carriedCacheHitRates, [0.8, 0.8, 0.9]);
  assert.equal(data.latestFiveHourRemaining, 0.7);
  assert.equal(data.latestSevenDayRemaining, 0.6);
  assert.equal(data.markerIndices.at(-1), 2);
});

test("prepareRecentChartData weights headline cache rate by input tokens", () => {
  const data = prepareRecentChartData("24h", {
    recentUsage24h: [
      point(0, {
        calls: 100,
        inputTokens: 100,
        cachedInputTokens: 0,
        cacheHitRate: 0,
      }),
      point(300, {
        calls: 1,
        inputTokens: 900,
        cachedInputTokens: 900,
        cacheHitRate: 1,
      }),
    ],
    recentUsage7d: [],
    recentUsage30d: [],
  });

  assert.equal(data.cacheHitRate, 0.9);
});

test("smoothPath uses cubic commands and optionalSmoothPath breaks at missing quota points", () => {
  const path = smoothPath([
    { x: 0, y: 10 },
    { x: 10, y: 0 },
    { x: 20, y: 10 },
  ]);

  assert.match(path, /^M 0 10 C /);
  assert.equal(
    optionalSmoothPath([{ x: 0, y: 0 }, null, { x: 10, y: 10 }, { x: 20, y: 5 }]).split(" M ")
      .length,
    2,
  );
});

test("smoothPath falls back to a full polyline when x positions are not increasing", () => {
  const path = smoothPath([
    { x: 0, y: 0 },
    { x: 10, y: 10 },
    { x: 10, y: 5 },
    { x: 20, y: 0 },
  ]);

  assert.equal(path, "M 0 0 L 10 10 L 10 5 L 20 0");
});

test("hover index rounds to nearest point and percentText formats 0-1 values", () => {
  assert.equal(hoverIndexForX(24, 100, 5), 1);
  assert.equal(hoverIndexForX(99, 100, 5), 4);
  assert.equal(hoverIndexForX(-1, 100, 5), null);
  assert.equal(percentText(0.834), "83%");
  assert.equal(percentText(null), "--");
});
