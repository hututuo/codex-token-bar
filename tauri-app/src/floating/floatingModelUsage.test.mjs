import test from "node:test";
import assert from "node:assert/strict";
import {
  floatingModelUsageAccessibilityText,
  floatingModelUsageValue,
  floatingTodayModelUsageItems,
} from "./floatingModelUsage.ts";

test("today model usage combines aliases and computes cache-aware per-model prices", () => {
  const rows = [
    row("gpt-5.6-sol", 1_000_000, 500_000, 100_000, 1_100_000, 2),
    row("gpt_5.6_sol", 100_000, 0, 0, 100_000, 1),
    row("gpt-5.6-luna", 1_000_000, 0, 0, 1_000_000, 1),
  ];
  const items = floatingTodayModelUsageItems(rows, "gpt56Terra");
  assert.deepEqual(items.map(({ label, tokens }) => ({ label, tokens })), [
    { label: "Sol", tokens: 1_200_000 },
    { label: "Luna", tokens: 1_000_000 },
  ]);
  assert.equal(floatingModelUsageValue(items[0], "cost"), "$6.25");
  assert.equal(floatingModelUsageValue(items[1], "cost"), "$0.20");
  assert.equal(floatingModelUsageValue(items[0], "share"), "55%");
});

test("Spark stays visible in share but is labelled as independent quota in cost", () => {
  const items = floatingTodayModelUsageItems([
    row("gpt-5.3-codex-spark", 800, 0, 200, 1_000, 1),
    row("codex-auto-review", 800, 0, 200, 1_000, 1),
  ], "gpt56Sol");
  assert.deepEqual(items.map((item) => item.label), ["5.3", "Spark"]);
  const spark = items.find((item) => item.label === "Spark");
  assert.ok(spark);
  assert.equal(floatingModelUsageValue(spark, "cost"), "独立");
  assert.match(floatingModelUsageAccessibilityText("cost", [
    row("gpt-5.3-codex-spark", 800, 0, 200, 1_000, 1),
  ], "gpt56Sol"), /Spark 独立/);
});

function row(model, inputTokens, cachedInputTokens, outputTokens, totalTokens, calls) {
  return { model, breakdown: { inputTokens, cachedInputTokens, outputTokens, totalTokens, calls } };
}
