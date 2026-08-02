import assert from "node:assert/strict";
import test from "node:test";
import {
  modelAwareAPICostUSD,
  normalizeOfficialAPIPriceModel,
  officialAPICostUSD,
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
});

test("Radar 2026-07-30 price basis stays separate from current official API value", () => {
  assert.equal(officialAPICostUSD(1_000_000, 0, 0, "gpt56Terra", "radar20260730"), 2.5);
  assert.equal(officialAPICostUSD(1_000_000, 0, 0, "gpt56Terra", "current"), 2);
  assert.equal(officialAPICostUSD(1_000_000, 0, 0, "gpt56Luna", "radar20260730"), 0.75);
  assert.equal(officialAPICostUSD(1_000_000, 0, 0, "gpt56Luna", "current"), 0.2);
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
