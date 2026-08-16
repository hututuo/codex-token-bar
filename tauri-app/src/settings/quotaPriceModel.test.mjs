import assert from "node:assert/strict";
import test from "node:test";
import {
  CODEX_AUTO_REVIEW_PRICING_RULES,
  detectedOfficialAPIPriceModel,
  effectiveModelForAlias,
  independentQuotaModelName,
  modelAwareAPICostUSD,
  normalizeOfficialAPIPriceModel,
  officialAPICostUSD,
  independentQuotaReferenceCostUSD,
  officialAPIPrices,
  readStoredQuotaPriceModel,
} from "./quotaPriceModel.ts";

test("historical model rows are priced automatically and unknown rows use only the fallback", () => {
  const estimate = modelAwareAPICostUSD([
    { model: "gpt-5.6-sol", breakdown: { inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0, calls: 2 } },
    { model: "gpt-5.6-terra", breakdown: { inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0, calls: 3 } },
    { model: "future-model", breakdown: { inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0, calls: 4 } },
  ], { inputTokens: 3_000_000, cachedInputTokens: 0, outputTokens: 0, calls: 9 }, "gpt56Luna");

  assert.equal(estimate.costUSD, 7.2);
  assert.deepEqual(estimate.detectedModels, ["gpt56Sol", "gpt56Terra"]);
  assert.equal(estimate.fallbackCalls, 4);
  assert.deepEqual(estimate.excludedModels, []);
  assert.equal(estimate.excludedCalls, 0);
});

test("GPT-5.6 current price cards use the official Sol, Terra and Luna rates", () => {
  assert.deepEqual(officialAPIPrices("gpt56Sol"), {
    inputUSDPerMillion: 5,
    cachedInputUSDPerMillion: 0.5,
    outputUSDPerMillion: 30,
  });
  assert.deepEqual(officialAPIPrices("gpt56Terra"), {
    inputUSDPerMillion: 2,
    cachedInputUSDPerMillion: 0.2,
    outputUSDPerMillion: 12,
  });
  assert.deepEqual(officialAPIPrices("gpt56Luna"), {
    inputUSDPerMillion: 0.2,
    cachedInputUSDPerMillion: 0.02,
    outputUSDPerMillion: 1.2,
  });
  assert.deepEqual(officialAPIPrices("gpt53Codex"), {
    inputUSDPerMillion: 1.75,
    cachedInputUSDPerMillion: 0.175,
    outputUSDPerMillion: 14,
  });
  assert.deepEqual(officialAPIPrices("gpt52Codex"), officialAPIPrices("gpt53Codex"));
  assert.equal(1 / officialAPIPrices("gpt56Luna").inputUSDPerMillion, 5);
  assert.equal(2.5 / officialAPIPrices("gpt56Terra").inputUSDPerMillion, 1.25);
});

test("Radar 2026-07-30 price basis matches the currently published GPT-5.6 standard rates", () => {
  assert.equal(officialAPICostUSD(1_000_000, 0, 0, "gpt56Terra", "radar20260730"), 2);
  assert.equal(officialAPICostUSD(1_000_000, 0, 0, "gpt56Terra", "current"), 2);
  assert.equal(officialAPICostUSD(1_000_000, 0, 0, "gpt56Luna", "radar20260730"), 0.2);
  assert.equal(officialAPICostUSD(1_000_000, 0, 0, "gpt56Luna", "current"), 0.2);
  assert.equal(officialAPICostUSD(1_000_000, 0, 0, "gpt53Codex"), 1.75);
  assert.equal(officialAPICostUSD(1_000_000, 0, 0, "gpt52Codex"), 1.75);
});

test("auto review switches from GPT-5.4 to Luna at the UTC boundary", () => {
  const before = Date.parse("2026-07-29T23:59:59Z") / 1000;
  const boundary = Date.parse("2026-07-30T00:00:00Z") / 1000;

  assert.equal(effectiveModelForAlias("codex-auto-review", before), "gpt54Legacy");
  assert.equal(effectiveModelForAlias("codex_auto_review", boundary), "gpt56Luna");
  assert.equal(detectedOfficialAPIPriceModel("codex-auto-review", before), "gpt54Legacy");
  assert.equal(detectedOfficialAPIPriceModel("codex-auto-review", boundary), "gpt56Luna");
  assert.equal(detectedOfficialAPIPriceModel("codex-auto-review"), "gpt56Luna");
  assert.deepEqual(CODEX_AUTO_REVIEW_PRICING_RULES.map((rule) => rule.revision), [
    "codex-auto-review-pre-luna",
    "codex-auto-review-luna-20260730",
  ]);
});

test("official aliases and legacy models keep their own price cards", () => {
  assert.equal(detectedOfficialAPIPriceModel("gpt-5.6"), "gpt56Sol");
  assert.equal(detectedOfficialAPIPriceModel("gpt-5.3-codex"), "gpt53Codex");
  assert.equal(detectedOfficialAPIPriceModel("gpt-5.2-codex"), "gpt52Codex");
  assert.equal(detectedOfficialAPIPriceModel("codex-auto-review"), "gpt56Luna");
  assert.equal(detectedOfficialAPIPriceModel("codex_auto_review"), "gpt56Luna");
  assert.equal(detectedOfficialAPIPriceModel("gpt-5.3-codex-spark"), null);
  assert.equal(independentQuotaModelName("gpt-5.3-codex-spark"), "gpt-5.3-codex-spark");
  assert.equal(detectedOfficialAPIPriceModel("gpt-5.4"), "gpt54Legacy");
  assert.equal(detectedOfficialAPIPriceModel("gpt-5.4-mini"), "gpt54MiniLegacy");
  assert.equal(officialAPICostUSD(1_000_000, 0, 100_000, "gpt54Legacy"), 4);
  assert.equal(officialAPICostUSD(1_000_000, 0, 100_000, "gpt54MiniLegacy"), 1.2);
});

test("Spark reference price is available without entering official quota totals", () => {
  assert.equal(independentQuotaReferenceCostUSD("gpt-5.3-codex-spark", 800, 0, 200), 0.0042);
  assert.equal(independentQuotaReferenceCostUSD("gpt-5.6-sol", 800, 0, 200), null);
});

test("incomplete or duplicate model rows fall back as one complete breakdown", () => {
  const fallback = { inputTokens: 2_000_000, cachedInputTokens: 500_000, outputTokens: 300_000, calls: 2 };
  const incomplete = modelAwareAPICostUSD([
    { model: "gpt-5.6-sol", breakdown: { inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 100_000, calls: 1 } },
  ], fallback, "gpt56Sol");
  assert.equal(incomplete.costUSD, 16.75);
  assert.deepEqual(incomplete.detectedModels, []);
  assert.equal(incomplete.fallbackCalls, 2);

  const duplicate = modelAwareAPICostUSD([
    { model: "gpt-5.6-sol", breakdown: fallback },
    { model: "gpt-5.6-sol", breakdown: fallback },
  ], fallback, "gpt56Terra");
  assert.equal(duplicate.costUSD, 6.7);
  assert.deepEqual(duplicate.detectedModels, []);
  assert.equal(duplicate.fallbackCalls, 2);
});

test("mixed model coverage prices Codex aliases, excludes Spark, and falls back only unknown rows", () => {
  const rows = [
    "gpt-5.6-sol",
    "gpt-5.6-luna",
    "gpt-5.6-terra",
    "gpt-5.3-codex",
    "gpt-5.2-codex",
    "gpt-5.3-codex-spark",
    "codex-auto-review",
  ].map((model) => ({
    model,
    breakdown: { inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0, calls: 1 },
  }));
  const estimate = modelAwareAPICostUSD(
    rows,
    { inputTokens: 7_000_000, cachedInputTokens: 0, outputTokens: 0, calls: 7 },
    "gpt56Terra",
  );

  assert.equal(estimate.costUSD, 10.9);
  assert.deepEqual(estimate.detectedModels, ["gpt56Sol", "gpt56Terra", "gpt56Luna", "gpt53Codex", "gpt52Codex"]);
  assert.equal(estimate.fallbackCalls, 0);
  assert.deepEqual(estimate.excludedModels, ["gpt-5.3-codex-spark"]);
  assert.equal(estimate.excludedCalls, 1);
});

test("mixed historical and current auto-review rows use their event timestamps", () => {
  const rows = [
    {
      model: "codex-auto-review",
      eventStartUnix: Date.parse("2026-07-29T23:59:59Z") / 1000,
      breakdown: { inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0, calls: 1 },
    },
    {
      model: "codex-auto-review",
      eventStartUnix: Date.parse("2026-07-30T00:00:00Z") / 1000,
      breakdown: { inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0, calls: 1 },
    },
  ];
  const estimate = modelAwareAPICostUSD(
    rows,
    { inputTokens: 2_000_000, cachedInputTokens: 0, outputTokens: 0, calls: 2 },
    "gpt56Sol",
  );

  assert.equal(estimate.costUSD, 2.7);
  assert.deepEqual(estimate.detectedModels, ["gpt56Luna", "gpt54Legacy"]);
});

test("Spark-only rows keep calls but produce an explicit zero API amount", () => {
  const estimate = modelAwareAPICostUSD([
    { model: "gpt-5.3-codex-spark", breakdown: { inputTokens: 2_000_000, cachedInputTokens: 1_000_000, outputTokens: 100_000, calls: 3 } },
  ], { inputTokens: 2_000_000, cachedInputTokens: 1_000_000, outputTokens: 100_000, calls: 3 }, "gpt56Sol");

  assert.equal(estimate.costUSD, 0);
  assert.deepEqual(estimate.detectedModels, []);
  assert.equal(estimate.fallbackCalls, 0);
  assert.deepEqual(estimate.excludedModels, ["gpt-5.3-codex-spark"]);
  assert.equal(estimate.excludedCalls, 3);
});

test("incomplete Spark rows never leak into the unknown fallback amount", () => {
  const estimate = modelAwareAPICostUSD([
    { model: "gpt-5.3-codex-spark", breakdown: { inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0, calls: 1 } },
  ], { inputTokens: 2_000_000, cachedInputTokens: 0, outputTokens: 0, calls: 2 }, "gpt56Sol");

  assert.equal(estimate.costUSD, 5);
  assert.equal(estimate.fallbackCalls, 1);
  assert.deepEqual(estimate.excludedModels, ["gpt-5.3-codex-spark"]);
  assert.equal(estimate.excludedCalls, 1);
});

test("legacy recentChartQuotaEstimateModel values migrate in place", () => {
  const values = new Map([["recentChartQuotaEstimateModel", "gpt54"]]);
  const storage = {
    getItem(key) { return values.get(key) ?? null; },
    setItem(key, value) { values.set(key, value); },
  };

  assert.equal(normalizeOfficialAPIPriceModel("gpt55"), "gpt56Sol");
  assert.equal(normalizeOfficialAPIPriceModel("gpt54Mini"), "gpt56Luna");
  assert.equal(readStoredQuotaPriceModel(storage), "gpt56Terra");
  assert.equal(values.get("recentChartQuotaEstimateModel"), "gpt56Terra");
});
