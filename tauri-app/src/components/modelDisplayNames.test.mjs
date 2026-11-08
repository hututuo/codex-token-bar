import test from "node:test";
import assert from "node:assert/strict";
import prices from "../../../Vendor/AgentSpeed/spec/assets/prices.json" with { type: "json" };
import { modelDisplayNames } from "../domain/modelDisplayNames.ts";
import { modelUsageLabel, modelUsageKey } from "./modelUsagePresentation.ts";
import { withSsrModules } from "../test/ssrHarness.mjs";

test("every price entry and unambiguous alias has a distinct short name", () => {
  assert.equal(prices.models.length, 199);
  assert.deepEqual(new Set(Object.keys(modelDisplayNames)), new Set(prices.models.map(model => model.id)));
  assert.equal(new Set(Object.values(modelDisplayNames)).size, prices.models.length);
  for (const model of prices.models) {
    const label = modelDisplayNames[model.id];
    assert.ok(label.length <= 32, model.id);
    for (const raw of [model.id, model.name, ...(model.aliases ?? [])].filter(raw => raw !== "gpt-5.6")) {
      assert.equal(modelUsageLabel(raw), label, raw);
    }
  }
});

test("short names retain versions, service tiers and unknown model identities", () => {
  for (const [raw, expected] of Object.entries({
    "Gemini 4 Argon (High)": "Argon4", "models/gemini-4-argon": "Argon4",
    "gemini-3.8-flash-low": "Flash3.8", "claude-mythos-5-1": "Mythos5.1",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0": "Sonnet4.5",
    "anthropic/claude-opus-5.5-fast": "Opus5.5 Fast",
    "deepseek/deepseek-v4-flash:free": "DS4.1 Flash Free",
    "k3.1-pro-highspeed": "Kimi3.1 Pro Fast", "gpt61sol": "Sol6.1",
    "gpt-6-sol": "Sol6", "gpt-5.6-sol": "Sol5.6", "gpt-4o-2024-05-13": "4o (2024-05-13)",
  })) assert.equal(modelUsageLabel(raw), expected, raw);
  for (const raw of ["gpt-5.6", "gpt5.6", "gpt56", "GPT-7-Nova", "gemini-3.1-flash", "gpt-6.1-sol-preview", "router/auto"]) {
    assert.equal(modelUsageLabel(raw), raw);
    assert.equal(modelUsageKey(raw), raw);
  }
  assert.equal(modelUsageKey("models/gemini-4-argon"), "models/gemini-4-argon");
  assert.equal(modelUsageLabel("codex-auto-review@5.4"), "Auto Review（5.4）");
});

test("multi-client cost projections shorten labels without changing keys, amounts or unpriced state", async () => {
  await withSsrModules(async load => {
    const { clientModelCostItems } = await load("/src/multiClient/originalDashboardProjection.ts");
    const source = [
      { client: "antigravity", model: "gemini-4-argon", inputTokens: 100, outputTokens: 20, requests: 1, apiCostUSD: 0.123, unpricedRequests: 0 },
      { client: "deepseek", model: "deepseek-pro", inputTokens: 100, outputTokens: 30, requests: 1, apiCostUSD: null, unpricedRequests: 1 },
    ];
    const before = structuredClone(source);
    const items = clientModelCostItems(source, [], ["antigravity", "deepseek"]);
    assert.deepEqual(items.map(item => [item.key, item.label, item.tokens, item.costUSD]), [
      ["antigravity|gemini-4-argon", "Argon4", 120, 0.123], ["deepseek|deepseek-pro", "deepseek-pro", 130, null],
    ]);
    assert.deepEqual(source, before);
  });
});
