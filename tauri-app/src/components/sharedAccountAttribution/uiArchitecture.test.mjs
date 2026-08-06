import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  prepareRecentChartData,
  quotaConsumptionSelection,
  quotaSelectionAttribution,
} from "../recentUsageChart/model.ts";

const SEVEN_DAY_SECONDS = 7 * 24 * 60 * 60;

function attributionPoint(startUnix, remainingPercent) {
  const inputTokens = 1_000_000;
  return {
    label: "00:00",
    startUnix,
    tokens: inputTokens,
    calls: 1,
    inputTokens,
    cachedInputTokens: 0,
    outputTokens: 0,
    cacheHitRate: 0,
    fiveHourRemainingPercent: null,
    sevenDayRemainingPercent: remainingPercent,
    modelBreakdowns: [{
      model: "gpt-5.6-terra",
      breakdown: {
        inputTokens,
        cachedInputTokens: 0,
        outputTokens: 0,
        totalTokens: inputTokens,
        calls: 1,
      },
    }],
  };
}

function attributionContext(quotaUpdatedAtUnix, overrides = {}) {
  return {
    status: "indistinguishable",
    priceBasis: "radar20260730",
    radarPlanTotalUSD: 100,
    quotaDataStale: false,
    radarDataStale: false,
    usagePendingQuotaRefresh: false,
    historyChangedLowConfidence: false,
    cycleStartUnix: 0,
    cycleEndUnix: SEVEN_DAY_SECONDS,
    segmentStartUnix: 0,
    quotaUpdatedAtUnix,
    ...overrides,
  };
}

test("attribution leaves the top quota strip and fixed selections feed the lower card", async () => {
  const [quotaStrip, chart, page] = await Promise.all([
    readFile(new URL("../QuotaStrip.tsx", import.meta.url), "utf8"),
    readFile(new URL("../RecentUsageChart.tsx", import.meta.url), "utf8"),
    readFile(new URL("../../pages/DashboardPage.tsx", import.meta.url), "utf8"),
  ]);

  assert.doesNotMatch(quotaStrip, /className="shared-attribution-trigger"/);
  assert.match(quotaStrip, /onAttributionChange/);
  assert.match(page, /sharedAccountAttribution=\{sharedAccountAttribution\}/);
  assert.match(chart, /quotaSelectionAttribution\(consumptionSelection, sharedAccountAttribution\)/);
  assert.match(chart, /fixedSelectionEndIndex !== null/);
  assert.match(chart, /aria-label="选区共享账号归因"/);
  assert.match(chart, /账号实降/);
  assert.match(chart, /本机折算/);

  for (const [range, bucketSeconds, pointsKey] of [
    ["24h", 5 * 60, "recentUsage24h"],
    ["7d", 60 * 60, "recentUsage7d"],
    ["30d", 6 * 60 * 60, "recentUsage30d"],
  ]) {
    const points = [
      attributionPoint(0, 0.90),
      attributionPoint(bucketSeconds, 0.87),
    ];
    const data = prepareRecentChartData(range, {
      recentUsage24h: pointsKey === "recentUsage24h" ? points : [],
      recentUsage7d: pointsKey === "recentUsage7d" ? points : [],
      recentUsage30d: pointsKey === "recentUsage30d" ? points : [],
    });
    const selection = quotaConsumptionSelection(data, 0, 1, "gpt56Sol");
    assert.ok(selection, range);
    assert.equal(selection.sevenDay.comparisonStartUnix, selection.startUnix, range);
    assert.equal(
      selection.sevenDay.comparisonBreakdown.inputTokens,
      selection.sevenDayModelBreakdowns.reduce((total, row) => total + row.breakdown.inputTokens, 0),
      range,
    );

    const allowed = quotaSelectionAttribution(
      selection,
      attributionContext(selection.endUnix),
    );
    assert.equal(allowed?.state, "withinTolerance", range);
    assert.equal(allowed?.allowsAttributionConclusion, true, range);

    const incomplete = quotaSelectionAttribution(
      selection,
      attributionContext(selection.endUnix - bucketSeconds),
    );
    assert.equal(incomplete?.state, "provisional", `${range} coverage`);
    assert.equal(incomplete?.allowsAttributionConclusion, false, `${range} coverage`);

    const resetPoints = [
      attributionPoint(0, 0.90),
      attributionPoint(bucketSeconds, 0.87),
      attributionPoint(2 * bucketSeconds, 1.00),
      attributionPoint(3 * bucketSeconds, 0.90),
    ];
    const resetData = prepareRecentChartData(range, {
      recentUsage24h: pointsKey === "recentUsage24h" ? resetPoints : [],
      recentUsage7d: pointsKey === "recentUsage7d" ? resetPoints : [],
      recentUsage30d: pointsKey === "recentUsage30d" ? resetPoints : [],
    });
    const resetSelection = quotaConsumptionSelection(resetData, 0, 3, "gpt56Sol");
    const crossReset = quotaSelectionAttribution(
      resetSelection,
      attributionContext(resetSelection.endUnix),
    );
    assert.notEqual(resetSelection.sevenDay.comparisonStartUnix, resetSelection.startUnix, range);
    assert.equal(crossReset?.state, "provisional", `${range} reset`);
    assert.equal(crossReset?.allowsAttributionConclusion, false, `${range} reset`);
  }
});

test("monitoring settings own the default-on attribution, tier and shared price-model controls", async () => {
  const [dialog, settings] = await Promise.all([
    readFile(new URL("../settings/AppSettingsDialog.tsx", import.meta.url), "utf8"),
    readFile(new URL("../../settings/sharedAccountAttribution.ts", import.meta.url), "utf8"),
  ]);

  assert.match(dialog, /共享账号归因/);
  assert.match(dialog, /共享账号归因雷达套餐/);
  assert.match(dialog, /共享账号归因价格模型/);
  assert.match(settings, /enabled: true/);
  assert.match(settings, /radarTier: "pro20x"/);
});

test("Radar attribution only subscribes to the existing shared client and precise readiness is explicit", async () => {
  const [hook, summary, dashboardData] = await Promise.all([
    readFile(new URL("../../api/useSubscribedCodexRadarSnapshot.ts", import.meta.url), "utf8"),
    readFile(new URL("../../pages/dashboard/DashboardSummarySection.tsx", import.meta.url), "utf8"),
    readFile(new URL("../../state/useDashboardData.ts", import.meta.url), "utf8"),
  ]);

  assert.match(hook, /subscribeCodexRadarState/);
  assert.doesNotMatch(hook, /readCodexRadarState|fetch\(/);
  assert.match(summary, /dashboard\.preciseRecentUsageCoveredAt/);
  assert.match(summary, /dashboard\.preciseRecentUsageFresh === true/);
  assert.doesNotMatch(summary, /usagePrecisionWarnings/);
  assert.match(summary, /dashboard\.attributionIdentity/);
  assert.match(summary, /dashboard\.quotaUpdatedAt/);
  assert.match(dashboardData, /advanceQuotaComparisonObservation/);
  assert.match(dashboardData, /comparison\.shouldRefreshPreciseUsage/);
  assert.doesNotMatch(dashboardData, /quotaTimestampChanged/);
});

test("disabled attribution gates segment, bucket key, storage read and write paths", async () => {
  const source = await readFile(new URL("../QuotaStrip.tsx", import.meta.url), "utf8");
  assert.match(source, /enabled: attributionSettings\.enabled/);
  assert.match(source, /if \(!attributionSettings\.enabled[\s\S]+return null;/);
  assert.match(source, /if \(!attributionSettings\.enabled[\s\S]+return emptyBucketMergeResult\(\);/);
  assert.match(source, /if \(!attributionSettings\.enabled[\s\S]+writeAttributionHighWater/);
  assert.match(source, /if \(!attributionSettings\.enabled[\s\S]+writeAttributionSegment/);
});

test("negative residual uses warning amber rather than failure red", async () => {
  const styles = await readFile(new URL("../../styles/global.css", import.meta.url), "utf8");
  const rule = styles.match(/\.shared-attribution-status--negativeResidual\s*\{[^}]+\}/s)?.[0] ?? "";
  assert.match(rule, /#df8020/);
  assert.doesNotMatch(rule, /#d24c58/);
});
