import assert from "node:assert/strict";
import test from "node:test";
import {
  estimateLifetimeSavings,
  estimateRecent7dAPICost,
  inclusiveCalendarMonths,
  monthlyPlanPriceUSD,
  lifetimeBreakdownFromStats,
  savingsPresentation,
} from "./savings.ts";

function recentPoint(startUnix, overrides = {}) {
  const { model = "gpt-5.6-sol", ...breakdownOverrides } = overrides;
  const breakdown = {
    inputTokens: 1_000_000,
    cachedInputTokens: 500_000,
    outputTokens: 100_000,
    calls: 2,
    ...breakdownOverrides,
  };
  return {
    label: "point",
    startUnix,
    tokens: breakdown.inputTokens + breakdown.outputTokens,
    calls: breakdown.calls,
    inputTokens: breakdown.inputTokens,
    cachedInputTokens: breakdown.cachedInputTokens,
    outputTokens: breakdown.outputTokens,
    modelBreakdowns: [{
      model,
      eventStartUnix: startUnix,
      breakdown: { ...breakdown, totalTokens: breakdown.inputTokens + breakdown.outputTokens },
    }],
    cacheHitRate: null,
    fiveHourRemainingPercent: null,
    sevenDayRemainingPercent: null,
  };
}

test("lifetime savings subtracts monthly Pro cost from cache-aware GPT-5.6 Sol API value", () => {
  const breakdown = {
    inputTokens: 2_000_000,
    cachedInputTokens: 1_000_000,
    outputTokens: 1_000_000,
    totalTokens: 3_000_000,
  };
  const estimate = estimateLifetimeSavings({
    breakdown,
    firstUsageAt: "2026-01-01T00:00:00Z",
    planLabel: "Pro",
    priceModel: "gpt56Sol",
    now: new Date("2026-07-07T00:00:00Z"),
  });

  assert.ok(estimate);
  assert.equal(estimate.billingMonths, 7);
  assert.equal(estimate.apiEquivalentUSD, 35.5);
  assert.equal(estimate.subscriptionCostUSD, 1_400);
  assert.equal(estimate.netSavingsUSD, -1_364.5);
  assert.equal(savingsPresentation(estimate).valueText, "−$1.36k");
  assert.equal(savingsPresentation(estimate).labelText, "累计净薅到（估）");
});

test("calendar month count is inclusive and public plan mapping is conservative", () => {
  assert.equal(inclusiveCalendarMonths(new Date(2025, 10, 30), new Date(2026, 1, 1)), 4);
  assert.equal(monthlyPlanPriceUSD("Plus"), 20);
  assert.equal(monthlyPlanPriceUSD("ChatGPT Pro"), 200);
  assert.equal(monthlyPlanPriceUSD("Business"), 25);
  assert.equal(monthlyPlanPriceUSD("Free"), 0);
  assert.equal(monthlyPlanPriceUSD("Enterprise"), null);
  assert.equal(monthlyPlanPriceUSD("套餐待读取"), null);
});

test("lifetime savings uses recorded historical models before the fallback model", () => {
  const estimate = estimateLifetimeSavings({
    breakdown: { inputTokens: 2_000_000, cachedInputTokens: 0, outputTokens: 0, totalTokens: 2_000_000, calls: 2 },
    modelBreakdowns: [
      { model: "gpt-5.6-sol", breakdown: { inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0, totalTokens: 1_000_000, calls: 1 } },
      { model: "gpt-5.6-terra", breakdown: { inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0, totalTokens: 1_000_000, calls: 1 } },
    ],
    firstUsageAt: "2026-07-01T00:00:00Z",
    planLabel: "Enterprise",
    priceModel: "gpt56Luna",
    now: new Date("2026-07-07T00:00:00Z"),
  });

  assert.equal(estimate?.apiEquivalentUSD, 7);
  assert.match(savingsPresentation(estimate).helpText, /历史真实模型/);
});

test("lifetime breakdown comes from full aggregate stats and clamps malformed cached input", () => {
  const combined = lifetimeBreakdownFromStats({
    totalTokens: 165,
    totalInputTokens: 150,
    totalCachedInputTokens: 250,
    totalOutputTokens: 15,
    peakDayTokens: 100,
    peakThreadTokens: 80,
    currentStreakDays: 1,
    longestStreakDays: 1,
    totalCalls: 2,
    totalThreads: 2,
  });

  assert.deepEqual(combined, { inputTokens: 150, cachedInputTokens: 150, outputTokens: 15, totalTokens: 165, calls: 2 });
});

test("unknown plan shows API equivalent instead of inventing subscription cost", () => {
  const estimate = estimateLifetimeSavings({
    breakdown: { inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0, totalTokens: 1_000_000 },
    firstUsageAt: "2026-07-01T00:00:00Z",
    planLabel: "Enterprise",
    priceModel: "gpt56Terra",
    now: new Date("2026-07-07T00:00:00Z"),
  });
  const presentation = savingsPresentation(estimate);

  assert.equal(presentation.valueText, "$2.00");
  assert.equal(presentation.labelText, "API 等值（估）");
  assert.match(presentation.helpText, /暂不计算净节省/);
});

test("lifetime savings excludes Spark while preserving its model calls", () => {
  const estimate = estimateLifetimeSavings({
    breakdown: { inputTokens: 2_000_000, cachedInputTokens: 0, outputTokens: 0, totalTokens: 2_000_000, calls: 2 },
    modelBreakdowns: [
      { model: "gpt-5.3-codex-spark", breakdown: { inputTokens: 2_000_000, cachedInputTokens: 0, outputTokens: 0, totalTokens: 2_000_000, calls: 2 } },
    ],
    firstUsageAt: "2026-07-01T00:00:00Z",
    planLabel: "Enterprise",
    priceModel: "gpt56Sol",
    now: new Date("2026-07-07T00:00:00Z"),
  });

  assert.equal(estimate?.apiEquivalentUSD, 0);
  assert.deepEqual(estimate?.detectedModels, []);
  assert.equal(estimate?.fallbackModelCalls, 0);
  assert.deepEqual(estimate?.excludedModels, ["gpt-5.3-codex-spark"]);
  assert.equal(estimate?.excludedCalls, 2);
  const helpText = savingsPresentation(estimate).helpText;
  assert.match(helpText, /独立额度/);
  assert.doesNotMatch(helpText, /缺少逐模型历史/);
  assert.doesNotMatch(helpText, /未知模型回退/);
});

test("7d API estimate uses the reset boundary and excludes adjacent points", () => {
  const resetAtUnix = 1_800_000_000;
  const periodStartUnix = resetAtUnix - 7 * 24 * 60 * 60;
  const estimate = estimateRecent7dAPICost({
    resetAtUnix,
    priceModel: "gpt56Luna",
    points: [
      recentPoint(periodStartUnix - 1),
      recentPoint(periodStartUnix),
      recentPoint(resetAtUnix - 1),
      recentPoint(resetAtUnix),
    ],
  });

  assert.ok(estimate);
  assert.equal(estimate.periodStartUnix, periodStartUnix);
  assert.equal(estimate.pointCount, 2);
  assert.equal(estimate.apiEquivalentUSD, 11.5);
  assert.equal(estimate.modelBreakdowns.length, 2);
});

test("7d API estimate applies the auto-review timestamp rule per five-minute point", () => {
  const resetAtUnix = Date.parse("2026-08-01T00:00:00Z") / 1000;
  const estimate = estimateRecent7dAPICost({
    resetAtUnix,
    priceModel: "gpt56Sol",
    points: [
      recentPoint(Date.parse("2026-07-29T23:55:00Z") / 1000, { model: "codex-auto-review" }),
      recentPoint(Date.parse("2026-07-30T00:05:00Z") / 1000, { model: "codex-auto-review" }),
    ],
  });

  assert.ok(estimate);
  assert.equal(estimate.apiEquivalentUSD, 3.105);
  assert.deepEqual(estimate.detectedModels, ["gpt56Luna", "gpt54Legacy"]);
  assert.deepEqual(estimate.modelBreakdowns.map((row) => row.eventStartUnix), [
    Date.parse("2026-07-29T23:55:00Z") / 1000,
    Date.parse("2026-07-30T00:05:00Z") / 1000,
  ]);
});

test("7d model scope stays pending when reset or model coverage is missing", () => {
  const missingReset = estimateRecent7dAPICost({
    points: [recentPoint(1_800_000_000)],
    resetAtUnix: null,
    priceModel: "gpt56Sol",
  });
  const noData = estimateRecent7dAPICost({
    points: [],
    resetAtUnix: 1_800_000_000,
    priceModel: "gpt56Sol",
  });

  assert.equal(missingReset, null);
  assert.equal(noData, null);
});

test("7d API estimate keeps a five-minute numeric fallback while model attribution loads", () => {
  const resetAtUnix = 1_800_000_000;
  const point = recentPoint(resetAtUnix - 5 * 60);
  delete point.modelBreakdowns;

  const estimate = estimateRecent7dAPICost({
    points: [point],
    resetAtUnix,
    priceModel: "gpt56Terra",
  });

  assert.ok(estimate);
  assert.equal(estimate.quality, "estimated");
  assert.equal(estimate.estimateSource, "5分钟桶用量缓存");
  assert.equal(estimate.modelBreakdowns.length, 1);
  assert.equal(estimate.modelBreakdowns[0].model, null);
  assert.equal(estimate.apiEquivalentUSD, 2.3);
});
