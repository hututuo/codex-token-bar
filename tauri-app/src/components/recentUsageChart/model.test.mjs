import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  clickQuotaSelection,
  hoverIndexForX,
  optionalSmoothPath,
  percentText,
  prepareRecentChartData,
  quotaConsumptionSelection,
  recentChartScrollLayout,
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
    outputTokens: 0,
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

test("quotaConsumptionSelection uses cumulative quota drop instead of start-end delta", () => {
  const data = prepareRecentChartData("24h", {
    recentUsage24h: [
      point(0, { inputTokens: 100_000, cachedInputTokens: 0, outputTokens: 0, tokens: 100_000, calls: 1, fiveHourRemainingPercent: 0.8, sevenDayRemainingPercent: 0.9 }),
      point(300, { inputTokens: 100_000, cachedInputTokens: 0, outputTokens: 0, tokens: 100_000, calls: 1, fiveHourRemainingPercent: 0.75, sevenDayRemainingPercent: 0.88 }),
      point(600, { inputTokens: 100_000, cachedInputTokens: 0, outputTokens: 0, tokens: 100_000, calls: 1, fiveHourRemainingPercent: 0.78, sevenDayRemainingPercent: 0.89 }),
      point(900, { inputTokens: 100_000, cachedInputTokens: 0, outputTokens: 0, tokens: 100_000, calls: 1, fiveHourRemainingPercent: 0.7, sevenDayRemainingPercent: 0.86 }),
    ],
    recentUsage7d: [],
    recentUsage30d: [],
  });

  const selection = quotaConsumptionSelection(data, 0, 3, "gpt55");

  assert.equal(selection?.bucketCount, 4);
  assert.equal(selection?.fiveHour.quotaDropPercent, 13);
  assert.equal(selection?.sevenDay.quotaDropPercent, 5);
  assert.equal(selection?.fiveHour.impliedWindowBudgetUSD?.toFixed(4), "15.3846");
  assert.equal(selection?.sevenDay.impliedWindowBudgetUSD?.toFixed(4), "40.0000");
});

test("quotaConsumptionSelection ignores isolated full-usage quota spikes", () => {
  const data = prepareRecentChartData("24h", {
    recentUsage24h: [
      point(0, { inputTokens: 100_000, tokens: 100_000, calls: 1, fiveHourRemainingPercent: 1, sevenDayRemainingPercent: 1 }),
      point(300, { inputTokens: 100_000, tokens: 100_000, calls: 1, fiveHourRemainingPercent: 0, sevenDayRemainingPercent: 0 }),
      point(600, { inputTokens: 100_000, tokens: 100_000, calls: 1, fiveHourRemainingPercent: 0.99, sevenDayRemainingPercent: 0.99 }),
      point(900, { inputTokens: 100_000, tokens: 100_000, calls: 1, fiveHourRemainingPercent: 0.98, sevenDayRemainingPercent: 0.98 }),
    ],
    recentUsage7d: [],
    recentUsage30d: [],
  });

  const selection = quotaConsumptionSelection(data, 0, 3, "gpt55");

  assert.equal(selection?.fiveHour.quotaDropPercent, 2);
  assert.equal(selection?.sevenDay.quotaDropPercent, 2);
});

test("quotaConsumptionSelection ignores isolated full remaining spikes before reset", () => {
  const data = prepareRecentChartData("24h", {
    recentUsage24h: [
      point(0, { inputTokens: 100_000, tokens: 100_000, calls: 1, fiveHourRemainingPercent: 0.8, sevenDayRemainingPercent: 0.7 }),
      point(300, { inputTokens: 100_000, tokens: 100_000, calls: 1, fiveHourRemainingPercent: 1, sevenDayRemainingPercent: 1 }),
      point(600, { inputTokens: 100_000, tokens: 100_000, calls: 1, fiveHourRemainingPercent: 0.78, sevenDayRemainingPercent: 0.69 }),
    ],
    recentUsage7d: [],
    recentUsage30d: [],
  });

  const selection = quotaConsumptionSelection(data, 0, 2, "gpt55");

  assert.equal(selection?.fiveHour.quotaDropPercent, 2);
  assert.equal(selection?.sevenDay.quotaDropPercent, 1);
});

test("recent chart gives the 24h viewport a 30-day horizontal history canvas", () => {
  const layout = recentChartScrollLayout("24h", 30 * 24 * 12, 5 * 60, 980);

  assert.equal(layout.isHorizontal, true);
  assert.equal(layout.viewportWidth, 980);
  assert.equal(layout.windowCount, 30);
  assert.equal(layout.contentWidth > 20_000, true);
  assert.equal(layout.latestScrollLeft, layout.contentWidth - layout.viewportWidth);
  assert.equal(recentChartScrollLayout("24h", 289, 5 * 60, 980).contentWidth, 980);
  assert.equal(recentChartScrollLayout("7d", 30 * 24 * 12, 5 * 60, 980).isHorizontal, false);
  assert.equal(recentChartScrollLayout("30d", 30 * 24 * 12, 5 * 60, 980).isHorizontal, false);
});

test("recent chart horizontal viewport keeps overlay outside the clipped scroll content", async () => {
  const css = await readFile(new URL("../../styles/global.css", import.meta.url), "utf8");
  const source = await readFile(new URL("../RecentUsageChart.tsx", import.meta.url), "utf8");

  assert.match(css, /\.recent-chart-scroll--horizontal\s*{[^}]*overflow-x:\s*auto/s);
  assert.match(css, /\.recent-chart-scroll--horizontal\s*{[^}]*overscroll-behavior-x:\s*contain/s);
  assert.match(css, /\.recent-chart-scroll--horizontal \.recent-chart-scroll-content\s*{[^}]*width:\s*var\(--recent-chart-content-width, 980px\)/s);
  assert.match(css, /\.recent-chart-overlay-layer\s*{[^}]*overflow:\s*visible/s);
  assert.equal(source.includes("recentChartScrollLayout(data.range, data.points.length, data.bucketSeconds, CHART_WIDTH)"), true);
  assert.equal(source.includes("className=\"recent-chart-overlay-layer\""), true);
  assert.equal(source.includes("x={activeTokenPoint.x - chartScrollLeft}"), true);
});

test("clickQuotaSelection previews on hover, pins on second click, resets on third click", () => {
  let state = clickQuotaSelection({ startIndex: null, fixedEndIndex: null }, 4, 10);

  assert.deepEqual(state, { startIndex: 4, fixedEndIndex: null });
  assert.equal(state.fixedEndIndex ?? 7, 7);

  state = clickQuotaSelection(state, 7, 10);
  assert.deepEqual(state, { startIndex: 4, fixedEndIndex: 7 });

  state = clickQuotaSelection(state, 2, 10);
  assert.deepEqual(state, { startIndex: 2, fixedEndIndex: null });
});

test("RecentUsageChart exposes click-to-estimate quota UI", async () => {
  const source = await readFile(new URL("../RecentUsageChart.tsx", import.meta.url), "utf8");

  for (const expected of [
    "点击起点/终点可估算额度",
    "recentChartScrollLayout(data.range, data.points.length, data.bucketSeconds, CHART_WIDTH)",
    "recent-chart-scroll-content",
    "recent-chart-overlay-layer",
    "quotaConsumptionSelection",
    "clickQuotaSelection",
    "RecentChartQuotaEstimateOverlay",
    "反推总额度",
    "官方 API",
    "偏离 6x",
  ]) {
    assert.equal(source.includes(expected), true, expected);
  }
});
