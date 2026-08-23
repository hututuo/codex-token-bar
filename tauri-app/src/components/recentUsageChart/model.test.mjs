import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  clickQuotaSelection,
  hoverIndexForX,
  optionalSmoothPath,
  percentText,
  prepareRecentChartData,
  plotChartPoints,
  quotaComparisonScopeText,
  quotaConsumptionSelection,
  quotaSelectionAttribution,
  quotaSelectionDurationText,
  quotaEstimateWindowVisibility,
  recentChartGeometry,
  recentChartHeightFraction,
  recentChartCostPointRadius,
  recentChartScaleMap,
  recentChartScrollLayout,
  recentChartScrollPresentation,
  recentChartScrollTarget,
  recentChartTimeMarkers,
  recentChartVisibleWindowLabel,
  recentChartVisibleWindowIndices,
  recentChartVisibleWindowSummary,
  scaledCostPoints,
  scaledCostPointRadii,
  smoothPath,
  shouldReopenPreviewOnHoverMove,
  tokenAreaPath,
} from "./model.ts";
import { withSsrModules } from "../../test/ssrHarness.mjs";
import { LONG_RECENT_POINT_COUNT } from "../../timeSeriesTimeline.ts";

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

test("all recent chart ranges use the 278px canvas", () => {
  const expected = {
    canvasHeight: 278,
    plotTop: 27,
    plotHeight: 215,
    timeMarkerGap: 36,
  };
  for (const range of ["24h", "7d", "30d"]) {
    assert.deepEqual(recentChartGeometry(range), expected, range);
  }
});

test("token peak leaves headroom below the top edge", () => {
  const data = prepareRecentChartData("24h", {
    recentUsage24h: [
      point(0, { tokens: 50 }),
      point(300, { tokens: 100 }),
    ],
    recentUsage7d: [],
    recentUsage30d: [],
  });
  const plotted = plotChartPoints(data, 100, 100, "gpt56Sol");
  assert.ok(Math.abs(plotted.tokenPoints[1].y - 35) < 1e-9);
  assert.equal(plotted.callPoints[1].y, 100);
  assert.ok(plotted.tokenPoints[0].y > plotted.tokenPoints[1].y);
});

test("the unified scale map gives each series its explicit visual range", () => {
  const scaleMap = recentChartScaleMap({
    tokenValues: [50, 100],
    callValues: [5, 10],
    costs: [5, 17.5, 30, 0],
  });
  assert.equal(recentChartHeightFraction(100, scaleMap.tokens), 0.65);
  assert.equal(recentChartHeightFraction(10, scaleMap.calls), 1);
  assert.equal(recentChartHeightFraction(1, scaleMap.cacheHitRate), 1);
  assert.equal(recentChartHeightFraction(1, scaleMap.quota), 1);
  assert.equal(recentChartHeightFraction(5, scaleMap.cost), 0.45);
  assert.equal(recentChartHeightFraction(17.5, scaleMap.cost), 0.7);
  assert.equal(recentChartHeightFraction(30, scaleMap.cost), 0.95);

  const costs = scaledCostPoints([5, 17.5, 30, 0], 100, 100, scaleMap.cost);
  assert.equal(costs.length, 4);
  const visibleCosts = costs.filter(Boolean);
  assert.equal(visibleCosts.length, 3);
  assert.ok(Math.abs(visibleCosts[0].y - 55) < 1e-9);
  assert.ok(Math.abs(visibleCosts[1].y - 30) < 1e-9);
  assert.ok(Math.abs(visibleCosts[2].y - 5) < 1e-9);
  assert.equal(costs[3], null);
  assert.equal(recentChartCostPointRadius(5, scaleMap.cost), 1.6);
  assert.equal(recentChartCostPointRadius(17.5, scaleMap.cost), 2.9);
  assert.equal(recentChartCostPointRadius(30, scaleMap.cost), 4.2);
  assert.equal(recentChartCostPointRadius(0, scaleMap.cost), 0);
  assert.deepEqual(scaledCostPointRadii([5, 17.5, 30, 0], scaleMap.cost), [1.6, 2.9, 4.2, null]);

  const data = prepareRecentChartData("24h", {
    recentUsage24h: [
      point(0, { tokens: 1_000_000, calls: 1, inputTokens: 1_000_000 }),
      point(300, { tokens: 1_000_000, calls: 1, outputTokens: 1_000_000 }),
      point(600),
    ],
    recentUsage7d: [],
    recentUsage30d: [],
  });
  const plotted = plotChartPoints(data, 100, 100, "gpt56Sol");
  assert.deepEqual(plotted.bucketCostsUSD, [5, 30, 0]);
  assert.equal(plotted.costPoints.length, 3);
  assert.equal(plotted.costPoints.filter(Boolean).length, 2);
  assert.equal(plotted.costPoints[2], null);
  assert.equal(plotted.costPointRadii[0], 1.6);
  assert.equal(plotted.costPointRadii[1], 4.2);
  assert.equal(plotted.costPointRadii[2], null);
});

test("only the token scale adapts to the visible bucket window and fixed scales reuse precomputed costs", () => {
  const data = prepareRecentChartData("24h", {
    recentUsage24h: [
      point(0, { tokens: 50, calls: 1 }),
      point(300, { tokens: 100, calls: 2 }),
      point(600, { tokens: 200, calls: 4 }),
      point(900, { tokens: 400, calls: 8 }),
    ],
    recentUsage7d: [],
    recentUsage30d: [],
  });
  const precomputedCosts = [1, 2, 4, 8];
  const firstWindow = plotChartPoints(data, 100, 100, "gpt56Sol", {
    bucketCostsUSD: precomputedCosts,
    scaleWindow: { startIndex: 0, endIndex: 1 },
  });
  const secondWindow = plotChartPoints(data, 100, 100, "gpt56Sol", {
    bucketCostsUSD: precomputedCosts,
    scaleWindow: { startIndex: 2, endIndex: 3 },
  });

  assert.equal(firstWindow.scaleMap.tokens.maximum, 100);
  assert.equal(secondWindow.scaleMap.tokens.maximum, 400);
  assert.ok(Math.abs(firstWindow.tokenPoints[1].y - 35) < 1e-9);
  assert.ok(Math.abs(secondWindow.tokenPoints[3].y - 35) < 1e-9);
  assert.equal(firstWindow.scaleMap.cost.minimum, 1);
  assert.equal(firstWindow.scaleMap.cost.maximum, 8);
  assert.equal(secondWindow.scaleMap.cost.minimum, 1);
  assert.equal(secondWindow.scaleMap.cost.maximum, 8);
  assert.equal(firstWindow.scaleMap.calls.maximum, 8);
  assert.equal(secondWindow.scaleMap.calls.maximum, 8);
  assert.strictEqual(firstWindow.bucketCostsUSD, precomputedCosts);
  assert.strictEqual(secondWindow.bucketCostsUSD, precomputedCosts);
});

test("plotChartPoints renders only the requested slice while preserving global x coordinates", () => {
  const points = Array.from({ length: 100 }, (_, index) => point(index * 300, {
    tokens: index + 1,
    calls: index % 7,
  }));
  const data = prepareRecentChartData("24h", {
    recentUsage24h: points,
    recentUsage7d: [],
    recentUsage30d: [],
  });
  const plotted = plotChartPoints(data, 990, 215, "gpt56Sol", {
    bucketCostsUSD: Array(100).fill(0),
    renderWindow: { startIndex: 18, endIndex: 32 },
    scaleWindow: { startIndex: 20, endIndex: 30 },
  });

  assert.equal(plotted.renderStartIndex, 18);
  assert.equal(plotted.renderEndIndex, 32);
  assert.equal(plotted.tokenPoints.length, 15);
  assert.equal(plotted.callPoints.length, 15);
  assert.equal(plotted.tokenPoints[0].x, 180);
  assert.equal(plotted.tokenPoints.at(-1).x, 320);
});

test("prepareRecentChartData keeps low-activity cache gaps unknown instead of carrying stale rates", () => {
  const data = prepareRecentChartData("7d", {
    recentUsage24h: [point(0, { tokens: 10 })],
    recentUsage7d: [
      point(0, { calls: 1, inputTokens: 100, cachedInputTokens: 51, cacheHitRate: 0.51, fiveHourRemainingPercent: 0.7 }),
      point(3600, { calls: 0, cacheHitRate: null }),
      point(7200, { calls: 1, inputTokens: 100, cachedInputTokens: 91, cacheHitRate: 0.91, sevenDayRemainingPercent: 0.6 }),
    ],
    recentUsage30d: [point(0, { tokens: 30 })],
  });

  assert.equal(data.title, "最近 7 天");
  assert.equal(data.points.length, 3);
  assert.deepEqual(data.observedCacheHitRates, [0.51, null, 0.91]);
  assert.equal(data.latestFiveHourRemaining, 0.7);
  assert.equal(data.latestSevenDayRemaining, 0.6);
  assert.equal(data.markerIndices.at(-1), 2);
});

test("quota estimate visibility follows historical windows instead of current official availability", () => {
  const data = prepareRecentChartData("24h", {
    recentUsage24h: [
      point(0, { fiveHourRemainingPercent: 0.8, sevenDayRemainingPercent: 0.9 }),
    ],
    recentUsage7d: [],
    recentUsage30d: [],
  });

  assert.deepEqual(quotaEstimateWindowVisibility(data), {
    fiveHour: true,
    sevenDay: true,
  });
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
  assert.deepEqual(data.observedCacheHitRates, [1, 0, null]);
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
  assert.match(optionalSmoothPath([{ x: 4, y: 6 }, null]), /^M 4 6 L /);
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

test("tokenAreaPath stays valid for empty, single, and multi-point series", () => {
  assert.equal(tokenAreaPath([], 20, 20), "");
  assert.equal(
    tokenAreaPath([{ x: 4, y: 6 }], 20, 20),
    "M 4 6 L 4 20 L 4 20 Z",
  );
  const multi = tokenAreaPath([
    { x: 4, y: 6 },
    { x: 12, y: 3 },
    { x: 20, y: 8 },
  ], 20, 20);
  assert.match(multi, /^M 4 6 C /);
  assert.match(multi, / L 20 20 L 4 20 Z$/);
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

test("quotaConsumptionSelection keeps only the latest quota cycle after a reset", () => {
  const data = prepareRecentChartData("24h", {
    recentUsage24h: [
      point(0, { inputTokens: 100_000, tokens: 100_000, calls: 1, sevenDayRemainingPercent: 0.20 }),
      point(300, { inputTokens: 100_000, tokens: 100_000, calls: 1, sevenDayRemainingPercent: 0.10 }),
      point(600, { inputTokens: 100_000, tokens: 100_000, calls: 1, sevenDayRemainingPercent: 1.00 }),
      point(900, { inputTokens: 100_000, tokens: 100_000, calls: 1, sevenDayRemainingPercent: 0.90 }),
    ],
    recentUsage7d: [],
    recentUsage30d: [],
  });

  const selection = quotaConsumptionSelection(data, 0, 3, "gpt56Sol");
  assert.equal(selection?.sevenDay.quotaDropPercent, 10);
  assert.equal(selection?.selectedCostUSD, 2);
  assert.equal(selection?.sevenDay.comparisonBreakdown.inputTokens, 200_000);
  assert.equal(selection?.sevenDay.impliedWindowBudgetUSD, 10);
  const attribution = quotaSelectionAttribution(selection, {
    status: "indistinguishable",
    priceBasis: "radar20260730",
    radarPlanTotalUSD: 100,
    quotaDataStale: false,
    radarDataStale: false,
    usagePendingQuotaRefresh: false,
    historyChangedLowConfidence: false,
    cycleStartUnix: 0,
    cycleEndUnix: 604_800,
    segmentStartUnix: 0,
    quotaUpdatedAtUnix: 1_200,
  });
  assert.equal(attribution?.state, "provisional");
  assert.equal(attribution?.allowsAttributionConclusion, false);
});

test("quota consumption keeps unaligned edge buckets as separate accounting", () => {
  const data = prepareRecentChartData("24h", {
    recentUsage24h: [0, 300, 600].map((startUnix, index) => point(startUnix, {
      inputTokens: 100,
      tokens: 100,
      calls: 1,
      sevenDayRemainingPercent: 0.9 - index * 0.1,
    })),
    recentUsage7d: [],
    recentUsage30d: [],
  });

  const selection = quotaConsumptionSelection(data, 0, 2, "gpt56Sol", {
    sevenDay: { resetAtUnix: 720, periodSeconds: 600 },
  });

  assert.ok(selection);
  assert.equal(selection.sevenDay.boundaryBreakdown.leading.totalTokens, 100);
  assert.equal(selection.sevenDay.boundaryBreakdown.trailing.totalTokens, 100);
  assert.equal(selection.sevenDay.comparisonBreakdown.totalTokens, 100);
  assert.equal(selection.sevenDay.comparisonStartUnix, 300);
  assert.equal(selection.sevenDay.comparisonEndUnix, 600);
});

test("latest quota cycle with one remaining point fails closed for the budget inversion", () => {
  const data = prepareRecentChartData("24h", {
    recentUsage24h: [
      point(0, { inputTokens: 100_000, tokens: 100_000, calls: 1, sevenDayRemainingPercent: 0.20 }),
      point(300, { inputTokens: 100_000, tokens: 100_000, calls: 1, sevenDayRemainingPercent: 0.10 }),
      point(600, { inputTokens: 100_000, tokens: 100_000, calls: 1, sevenDayRemainingPercent: 1.00 }),
    ],
    recentUsage7d: [],
    recentUsage30d: [],
  });

  const selection = quotaConsumptionSelection(data, 0, 2, "gpt56Sol");
  assert.equal(selection?.selectedCostUSD, 1.5);
  assert.equal(selection?.sevenDay.quotaDropAvailable, false);
  assert.equal(selection?.sevenDay.quotaDropPercent, 0);
  assert.equal(selection?.sevenDay.impliedWindowBudgetUSD, null);
});

test("latest quota cycle suffix semantics cover 24h, 7d and 30d chart paths", () => {
  for (const [range, bucketSeconds, pointsKey] of [
    ["24h", 5 * 60, "recentUsage24h"],
    ["7d", 60 * 60, "recentUsage7d"],
    ["30d", 6 * 60 * 60, "recentUsage30d"],
  ]) {
    const points = [0.90, 0.80, 0.95, 0.23].map((remaining, index) => point(index * bucketSeconds, {
      inputTokens: 100_000,
      tokens: 100_000,
      calls: 1,
      sevenDayRemainingPercent: remaining,
    }));
    const data = prepareRecentChartData(range, {
      recentUsage24h: pointsKey === "recentUsage24h" ? points : [],
      recentUsage7d: pointsKey === "recentUsage7d" ? points : [],
      recentUsage30d: pointsKey === "recentUsage30d" ? points : [],
    });
    const selection = quotaConsumptionSelection(data, 0, 3, "gpt56Sol");

    assert.ok(selection, range);
    assert.equal(selection.selectedCostUSD, 2, range);
    assert.equal(selection.sevenDay.quotaDropPercent, 72, range);
    assert.equal(selection.sevenDay.comparisonBreakdown.inputTokens, 200_000, range);
    assert.equal(selection.sevenDay.comparisonStartUnix, 2 * bucketSeconds, range);
    assert.equal(selection.sevenDay.impliedWindowBudgetUSD, 1.3888888888888888, range);
    assert.equal(
      quotaComparisonScopeText(selection, { fiveHour: false, sevenDay: true }),
      "7d 反推仅按同周期可比区间",
      range,
    );
  }
});

test("7d and 30d selections use the same complete model-aware attribution semantics", () => {
  for (const [range, bucketSeconds, pointsKey] of [
    ["7d", 60 * 60, "recentUsage7d"],
    ["30d", 6 * 60 * 60, "recentUsage30d"],
  ]) {
    const points = [0, 1, 2].map((index) => point(index * bucketSeconds, {
      inputTokens: 1_000_000,
      tokens: 1_000_000,
      calls: 1,
      sevenDayRemainingPercent: [0.90, 0.87, 0.86][index],
      modelBreakdowns: [{
        model: "gpt-5.6-terra",
        breakdown: { inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0, totalTokens: 1_000_000, calls: 1 },
      }],
    }));
    const data = prepareRecentChartData(range, {
      recentUsage24h: [],
      recentUsage7d: pointsKey === "recentUsage7d" ? points : [],
      recentUsage30d: pointsKey === "recentUsage30d" ? points : [],
    });
    const selection = quotaConsumptionSelection(data, 0, 1, "gpt56Sol");
    const attribution = quotaSelectionAttribution(selection, {
      status: "indistinguishable",
      priceBasis: "radar20260730",
      radarPlanTotalUSD: 100,
      quotaDataStale: false,
      radarDataStale: false,
      usagePendingQuotaRefresh: false,
      historyChangedLowConfidence: false,
      cycleStartUnix: 0,
      cycleEndUnix: 7 * 24 * 60 * 60,
      segmentStartUnix: 0,
      quotaUpdatedAtUnix: 2 * bucketSeconds,
    });

    assert.ok(selection);
    assert.ok(attribution);
    assert.equal(attribution.accountDropPercent, 3);
    assert.equal(attribution.localComparableCostUSD, 4);
    assert.equal(attribution.localSharePercent, 4);
    assert.equal(attribution.state, "withinTolerance");
    assert.equal(attribution.allowsAttributionConclusion, true);
  }
});

test("coarse 7d/30d reset boundaries stay provisional instead of attributing across cycles", () => {
  for (const [range, bucketSeconds, pointsKey] of [
    ["7d", 60 * 60, "recentUsage7d"],
    ["30d", 6 * 60 * 60, "recentUsage30d"],
  ]) {
    const points = [0.20, 0.10, 1.00, 0.90].map((remaining, index) => point(index * bucketSeconds, {
      inputTokens: 100_000,
      tokens: 100_000,
      calls: 1,
      sevenDayRemainingPercent: remaining,
    }));
    const data = prepareRecentChartData(range, {
      recentUsage24h: [],
      recentUsage7d: pointsKey === "recentUsage7d" ? points : [],
      recentUsage30d: pointsKey === "recentUsage30d" ? points : [],
    });
    const selection = quotaConsumptionSelection(data, 0, 3, "gpt56Sol");

    assert.ok(selection);
    assert.equal(selection.sevenDay.quotaDropPercent, 10);
    assert.equal(selection.sevenDay.comparisonStartUnix, 2 * bucketSeconds);
    const attribution = quotaSelectionAttribution(selection, {
      status: "indistinguishable",
      priceBasis: "radar20260730",
      radarPlanTotalUSD: 100,
      quotaDataStale: false,
      radarDataStale: false,
      usagePendingQuotaRefresh: false,
      historyChangedLowConfidence: false,
      cycleStartUnix: 0,
      cycleEndUnix: 7 * 24 * 60 * 60,
      segmentStartUnix: 0,
      quotaUpdatedAtUnix: 4 * bucketSeconds,
    });
    assert.equal(attribution?.state, "provisional");
    assert.equal(attribution?.allowsAttributionConclusion, false);
  }
});

test("partial model rows fall back to complete selected tokens instead of inventing attribution", () => {
  const data = prepareRecentChartData("7d", {
    recentUsage24h: [],
    recentUsage7d: [0, 3600].map((startUnix) => point(startUnix, {
      inputTokens: 1_000_000,
      tokens: 1_000_000,
      calls: 1,
      sevenDayRemainingPercent: startUnix === 0 ? 0.90 : 0.87,
      // This deliberately covers only half of the point. The model-aware
      // estimator must fall back to the full token breakdown.
      modelBreakdowns: [{
        model: "gpt-5.6-terra",
        breakdown: { inputTokens: 500_000, cachedInputTokens: 0, outputTokens: 0, totalTokens: 500_000, calls: 1 },
      }],
    })),
    recentUsage30d: [],
  });
  const selection = quotaConsumptionSelection(data, 0, 1, "gpt56Sol");
  const attribution = quotaSelectionAttribution(selection, {
    status: "indistinguishable",
    priceBasis: "radar20260730",
    radarPlanTotalUSD: 100,
    quotaDataStale: false,
    radarDataStale: false,
    usagePendingQuotaRefresh: false,
    historyChangedLowConfidence: false,
    cycleStartUnix: 0,
    cycleEndUnix: 604_800,
    segmentStartUnix: 0,
    quotaUpdatedAtUnix: 7_200,
  });

  assert.ok(selection);
  assert.equal(selection.selectedCostUSD, 10);
  assert.equal(attribution?.localComparableCostUSD, 10);
  assert.equal(attribution?.localCurrentAPIEquivalentUSD, 10);
});

test("missing 7d snapshots keep local conversion visible but never conclude attribution", () => {
  const data = prepareRecentChartData("7d", {
    recentUsage24h: [],
    recentUsage7d: [0, 3600].map((startUnix) => point(startUnix, {
      inputTokens: 1_000_000,
      tokens: 1_000_000,
      calls: 1,
      modelBreakdowns: [{
        model: "gpt-5.6-terra",
        breakdown: { inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0, totalTokens: 1_000_000, calls: 1 },
      }],
    })),
    recentUsage30d: [],
  });
  const selection = quotaConsumptionSelection(data, 0, 1, "gpt56Sol");
  const attribution = quotaSelectionAttribution(selection, {
    status: "indistinguishable",
    priceBasis: "radar20260730",
    radarPlanTotalUSD: 100,
    quotaDataStale: false,
    radarDataStale: false,
    usagePendingQuotaRefresh: false,
    historyChangedLowConfidence: false,
    cycleStartUnix: 0,
    cycleEndUnix: 604_800,
    segmentStartUnix: 0,
    quotaUpdatedAtUnix: 7_200,
  });

  assert.ok(selection);
  assert.equal(attribution?.state, "missingQuotaHistory");
  assert.equal(attribution?.localComparableCostUSD, 4);
  assert.equal(attribution?.accountDropPercent, null);
  assert.equal(attribution?.allowsAttributionConclusion, false);
});

test("quotaConsumptionSelection never invents output from total minus input", () => {
  const data = prepareRecentChartData("24h", {
    recentUsage24h: [
      point(0, { inputTokens: 600_000, outputTokens: undefined, tokens: 1_000_000, calls: 1 }),
    ],
    recentUsage7d: [],
    recentUsage30d: [],
  });

  const selection = quotaConsumptionSelection(data, 0, 0, "gpt56Sol");
  assert.equal(selection?.outputTokens, 0);
  assert.equal(selection?.selectedCostUSD, 3);
});

test("24h selection attribution compares observed account drop with Radar-priced local usage", () => {
  const data = prepareRecentChartData("24h", {
    recentUsage24h: [
      point(0, {
        inputTokens: 1_000_000,
        tokens: 1_000_000,
        calls: 1,
        sevenDayRemainingPercent: 0.90,
        modelBreakdowns: [{
          model: "gpt-5.6-terra",
          breakdown: { inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0, totalTokens: 1_000_000, calls: 1 },
        }],
      }),
      point(300, {
        inputTokens: 1_000_000,
        tokens: 1_000_000,
        calls: 1,
        sevenDayRemainingPercent: 0.87,
        modelBreakdowns: [{
          model: "gpt-5.6-terra",
          breakdown: { inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0, totalTokens: 1_000_000, calls: 1 },
        }],
      }),
    ],
    recentUsage7d: [],
    recentUsage30d: [],
  });
  const selection = quotaConsumptionSelection(data, 0, 1, "gpt56Sol");
  assert.ok(selection);

  const result = quotaSelectionAttribution(selection, {
    status: "indistinguishable",
    priceBasis: "radar20260730",
    radarPlanTotalUSD: 100,
    quotaDataStale: false,
    radarDataStale: false,
    usagePendingQuotaRefresh: false,
    historyChangedLowConfidence: false,
    cycleStartUnix: 0,
    cycleEndUnix: 604_800,
    segmentStartUnix: 0,
    quotaUpdatedAtUnix: 600,
  });

  assert.ok(result);
  assert.equal(result.accountDropPercent, 3);
  assert.equal(result.localComparableCostUSD, 4);
  assert.equal(result.localCurrentAPIEquivalentUSD, 4);
  assert.equal(result.localSharePercent, 4);
  assert.equal(result.nonLocalDifferencePercent, -1);
  assert.equal(result.state, "withinTolerance");
});

test("24h selection attribution keeps the local Radar conversion when quota history is unavailable", () => {
  const data = prepareRecentChartData("24h", {
    recentUsage24h: [
      point(0, {
        inputTokens: 1_000_000,
        tokens: 1_000_000,
        calls: 1,
        modelBreakdowns: [{
          model: "gpt-5.6-terra",
          breakdown: { inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0, totalTokens: 1_000_000, calls: 1 },
        }],
      }),
      point(300, {
        inputTokens: 1_000_000,
        tokens: 1_000_000,
        calls: 1,
        modelBreakdowns: [{
          model: "gpt-5.6-terra",
          breakdown: { inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0, totalTokens: 1_000_000, calls: 1 },
        }],
      }),
    ],
    recentUsage7d: [],
    recentUsage30d: [],
  });
  const selection = quotaConsumptionSelection(data, 0, 1, "gpt56Sol");
  assert.ok(selection);

  const result = quotaSelectionAttribution(selection, {
    status: "awaitingAccountSwitchBaseline",
    priceBasis: "radar20260730",
    radarPlanTotalUSD: 100,
    quotaDataStale: false,
    radarDataStale: false,
    usagePendingQuotaRefresh: false,
    historyChangedLowConfidence: false,
    cycleStartUnix: 0,
    cycleEndUnix: 604_800,
    segmentStartUnix: 0,
    quotaUpdatedAtUnix: 600,
  });

  assert.ok(result);
  assert.equal(result.state, "missingQuotaHistory");
  assert.equal(result.accountDropPercent, null);
  assert.equal(result.localComparableCostUSD, 4);
  assert.equal(result.localCurrentAPIEquivalentUSD, 4);
  assert.equal(result.localSharePercent, 4);
  assert.equal(result.nonLocalDifferencePercent, null);
  assert.equal(result.allowsAttributionConclusion, false);
});

test("Spark-only selected range keeps breakdown and calls while reporting independent quota", () => {
  const sparkPoints = [0, 300].map((startUnix) => point(startUnix, {
    inputTokens: 1_000_000,
    tokens: 1_000_000,
    calls: 1,
    modelBreakdowns: [{
      model: "gpt-5.3-codex-spark",
      breakdown: { inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0, totalTokens: 1_000_000, calls: 1 },
    }],
  }));
  const data = prepareRecentChartData("24h", {
    recentUsage24h: sparkPoints,
    recentUsage7d: [],
    recentUsage30d: [],
  });
  const selection = quotaConsumptionSelection(data, 0, 1, "gpt56Sol");

  assert.ok(selection);
  assert.equal(selection.selectedCostUSD, 0);
  assert.equal(selection.totalTokens, 2_000_000);
  assert.equal(selection.calls, 2);
  assert.deepEqual(selection.excludedModels, ["gpt-5.3-codex-spark"]);
  assert.equal(selection.excludedCalls, 2);
  assert.equal(selection.fiveHour.excludedCalls, 2);
  assert.equal(selection.sevenDay.excludedCalls, 2);
});

test("quotaConsumptionSelection keeps a flat zero-quota range summary", () => {
  const data = prepareRecentChartData("24h", {
    recentUsage24h: [
      point(0, { inputTokens: 100_000, outputTokens: 20_000, tokens: 120_000, calls: 1, fiveHourRemainingPercent: 0, sevenDayRemainingPercent: 0 }),
      point(300, { inputTokens: 100_000, outputTokens: 20_000, tokens: 120_000, calls: 1, fiveHourRemainingPercent: 0, sevenDayRemainingPercent: 0 }),
    ],
    recentUsage7d: [],
    recentUsage30d: [],
  });

  const selection = quotaConsumptionSelection(data, 0, 1, "gpt55");

  assert.ok(selection);
  assert.equal(selection.bucketCount, 2);
  assert.equal(selection.endUnix - selection.startUnix, 600);
  assert.equal(selection.fiveHour.quotaDropPercent, 0);
  assert.equal(selection.sevenDay.quotaDropPercent, 0);
  assert.equal(selection.fiveHour.confidence, "insufficientQuotaMovement");
  assert.equal(selection.sevenDay.confidence, "insufficientQuotaMovement");
  assert.equal(quotaSelectionDurationText(selection), "持续 10分钟");
});

test("quotaConsumptionSelection estimates quota from the fallback -> quota -> precise chain", async () => {
  return withSsrModules(async (load) => {
    const { mergePreciseDashboard, mergeQuota } = await load("/src/state/dashboardMergers.ts");
    const { emptyRecentUsage } = await load("/src/api/fallback/timeSeriesFallback.ts");
    const fallbackPoints = emptyRecentUsage(new Date("2026-07-01T00:02:00Z"));
    const oldWindowStart = 12 * 24 * 12;
    const precisePoints = fallbackPoints.map((fallbackPoint, index) =>
      point(fallbackPoint.startUnix, {
        inputTokens: index >= oldWindowStart && index <= oldWindowStart + 2 ? 100_000 : 0,
        tokens: index >= oldWindowStart && index <= oldWindowStart + 2 ? 100_000 : 0,
        calls: index >= oldWindowStart && index <= oldWindowStart + 2 ? 1 : 0,
      }),
    );
    const fallbackDashboard = dashboardStateWithRecentUsage(fallbackPoints);
    const quotaHistory = [
      [oldWindowStart, 0.8],
      [oldWindowStart + 1, 0.76],
      [oldWindowStart + 2, 0.72],
    ].map(([index, remaining]) => ({
      label: "quota",
      startUnix: fallbackPoints[index].startUnix,
      fiveHourRemainingPercent: remaining,
      sevenDayRemainingPercent: null,
    }));
    const withQuota = mergeQuota(fallbackDashboard, quotaBundleWithHistory(quotaHistory));
    const merged = mergePreciseDashboard(withQuota, dashboardSnapshotWithRecentUsage(precisePoints));
    const data = prepareRecentChartData("24h", {
      recentUsage24h: merged.dashboard.recentUsage24h,
      recentUsage7d: [],
      recentUsage30d: [],
    });

    const selection = quotaConsumptionSelection(data, oldWindowStart, oldWindowStart + 2, "gpt55");

    assert.equal(selection?.startUnix, precisePoints[oldWindowStart].startUnix);
    assert.equal(selection?.endUnix, precisePoints[oldWindowStart + 2].startUnix + 5 * 60);
    assert.equal(selection?.fiveHour.quotaDropPercent, 8);
    assert.equal(selection?.fiveHour.impliedWindowBudgetUSD?.toFixed(4), "18.7500");
  });
});

function dashboardStateWithRecentUsage(recentUsage24h) {
  return { dashboard: dashboardSnapshotWithRecentUsage(recentUsage24h) };
}

function dashboardSnapshotWithRecentUsage(recentUsage24h) {
  return {
    stats: {
      totalTokens: 0,
      peakDayTokens: 0,
      peakThreadTokens: 0,
      totalCalls: 0,
      totalThreads: 0,
    },
    account: {}, quota: {}, activityDays: [], recentUsage24h, recentUsage7d: [], recentUsage30d: [],
    warnings: [], diagnostics: [],
  };
}

function quotaBundleWithHistory(quotaHistory24h) {
  return {
    account: {}, quota: {}, quotaHistoryDaily: [], quotaHistory24h, quotaHistory7d: [], quotaHistory30d: [],
    warnings: [], diagnostics: [],
  };
}

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
  const layout = recentChartScrollLayout("24h", LONG_RECENT_POINT_COUNT, 5 * 60, 980);

  assert.equal(layout.isHorizontal, true);
  assert.equal(layout.viewportWidth, 980);
  assert.equal(layout.windowCount, 30);
  assert.equal(layout.contentWidth > 20_000, true);
  assert.equal(layout.latestScrollLeft, layout.contentWidth - layout.viewportWidth);
  assert.equal(recentChartScrollLayout("24h", 289, 5 * 60, 980).contentWidth, 980);
  assert.equal(recentChartScrollLayout("7d", 7 * 24 + 1, 60 * 60, 980).isHorizontal, false);
  assert.equal(recentChartScrollLayout("30d", 30 * 4 + 1, 6 * 60 * 60, 980).isHorizontal, false);
});

test("24h/7d/30d page navigation has real offsets and disabled boundaries", () => {
  const cases = [
    ["24h", LONG_RECENT_POINT_COUNT, 5 * 60],
    ["7d", 8 * 24 + 1, 60 * 60],
    ["30d", 31 * 4 + 1, 6 * 60 * 60],
  ];
  for (const [range, pointCount, bucketSeconds] of cases) {
    const layout = recentChartScrollLayout(range, pointCount, bucketSeconds, 980);
    assert.equal(layout.isHorizontal, true, range);
    assert.ok(layout.windowCount >= 2, range);
    const oldest = recentChartScrollPresentation(layout, 0);
    const latest = recentChartScrollPresentation(layout, layout.latestScrollLeft);
    assert.equal(oldest.isAtOldest, true, range);
    assert.equal(oldest.isAtLatest, false, range);
    assert.equal(latest.isAtOldest, false, range);
    assert.equal(latest.isAtLatest, true, range);
    assert.equal(recentChartScrollTarget(layout, 0, "backward"), 0, range);
    assert.ok(recentChartScrollTarget(layout, 0, "forward") > 0, range);
    assert.equal(recentChartScrollTarget(layout, layout.latestScrollLeft, "forward"), layout.latestScrollLeft, range);
  }
});

test("24h long chart time markers show one local date label per day", () => {
  const startUnix = localUnix(2026, 6, 1);
  const points = Array.from({ length: LONG_RECENT_POINT_COUNT }, (_, index) => point(startUnix + index * 5 * 60));
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
  const points = Array.from({ length: LONG_RECENT_POINT_COUNT }, (_, index) => point(startUnix + index * 5 * 60));
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
  const points = Array.from({ length: LONG_RECENT_POINT_COUNT }, (_, index) => point(startUnix + index * 5 * 60));
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
  const points = Array.from({ length: LONG_RECENT_POINT_COUNT }, (_, index) => point(startUnix + index * 5 * 60));
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

test("headline totals use the selected window instead of the retained history canvas", () => {
  const recent24hPoints = Array.from({ length: LONG_RECENT_POINT_COUNT }, (_, index) => point(index * 300, {
    tokens: index + 1,
    calls: 1,
    inputTokens: 100,
    cachedInputTokens: 25,
    cacheHitRate: 0.25,
    fiveHourRemainingPercent: index / LONG_RECENT_POINT_COUNT,
    sevenDayRemainingPercent: 0.5,
  }));
  const fourteenDayHourlyPoints = Array.from({ length: 14 * 24 }, (_, index) => point(index * 3600, {
    tokens: 1_000 + index,
    calls: 2,
    inputTokens: 200,
    cachedInputTokens: 100,
    cacheHitRate: 0.5,
    sevenDayRemainingPercent: index / (14 * 24),
  }));
  const sixtyDaySixHourPoints = Array.from({ length: 60 * 4 }, (_, index) => point(index * 6 * 3600, {
    tokens: 10_000 + index,
    calls: 3,
    inputTokens: 300,
    cachedInputTokens: 75,
    cacheHitRate: 0.25,
  }));

  const data24h = prepareRecentChartData("24h", {
    recentUsage24h: recent24hPoints,
    recentUsage7d: [],
    recentUsage30d: [],
  });
  const layout24h = recentChartScrollLayout("24h", data24h.points.length, data24h.bucketSeconds, 980);
  const summary24h = recentChartVisibleWindowSummary(
    data24h,
    layout24h.contentWidth,
    layout24h.latestScrollLeft,
    layout24h.viewportWidth,
  );
  assert.deepEqual(recentChartVisibleWindowIndices(
    data24h,
    layout24h.contentWidth,
    layout24h.latestScrollLeft,
    layout24h.viewportWidth,
  ), { startIndex: LONG_RECENT_POINT_COUNT - 288, endIndex: LONG_RECENT_POINT_COUNT - 1 });
  assert.equal(summary24h.tokenTotal, recent24hPoints.slice(-288).reduce((total, value) => total + value.tokens, 0));
  assert.equal(summary24h.callTotal, 288);
  assert.equal(summary24h.cacheHitRate, 0.25);
  assert.equal(summary24h.latestFiveHourRemaining, recent24hPoints.at(-1).fiveHourRemainingPercent);
  const middleSummary24h = recentChartVisibleWindowSummary(
    data24h,
    layout24h.contentWidth,
    10 * layout24h.viewportWidth,
    layout24h.viewportWidth,
  );
  assert.equal(middleSummary24h.endIndex - middleSummary24h.startIndex + 1, 288);
  assert.ok(middleSummary24h.endIndex < summary24h.startIndex);

  const data7d = prepareRecentChartData("7d", {
    recentUsage24h: [],
    recentUsage7d: fourteenDayHourlyPoints,
    recentUsage30d: [],
  });
  const layout7d = recentChartScrollLayout("7d", data7d.points.length, data7d.bucketSeconds, 980);
  const summary7d = recentChartVisibleWindowSummary(data7d, layout7d.contentWidth, layout7d.latestScrollLeft, layout7d.viewportWidth);
  assert.equal(summary7d.startIndex, fourteenDayHourlyPoints.length - 168);
  assert.equal(summary7d.endIndex, fourteenDayHourlyPoints.length - 1);
  assert.equal(summary7d.tokenTotal, fourteenDayHourlyPoints.slice(-168).reduce((total, value) => total + value.tokens, 0));
  assert.equal(summary7d.callTotal, 168 * 2);

  const data30d = prepareRecentChartData("30d", {
    recentUsage24h: [],
    recentUsage7d: [],
    recentUsage30d: sixtyDaySixHourPoints,
  });
  const layout30d = recentChartScrollLayout("30d", data30d.points.length, data30d.bucketSeconds, 980);
  const summary30d = recentChartVisibleWindowSummary(data30d, layout30d.contentWidth, layout30d.latestScrollLeft, layout30d.viewportWidth);
  assert.equal(summary30d.startIndex, sixtyDaySixHourPoints.length - 120);
  assert.equal(summary30d.endIndex, sixtyDaySixHourPoints.length - 1);
  assert.equal(summary30d.tokenTotal, sixtyDaySixHourPoints.slice(-120).reduce((total, value) => total + value.tokens, 0));
  assert.equal(summary30d.callTotal, 120 * 3);
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
  assert.match(css, /\.usage-chart\s*{[^}]*aspect-ratio:\s*var\(--recent-chart-aspect-ratio,\s*980 \/ 278\)/s);
  assert.match(css, /\.chart-day-separator\s*{[^}]*stroke:/s);
  assert.match(css, /\.recent-chart-visible-window\s*{[^}]*position:\s*absolute/s);
  assert.match(css, /\.recent-chart-page-button\s*{[^}]*pointer-events:\s*auto/s);
  assert.match(css, /\.recent-chart-page-button\s*{[^}]*width:\s*30px/s);
  assert.equal(source.includes("recentChartScrollLayout(data.range, data.points.length, data.bucketSeconds, chartViewportWidth)"), true);
  assert.equal(source.includes("recentChartScrollTarget(scrollLayout, scrollElement.scrollLeft, direction)"), true);
  assert.equal(source.includes("className=\"recent-chart-page-controls\""), true);
  assert.equal(source.includes("aria-label=\"向前翻页\""), true);
  assert.equal(source.includes("aria-label=\"向后翻页\""), true);
  assert.equal(source.includes("recentChartTimeMarkers(data, chartWidth)"), true);
  assert.equal(source.includes("recentChartVisibleWindowLabel(data, chartWidth, chartScrollLeft, chartViewportWidth)"), true);
  assert.equal(source.includes("\"--recent-chart-aspect-ratio\": `${chartWidth} / ${canvasHeight}`"), true);
  assert.equal(source.includes("className=\"recent-chart-overlay-layer\""), true);
  assert.equal(source.indexOf("className=\"recent-chart-visible-window\"") > source.indexOf("className=\"recent-chart-overlay-layer\""), true);
  assert.equal(source.indexOf("className=\"recent-chart-visible-window\"") > source.indexOf("recent-chart-scroll-content"), true);
  assert.equal(source.includes("chart-time-marker--"), true);
  assert.equal(source.includes("chart-day-separator"), true);
  assert.equal(source.includes("x={activeTokenPoint.x - chartScrollLeft}"), true);
  assert.equal(source.includes("recentChartBucketCosts(data.points, quotaModel)"), true);
  assert.equal(source.includes("window.requestAnimationFrame"), true);
  assert.equal(source.includes("visibleWindowSummary.startIndex"), true);
  assert.equal(source.includes("visibleWindowSummary.endIndex"), true);
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

test("fixed selection keeps a dismissed preview closed while unpinned hover still reopens on a new point", () => {
  assert.equal(shouldReopenPreviewOnHoverMove(7, 2, 4), false);
  assert.equal(shouldReopenPreviewOnHoverMove(7, 4, 4), false);
  assert.equal(shouldReopenPreviewOnHoverMove(null, 2, 4), true);
  assert.equal(shouldReopenPreviewOnHoverMove(null, 4, 4), false);
});

test("RecentUsageChart exposes click-to-estimate quota UI", async () => {
  const source = await readFile(new URL("../RecentUsageChart.tsx", import.meta.url), "utf8");

  for (const expected of [
    "点击起点/终点可估算额度",
    "recentChartScrollLayout(data.range, data.points.length, data.bucketSeconds, chartViewportWidth)",
    "recent-chart-scroll-content",
    "recent-chart-overlay-layer",
    "quotaConsumptionSelection",
    "clickQuotaSelection",
    "RecentChartQuotaEstimateOverlay",
    "反推总额度",
    "SelectionSummaryBubble",
    "偏离 6x",
  ]) {
    assert.equal(source.includes(expected), true, expected);
  }
});
