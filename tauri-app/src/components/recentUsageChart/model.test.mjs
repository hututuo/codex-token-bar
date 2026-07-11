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
  recentChartTimeMarkers,
  recentChartVisibleWindowLabel,
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

function localUnix(year, monthIndex, day, hour = 0, minute = 0) {
  return Math.floor(new Date(year, monthIndex, day, hour, minute).getTime() / 1_000);
}

test("prepareRecentChartData selects range-specific points and carries cache hit rate", () => {
  const data = prepareRecentChartData("7d", {
    recentUsage24h: [point(0, { tokens: 10 })],
    recentUsage7d: [
      point(0, { calls: 1, inputTokens: 100, cachedInputTokens: 80, cacheHitRate: 0.8, fiveHourRemainingPercent: 0.7 }),
      point(3600, { calls: 0, cacheHitRate: null }),
      point(7200, { calls: 1, inputTokens: 100, cachedInputTokens: 90, cacheHitRate: 0.9, sevenDayRemainingPercent: 0.6 }),
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

test("recent chart normalizes malformed cache inputs at the model boundary", () => {
  const malformed = [
    point(0, { calls: 1, inputTokens: 100, cachedInputTokens: 250, cacheHitRate: 0.2 }),
    point(300, { calls: 1, inputTokens: 0, cachedInputTokens: 0, cacheHitRate: 1 }),
    point(600, {
      calls: 1,
      inputTokens: Number.NaN,
      cachedInputTokens: Number.POSITIVE_INFINITY,
      cacheHitRate: Number.NaN,
    }),
  ];
  const data = prepareRecentChartData("24h", {
    recentUsage24h: malformed,
    recentUsage7d: [],
    recentUsage30d: [],
  });
  const selection = quotaConsumptionSelection(data, 0, 2, "gpt55");

  assert.deepEqual(
    data.points.map(({ inputTokens, cachedInputTokens, cacheHitRate }) => ({
      inputTokens,
      cachedInputTokens,
      cacheHitRate,
    })),
    [
      { inputTokens: 100, cachedInputTokens: 100, cacheHitRate: 1 },
      { inputTokens: 0, cachedInputTokens: 0, cacheHitRate: 0 },
      { inputTokens: 0, cachedInputTokens: 0, cacheHitRate: null },
    ],
  );
  assert.ok(data.cacheHitRate >= 0 && data.cacheHitRate <= 1);
  assert.deepEqual(data.carriedCacheHitRates, [1, 0, 0]);
  assert.ok(selection.cachedInputTokens <= selection.inputTokens);
  assert.equal(data.cacheHitRate, 1);
  assert.equal(selection.cacheHitRate, 1);
});

test("recent chart preserves null cache availability while deriving numeric rates from tokens", () => {
  const data = prepareRecentChartData("24h", {
    recentUsage24h: [point(0, { calls: 1, inputTokens: 100, cachedInputTokens: 40, cacheHitRate: null })],
    recentUsage7d: [],
    recentUsage30d: [],
  });

  assert.equal(data.points[0].cacheHitRate, null);
  assert.equal(data.hasCacheCalls, false);
  assert.equal(data.cacheHitRate, 0.4);
});

test("recent chart cache normalization preserves valid points exactly", () => {
  const valid = point(0, {
    tokens: 175,
    calls: 2,
    inputTokens: 100,
    cachedInputTokens: 40,
    outputTokens: 75,
    cacheHitRate: 0.4,
  });
  const data = prepareRecentChartData("7d", {
    recentUsage24h: [],
    recentUsage7d: [valid],
    recentUsage30d: [],
  });

  assert.deepEqual(data.points, [valid]);
  assert.equal(data.cacheHitRate, 0.4);
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

test("quotaConsumptionSelection estimates quota inside an old window of the 30-day canvas", () => {
  const pointCount = 30 * 24 * 12;
  const startUnix = localUnix(2026, 5, 1);
  const oldWindowStart = 12 * 24 * 12;
  const points = Array.from({ length: pointCount }, (_, index) =>
    point(startUnix + index * 5 * 60, {
      inputTokens: index >= oldWindowStart && index <= oldWindowStart + 2 ? 100_000 : 0,
      tokens: index >= oldWindowStart && index <= oldWindowStart + 2 ? 100_000 : 0,
      calls: index >= oldWindowStart && index <= oldWindowStart + 2 ? 1 : 0,
      fiveHourRemainingPercent: index === oldWindowStart ? 0.8 : index === oldWindowStart + 1 ? 0.76 : index === oldWindowStart + 2 ? 0.72 : null,
    }),
  );
  const data = prepareRecentChartData("24h", {
    recentUsage24h: points,
    recentUsage7d: [],
    recentUsage30d: [],
  });

  const selection = quotaConsumptionSelection(data, oldWindowStart, oldWindowStart + 2, "gpt55");

  assert.equal(selection?.startUnix, points[oldWindowStart].startUnix);
  assert.equal(selection?.endUnix, points[oldWindowStart + 2].startUnix + 5 * 60);
  assert.equal(selection?.fiveHour.quotaDropPercent, 8);
  assert.equal(selection?.fiveHour.impliedWindowBudgetUSD?.toFixed(4), "18.7500");
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

test("24h long chart time markers show one local date label per day", () => {
  const startUnix = localUnix(2026, 6, 1);
  const points = Array.from({ length: 30 * 24 * 12 }, (_, index) => point(startUnix + index * 5 * 60));
  const data = prepareRecentChartData("24h", {
    recentUsage24h: points,
    recentUsage7d: [],
    recentUsage30d: [],
  });
  const markers = recentChartTimeMarkers(data, 29_000);
  const dayMarkers = markers.filter((marker) => marker.kind === "day");

  assert.equal(dayMarkers.length, 30);
  assert.equal(dayMarkers.length > data.markerIndices.length, true);
  assert.deepEqual(dayMarkers.slice(0, 3).map((marker) => marker.label), ["7月1日", "7月2日", "7月3日"]);
  assert.equal(dayMarkers.every((marker) => marker.label.includes("月") && marker.label.includes("日")), true);
  assert.equal(dayMarkers.every((marker, index) => index === 0 || marker.x > dayMarkers[index - 1].x), true);
  assert.equal(dayMarkers.at(-1).x > 20_000, true);
});

test("24h day markers are positioned by full scroll content width", () => {
  const startUnix = localUnix(2026, 6, 1);
  const points = Array.from({ length: 30 * 24 * 12 }, (_, index) => point(startUnix + index * 5 * 60));
  const data = prepareRecentChartData("24h", {
    recentUsage24h: points,
    recentUsage7d: [],
    recentUsage30d: [],
  });
  const markers = recentChartTimeMarkers(data, 29_000);
  const secondDay = markers.find((marker) => marker.label === "7月2日");
  const expectedX = (288 / (points.length - 1)) * 29_000;

  assert.equal(secondDay?.index, 288);
  assert.equal(Math.abs((secondDay?.x ?? 0) - expectedX) < 0.01, true);
});

test("7d and 30d time markers keep the existing sparse month-day behavior", () => {
  const startUnix = localUnix(2026, 6, 1);
  const sevenDayPoints = Array.from({ length: 8 }, (_, index) => point(startUnix + index * 24 * 60 * 60));
  const thirtyDayPoints = Array.from({ length: 10 }, (_, index) => point(startUnix + index * 3 * 24 * 60 * 60));
  const sevenDay = prepareRecentChartData("7d", {
    recentUsage24h: [],
    recentUsage7d: sevenDayPoints,
    recentUsage30d: [],
  });
  const thirtyDay = prepareRecentChartData("30d", {
    recentUsage24h: [],
    recentUsage7d: [],
    recentUsage30d: thirtyDayPoints,
  });

  assert.deepEqual(recentChartTimeMarkers(sevenDay, 980).map((marker) => marker.index), sevenDay.markerIndices);
  assert.deepEqual(recentChartTimeMarkers(thirtyDay, 980).map((marker) => marker.index), thirtyDay.markerIndices);
  assert.equal(recentChartTimeMarkers(sevenDay, 980).every((marker) => marker.kind === "time"), true);
  assert.equal(recentChartTimeMarkers(thirtyDay, 980).every((marker) => marker.label.includes("月")), true);
});

test("24h visible window label describes the latest local date range", () => {
  const startUnix = localUnix(2026, 6, 1, 0, 35);
  const points = Array.from({ length: 30 * 24 * 12 }, (_, index) => point(startUnix + index * 5 * 60));
  const data = prepareRecentChartData("24h", {
    recentUsage24h: points,
    recentUsage7d: [],
    recentUsage30d: [],
  });
  const layout = recentChartScrollLayout(data.range, data.points.length, data.bucketSeconds, 980);

  assert.equal(
    recentChartVisibleWindowLabel(data, layout.contentWidth, layout.latestScrollLeft, layout.viewportWidth),
    "7月30日 00:30 - 7月31日 00:30",
  );
});

test("24h visible window label follows a middle scroll position", () => {
  const startUnix = localUnix(2026, 6, 1, 0, 35);
  const points = Array.from({ length: 30 * 24 * 12 }, (_, index) => point(startUnix + index * 5 * 60));
  const data = prepareRecentChartData("24h", {
    recentUsage24h: points,
    recentUsage7d: [],
    recentUsage30d: [],
  });
  const layout = recentChartScrollLayout(data.range, data.points.length, data.bucketSeconds, 980);

  assert.equal(
    recentChartVisibleWindowLabel(data, layout.contentWidth, 10 * layout.viewportWidth, layout.viewportWidth),
    "7月11日 00:35 - 7月12日 00:35",
  );
});

test("visible window label is only used for the 24h horizontal chart", () => {
  const startUnix = localUnix(2026, 6, 1);
  const sevenDay = prepareRecentChartData("7d", {
    recentUsage24h: [],
    recentUsage7d: Array.from({ length: 8 }, (_, index) => point(startUnix + index * 24 * 60 * 60)),
    recentUsage30d: [],
  });
  const thirtyDay = prepareRecentChartData("30d", {
    recentUsage24h: [],
    recentUsage7d: [],
    recentUsage30d: Array.from({ length: 10 }, (_, index) => point(startUnix + index * 3 * 24 * 60 * 60)),
  });

  assert.equal(recentChartVisibleWindowLabel(sevenDay, 980, 0, 980), null);
  assert.equal(recentChartVisibleWindowLabel(thirtyDay, 980, 0, 980), null);
});

test("recent chart horizontal viewport keeps overlay outside the clipped scroll content", async () => {
  const css = await readFile(new URL("../../styles/global.css", import.meta.url), "utf8");
  const source = await readFile(new URL("../RecentUsageChart.tsx", import.meta.url), "utf8");

  assert.match(css, /\.recent-chart-scroll--horizontal\s*{[^}]*overflow-x:\s*auto/s);
  assert.match(css, /\.recent-chart-scroll--horizontal\s*{[^}]*overscroll-behavior-x:\s*contain/s);
  assert.match(css, /\.recent-chart-scroll--horizontal \.recent-chart-scroll-content\s*{[^}]*width:\s*var\(--recent-chart-content-width, 980px\)/s);
  assert.match(css, /\.recent-chart-overlay-layer\s*{[^}]*overflow:\s*visible/s);
  assert.match(css, /\.usage-chart\s*{[^}]*aspect-ratio:\s*var\(--recent-chart-aspect-ratio,\s*980 \/ 185\)/s);
  assert.match(css, /\.chart-day-separator\s*{[^}]*stroke:/s);
  assert.match(css, /\.recent-chart-visible-window\s*{[^}]*position:\s*absolute/s);
  assert.equal(source.includes("recentChartScrollLayout(data.range, data.points.length, data.bucketSeconds, CHART_WIDTH)"), true);
  assert.equal(source.includes("recentChartTimeMarkers(data, chartWidth)"), true);
  assert.equal(source.includes("recentChartVisibleWindowLabel(data, chartWidth, chartScrollLeft, chartViewportWidth)"), true);
  assert.equal(source.includes("\"--recent-chart-aspect-ratio\": `${chartWidth} / ${CHART_HEIGHT}`"), true);
  assert.equal(source.includes("className=\"recent-chart-overlay-layer\""), true);
  assert.equal(source.indexOf("className=\"recent-chart-visible-window\"") > source.indexOf("className=\"recent-chart-overlay-layer\""), true);
  assert.equal(source.indexOf("className=\"recent-chart-visible-window\"") > source.indexOf("recent-chart-scroll-content"), true);
  assert.equal(source.includes("chart-time-marker--"), true);
  assert.equal(source.includes("chart-day-separator"), true);
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
