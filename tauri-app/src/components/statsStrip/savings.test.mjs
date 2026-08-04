import assert from "node:assert/strict";
import test from "node:test";
import {
  estimateLifetimeSavings,
  inclusiveCalendarMonths,
  monthlyPlanPriceUSD,
  lifetimeBreakdownFromStats,
  savingsPresentation,
} from "./savings.ts";

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
