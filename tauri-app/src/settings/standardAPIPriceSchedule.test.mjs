import assert from "node:assert/strict";
import test from "node:test";
import {
  canonicalStandardAPIModelKey,
  currentStandardAPIPriceQuote,
  standardAPIPriceQuote,
} from "./standardAPIPriceSchedule.ts";

test("GPT-6.1 Terra uses its own October 26 card without repricing old Terra", () => {
  const rates = { inputUSDPerMillion: 1, cachedInputUSDPerMillion: 0.05, outputUSDPerMillion: 5 };
  for (const alias of ["gpt-6.1-terra", "GPT_6.1_TERRA", "GPT 6.1 Terra", "gpt61-terra", "gpt61terra"]) {
    assert.equal(canonicalStandardAPIModelKey(alias), "gpt-6.1-terra");
    assert.equal(standardAPIPriceQuote(alias, "2026-10-25T23:59:59Z"), null);
    assert.deepEqual(standardAPIPriceQuote(alias, "2026-10-26T00:00:00Z").rates, rates);
    assert.deepEqual(currentStandardAPIPriceQuote(alias).rates, rates);
  }
  assert.equal(currentStandardAPIPriceQuote("gpt-6.1-terra-preview"), null);
  assert.equal(standardAPIPriceQuote("gpt-6.1-terra", null), null);
  assert.equal(currentStandardAPIPriceQuote("gpt-5.6-terra").rates.outputUSDPerMillion, 12);
});

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

test("GPT-6.1 Sol has an independent September 29 card and narrow aliases", () => {
  const expected = { inputUSDPerMillion: 2, cachedInputUSDPerMillion: 0.1, outputUSDPerMillion: 10 };
  for (const alias of ["gpt-6.1-sol", "GPT_6.1_SOL", "GPT 6.1 Sol", "gpt61sol", "gpt61-sol"]) {
    assert.equal(canonicalStandardAPIModelKey(alias), "gpt-6.1-sol");
    assert.equal(standardAPIPriceQuote(alias, "2026-09-28T23:59:59Z"), null);
    const quote = standardAPIPriceQuote(alias, "2026-09-29T00:00:00Z");
    assert.deepEqual(quote.rates, expected);
    assert.equal(quote.revision, "standard-api-gpt-6.1-sol-from-2026-09-29");
    assert.deepEqual(currentStandardAPIPriceQuote(alias).rates, expected);
  }
  assert.equal(standardAPIPriceQuote("gpt-6.1-sol", null), null);
  assert.equal(canonicalStandardAPIModelKey("gpt-6.1-sol-preview"), null);
  assert.equal(canonicalStandardAPIModelKey("gpt-6.1"), null);
  assert.equal(currentStandardAPIPriceQuote("gpt-6-sol").rates.cachedInputUSDPerMillion, 0.2);
});


test("all admitted current cards share vendor data while history is a frozen shared snapshot", async () => {
  const { readFile } = await import("node:fs/promises");
  const pinned = JSON.parse(await readFile(new URL("../../../Vendor/AgentSpeed/spec/assets/prices.json", import.meta.url), "utf8"));
  const history = JSON.parse(await readFile(new URL("../../../Sources/CodexTokenBar/Resources/standard-api-price-history.json", import.meta.url), "utf8"));
  for (const id of new Set(history.rows.map(row => row.modelKey))) {
    const base = pinned.models.find(row => row.id === id).prices;
    const expected = { inputUSDPerMillion:base.input, cachedInputUSDPerMillion:base.cachedInput, outputUSDPerMillion:base.output };
    assert.deepEqual(currentStandardAPIPriceQuote(id).rates, expected);
    assert.deepEqual(standardAPIPriceQuote(id, "2026-10-26T00:00:00Z").rates, expected);
  }
  const quote = currentStandardAPIPriceQuote("gpt-6.1-sol");
  quote.rates.inputUSDPerMillion = 999;
  assert.equal(currentStandardAPIPriceQuote("gpt-6.1-sol").rates.inputUSDPerMillion, 2);
});
