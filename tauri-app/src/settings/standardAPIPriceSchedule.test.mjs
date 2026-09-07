import assert from "node:assert/strict";
import test from "node:test";
import {
  canonicalStandardAPIModelKey,
  currentStandardAPIPriceQuote,
  standardAPIPriceQuote,
} from "./standardAPIPriceSchedule.ts";

test("Sol switches at the UTC midnight boundary", () => {
  assert.deepEqual(
    standardAPIPriceQuote("gpt-5.6-sol", "2026-08-20T23:59:59Z"),
    {
      modelKey: "gpt-5.6-sol",
      rates: { inputUSDPerMillion: 5, cachedInputUSDPerMillion: 0.5, outputUSDPerMillion: 30 },
      revision: "standard-api-gpt-5.6-sol-before-2026-08-21",
    },
  );
  assert.deepEqual(
    standardAPIPriceQuote("GPT5.6_SOL", "2026-08-21T00:00:00Z"),
    {
      modelKey: "gpt-5.6-sol",
      rates: { inputUSDPerMillion: 4, cachedInputUSDPerMillion: 0.4, outputUSDPerMillion: 20 },
      revision: "standard-api-gpt-5.6-sol-from-2026-08-21",
    },
  );
});

test("Terra and Luna switch independently at the July UTC boundary", () => {
  assert.equal(standardAPIPriceQuote("gpt-5.6-terra", "2026-07-29T23:59:59Z").rates.inputUSDPerMillion, 2.5);
  assert.equal(standardAPIPriceQuote("gpt-5.6-terra", "2026-07-30T00:00:00Z").rates.inputUSDPerMillion, 2);
  assert.equal(standardAPIPriceQuote("gpt-5.6-luna", "2026-07-29T23:59:59Z").rates.inputUSDPerMillion, 1);
  assert.equal(standardAPIPriceQuote("gpt-5.6-luna", "2026-07-30T00:00:00Z").rates.inputUSDPerMillion, 0.2);
});

test("GPT-5.5 remains at its own stable card and Sol uses the new standard rate", () => {
  const before = standardAPIPriceQuote("gpt-5.5", "2026-08-20T23:59:59Z");
  const after = standardAPIPriceQuote("gpt55", "2026-08-21T00:00:00Z");
  assert.deepEqual(before?.rates, { inputUSDPerMillion: 5, cachedInputUSDPerMillion: 0.5, outputUSDPerMillion: 30 });
  assert.deepEqual(after?.rates, before?.rates);
  assert.equal(currentStandardAPIPriceQuote("gpt-5.6-sol").rates.inputUSDPerMillion, 4);
  assert.equal(currentStandardAPIPriceQuote("gpt-5.5").rates.inputUSDPerMillion, 5);
});

test("No date is not silently treated as current, and promotions are not applied", () => {
  assert.equal(standardAPIPriceQuote("gpt-5.6-sol", undefined), null);
  assert.equal(standardAPIPriceQuote("gpt-5.6-sol", null), null);
  assert.equal(standardAPIPriceQuote("gpt-5.6-sol", "not-a-date"), null);
  assert.equal(currentStandardAPIPriceQuote("gpt-5.6-sol").rates.inputUSDPerMillion, 4);
  assert.equal(standardAPIPriceQuote("gpt-5.3-codex-spark", "2026-08-21T00:00:00Z"), null);
  assert.equal(standardAPIPriceQuote("codex-auto-review", "2026-08-21T00:00:00Z"), null);
});

test("Bare GPT-5.6 aliases remain untyped until a card is explicit", () => {
  assert.equal(canonicalStandardAPIModelKey("gpt-5.6"), null);
  assert.equal(canonicalStandardAPIModelKey("gpt5.6"), null);
  assert.equal(canonicalStandardAPIModelKey("gpt56"), null);
  assert.equal(canonicalStandardAPIModelKey("gpt-5.6-sol"), "gpt-5.6-sol");
  assert.equal(standardAPIPriceQuote("gpt-5.6", "2026-08-21T00:00:00Z"), null);
});

test("Astra and existing legacy cards retain their stored standard prices", () => {
  assert.deepEqual(standardAPIPriceQuote("gpt-6-astra", "2025-01-01T00:00:00Z").rates, {
    inputUSDPerMillion: 10,
    cachedInputUSDPerMillion: 1,
    outputUSDPerMillion: 50,
  });
  assert.deepEqual(currentStandardAPIPriceQuote("gpt-5.4").rates, {
    inputUSDPerMillion: 2.5,
    cachedInputUSDPerMillion: 0.25,
    outputUSDPerMillion: 15,
  });
  assert.equal(canonicalStandardAPIModelKey(" GPT_5.6_Terra "), "gpt-5.6-terra");
});
