import test from "node:test";
import assert from "node:assert/strict";
import {
  dashboardPrimaryModelUsageItems,
  dashboardSecondaryModelUsageItems,
  floatingModelUsageAccessibilityText,
  floatingModelUsageOverflowText,
  floatingModelUsagePageCount,
  floatingModelUsagePageItems,
  floatingModelUsagePageSizes,
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

test("Spark stays visible in share and shows its reference price in cost", () => {
  const items = floatingTodayModelUsageItems([
    row("gpt-5.3-codex-spark", 800, 0, 200, 1_000, 1),
    row("codex-auto-review", 800, 0, 200, 1_000, 1),
  ], "gpt56Sol");
  assert.deepEqual(items.map((item) => item.label), ["Luna", "Spark"]);
  const spark = items.find((item) => item.label === "Spark");
  assert.ok(spark);
  assert.equal(floatingModelUsageValue(spark, "cost"), "$0.00（不计入总计）");
  assert.equal(spark.referenceCostUSD, 0.0042);
  assert.equal(floatingModelUsageValue({ ...spark, share: 0.0010916 }, "share"), "0.1%");
  assert.match(floatingModelUsageAccessibilityText("cost", [
    row("gpt-5.3-codex-spark", 800, 0, 200, 1_000, 1),
  ], "gpt56Sol"), /Spark \$0\.00（不计入总计）/);
});

test("today model usage keeps a default trio and shares one cost order", () => {
  const rows = [
    row("gpt-5.6-luna", 2_000_000, 0, 0, 2_000_000, 1),
    row("gpt-5.6-sol", 1_000_000, 0, 1_000_000, 2_000_000, 1),
  ];
  const items = floatingTodayModelUsageItems(rows, "gpt56Sol", { showPlaceholders: true });

  assert.deepEqual(items.map(({ label, tokens }) => ({ label, tokens })), [
    { label: "Sol", tokens: 2_000_000 },
    { label: "Luna", tokens: 2_000_000 },
    { label: "Terra", tokens: 0 },
  ]);
  assert.deepEqual(items.map((item) => Math.round(item.share * 100)), [50, 50, 0]);
  assert.deepEqual(
    floatingTodayModelUsageItems(rows, "gpt56Sol", { showPlaceholders: true }).map((item) => item.key),
    items.map((item) => item.key),
  );
});

test("one used model receives only enough zero placeholders to reach three", () => {
  const items = floatingTodayModelUsageItems([
    row("gpt-5.4", 1_000, 0, 0, 1_000, 1),
  ], "gpt56Sol", { showPlaceholders: true });

  assert.deepEqual(items.map((item) => item.label), ["5.4", "Sol", "Terra"]);
  assert.equal(items.length, 3);
});

test("cold-start empty model rows remain pending until a trusted summary exists", () => {
  assert.deepEqual(floatingTodayModelUsageItems([], "gpt56Sol"), []);
  assert.equal(
    floatingTodayModelUsageItems([], "gpt56Sol", { showPlaceholders: true }).length,
    3,
  );
});

test("model usage overflow explains every hidden model", () => {
  const items = floatingTodayModelUsageItems([
    row("gpt-5.6-sol", 1_000_000, 0, 0, 1_000_000, 1),
    row("gpt-5.6-luna", 500_000, 0, 0, 500_000, 1),
    row("gpt-5.6-terra", 400_000, 0, 0, 400_000, 1),
    row("codex-auto-review", 300_000, 0, 0, 300_000, 1),
    row("gpt-5.5", 1, 0, 0, 1, 1),
    row("gpt-5.4", 0, 0, 0, 0, 0),
  ], "gpt56Sol", { showPlaceholders: true });

  assert.equal(items.length, 5);
  assert.equal(
    floatingModelUsageOverflowText(items),
    "更多模型\n5.4 · 0 tokens · 占比 0% · $0.00",
  );
  assert.equal(floatingModelUsageOverflowText(items.slice(0, 4)), null);
});

test("cost model pages stay balanced while never exceeding four items", () => {
  assert.deepEqual(floatingModelUsagePageSizes(4), [4]);
  assert.deepEqual(floatingModelUsagePageSizes(5), [3, 2]);
  assert.deepEqual(floatingModelUsagePageSizes(6), [3, 3]);
  assert.deepEqual(floatingModelUsagePageSizes(7), [4, 3]);
  assert.deepEqual(floatingModelUsagePageSizes(8), [4, 4]);

  const items = floatingTodayModelUsageItems([
    row("gpt-5.6-sol", 1_000, 0, 0, 1_000, 1),
    row("gpt-5.6-terra", 900, 0, 0, 900, 1),
    row("gpt-5.6-luna", 800, 0, 0, 800, 1),
    row("gpt-5.4", 700, 0, 0, 700, 1),
    row("gpt-5.3-codex", 600, 0, 0, 600, 1),
  ], "gpt56Sol");
  assert.equal(floatingModelUsagePageCount("cost", items), 2);
  const firstPage = floatingModelUsagePageItems("cost", items, 0);
  const secondPage = floatingModelUsagePageItems("cost", items, 1);
  assert.equal(firstPage.length, 3);
  assert.equal(secondPage.length, 2);
  assert.deepEqual(
    new Set([...firstPage, ...secondPage].map((item) => item.key)),
    new Set(items.map((item) => item.key)),
  );
});

test("dashboard groups keep Sol Terra Luna expanded and wrap used secondary models", () => {
  const items = floatingTodayModelUsageItems([
    row("gpt-5.6-sol", 1_000, 0, 0, 1_000, 1),
    row("gpt-5.4", 500, 0, 0, 500, 1),
    row("gpt-5.3-codex", 250, 0, 0, 250, 1),
  ], "gpt56Sol");

  assert.deepEqual(
    dashboardPrimaryModelUsageItems(items).map((item) => item.label),
    ["Sol", "Terra", "Luna"],
  );
  assert.deepEqual(
    dashboardSecondaryModelUsageItems(items).map((item) => item.label),
    ["5.4", "5.3"],
  );
});

function row(model, inputTokens, cachedInputTokens, outputTokens, totalTokens, calls, eventStartUnix) {
  return { model, eventStartUnix, breakdown: { inputTokens, cachedInputTokens, outputTokens, totalTokens, calls } };
}
