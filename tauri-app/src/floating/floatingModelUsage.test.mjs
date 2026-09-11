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
  hasUnknownModelPrices,
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
  assert.equal(floatingModelUsageValue(items[0], "cost"), "$4.60 · 均一化 $4.60");
  assert.equal(floatingModelUsageValue(items[1], "cost"), "$0.20 · 均一化 $0.40");
  assert.equal(floatingModelUsageValue(items[0], "share"), "55%");
});

test("Astra is shown and priced from the same shared model rows", () => {
  const items = floatingTodayModelUsageItems([
    row("gpt-6-astra", 1_000_000, 500_000, 100_000, 1_100_000, 1),
    row("gpt-5.6-sol", 1_000_000, 0, 0, 1_000_000, 1),
  ], "gpt56Sol");

  assert.deepEqual(items.map(({ label, tokens }) => ({ label, tokens })), [
    { label: "Astra", tokens: 1_100_000 },
    { label: "Sol", tokens: 1_000_000 },
  ]);
  assert.equal(floatingModelUsageValue(items[0], "cost"), "$10.5 · 均一化 $15.8");
});

test("Spark stays visible in share and shows its reference price in cost", () => {
  const items = floatingTodayModelUsageItems([
    row("gpt-5.3-codex-spark", 800, 0, 200, 1_000, 1),
    row("codex-auto-review", 800, 0, 200, 1_000, 1),
  ], "gpt56Sol");
  assert.deepEqual(items.map((item) => item.label), ["Luna", "Spark"]);
  const spark = items.find((item) => item.label === "Spark");
  assert.ok(spark);
  assert.equal(floatingModelUsageValue(spark, "cost"), "$0.00 · 均一化 $0.00（不计入总计）");
  assert.equal(spark.referenceCostUSD, 0.0042);
  assert.equal(floatingModelUsageValue({ ...spark, share: 0.0010916 }, "share"), "0.1%");
  assert.match(floatingModelUsageAccessibilityText("cost", [
    row("gpt-5.3-codex-spark", 800, 0, 200, 1_000, 1),
  ], "gpt56Sol"), /Spark \$0\.00 · 均一化 \$0\.00（不计入总计）/);
});

test("today model usage keeps the compact four-model set and shares one cost order", () => {
  const rows = [
    row("gpt-5.6-luna", 2_000_000, 0, 0, 2_000_000, 1),
    row("gpt-5.6-sol", 1_000_000, 0, 1_000_000, 2_000_000, 1),
  ];
  const items = floatingTodayModelUsageItems(rows, "gpt56Sol", { showPlaceholders: true });

  assert.deepEqual(items.map(({ label, tokens }) => ({ label, tokens })), [
    { label: "Sol", tokens: 2_000_000 },
    { label: "Luna", tokens: 2_000_000 },
    { label: "Astra", tokens: 0 },
    { label: "Terra", tokens: 0 },
  ]);
  assert.deepEqual(items.map((item) => Math.round(item.share * 100)), [50, 50, 0, 0]);
  assert.deepEqual(
    floatingTodayModelUsageItems(rows, "gpt56Sol", { showPlaceholders: true }).map((item) => item.key),
    items.map((item) => item.key),
  );
});

test("one used model receives only enough zero placeholders to reach four", () => {
  const items = floatingTodayModelUsageItems([
    row("gpt-5.4", 1_000, 0, 0, 1_000, 1),
  ], "gpt56Sol", { showPlaceholders: true });

  assert.deepEqual(items.map((item) => item.label), ["5.4", "Astra", "Sol", "Terra"]);
  assert.equal(items.length, 4);
});

test("cold-start empty model rows remain pending until a trusted summary exists", () => {
  assert.deepEqual(floatingTodayModelUsageItems([], "gpt56Sol"), []);
  assert.equal(
    floatingTodayModelUsageItems([], "gpt56Sol", { showPlaceholders: true }).length,
    4,
  );
});

test("used Astra Sol Terra Luna rows sort by amount with the default order as the tie-breaker", () => {
  const items = floatingTodayModelUsageItems([
    row("gpt-6-astra", 100_000, 0, 0, 100_000, 1),
    row("gpt-5.6-sol", 1_000_000, 0, 0, 1_000_000, 1),
    row("gpt-5.6-terra", 500_000, 0, 0, 500_000, 1),
    row("gpt-5.6-luna", 0, 0, 1_000_000, 1_000_000, 1),
  ], "gpt56Sol");

  assert.deepEqual(items.map((item) => item.label), ["Sol", "Luna", "Astra", "Terra"]);
  assert.deepEqual(items.map((item) => floatingModelUsageValue(item, "cost")), ["$4.00 · 均一化 $4.00", "$1.20 · 均一化 $2.40", "$1.00 · 均一化 $1.50", "$1.00 · 均一化 $1.00"]);
});

test("today model usage merges Sol aliases across the price cutover and sums both rates", () => {
  const before = Date.parse("2026-08-20T23:59:59Z") / 1000;
  const after = Date.parse("2026-08-21T00:00:00Z") / 1000;
  const items = floatingTodayModelUsageItems([
    row("gpt-5.6-sol", 1_000_000, 0, 0, 1_000_000, 1, before),
    row("gpt_5.6_sol", 1_000_000, 0, 0, 1_000_000, 1, after),
  ], "gpt56Sol");

  assert.equal(items.length, 1);
  assert.equal(items[0].label, "Sol");
  assert.equal(items[0].tokens, 2_000_000);
  assert.equal(floatingModelUsageValue(items[0], "cost"), "$9.00 · 均一化 $9.00");
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
    "更多模型\n5.4 · 0 tokens · 占比 0% · $0.00 · 均一化 $0.00",
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

test("dashboard groups keep Astra Sol Terra Luna expanded and wrap used secondary models", () => {
  const items = floatingTodayModelUsageItems([
    row("gpt-5.6-sol", 1_000, 0, 0, 1_000, 1),
    row("gpt-5.4", 500, 0, 0, 500, 1),
    row("gpt-5.3-codex", 250, 0, 0, 250, 1),
  ], "gpt56Sol");

  assert.deepEqual(
    dashboardPrimaryModelUsageItems(items).map((item) => item.label),
    ["Astra", "Sol", "Terra", "Luna"],
  );
  assert.deepEqual(
    dashboardSecondaryModelUsageItems(items).map((item) => item.label),
    ["5.4", "5.3"],
  );
});

function row(model, inputTokens, cachedInputTokens, outputTokens, totalTokens, calls, eventStartUnix) {
  return { model, eventStartUnix, breakdown: { inputTokens, cachedInputTokens, outputTokens, totalTokens, calls } };
}

test("floating merges Review but dashboard separates it without changing totals or dated prices", () => {
  const before = Date.parse("2026-07-29T12:00:00Z") / 1000;
  const after = Date.parse("2026-07-31T12:00:00Z") / 1000;
  const rows = [
    row("codex-auto-review", 1_000_000, 0, 0, 1_000_000, 1, before),
    row("gpt-5.4", 1_000_000, 0, 0, 1_000_000, 1, before),
    row("codex-auto-review", 1_000_000, 0, 0, 1_000_000, 1, after),
    row("gpt-5.6-luna", 1_000_000, 0, 0, 1_000_000, 1, after),
  ];
  const floating = floatingTodayModelUsageItems(rows, "gpt56Sol");
  const dashboard = floatingTodayModelUsageItems(rows, "gpt56Sol", { mergeAutoReview: false });
  assert.deepEqual(floating.map((item) => [item.label, item.tokens, item.costUSD]), [
    ["5.4", 2_000_000, 5], ["Luna", 2_000_000, 0.4],
  ]);
  assert.equal(dashboard.length, 4);
  assert.ok(dashboard.some((item) => item.label === "Auto Review（Luna）" && item.tokens === 1_000_000));
  assert.ok(dashboard.some((item) => item.label === "Auto Review（5.4）" && item.costUSD === 2.5));
  assert.equal(dashboard.reduce((sum, item) => sum + item.tokens, 0), 4_000_000);
  assert.ok(Math.abs(dashboard.reduce((sum, item) => sum + item.costUSD, 0) - 5.4) < 1e-10);
});

test("unpriced future models retain names and token shares without showing a zero or fallback price", () => {
  const items = floatingTodayModelUsageItems([
    row("GPT-5.6-NewLane", 1_000_000, 0, 0, 1_000_000, 1),
    row("gpt-6-astra", 1_000_000, 0, 0, 1_000_000, 1),
  ], "gpt56Sol");
  const unknown = items.find((item) => item.label === "GPT-5.6-NewLane");
  assert.ok(unknown);
  assert.equal(unknown.costUSD, null);
  assert.equal(unknown.tokens, 1_000_000);
  assert.equal(unknown.share, 0.5);
  assert.equal(floatingModelUsageValue(unknown, "cost"), "价格未知");
  assert.equal(hasUnknownModelPrices(items), true);
  assert.equal(items.reduce((sum, item) => sum + (item.costUSD ?? 0), 0), 10);
});
