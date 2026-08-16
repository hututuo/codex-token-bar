import test from "node:test";
import assert from "node:assert/strict";
import { buildCalendarDays } from "./calendar.ts";
import { hoverSummary } from "./hoverSummary.ts";
import { buildHeatmapDays, modelCostCellBackground } from "./heatmap.ts";
import { summarizeRange } from "./rangeSummary.ts";
import { modelCostProjectionAvailable, modelCostRowsAvailable } from "./modelCostAvailability.ts";

test("buildCalendarDays keeps a 365-day window ending at the latest activity date", () => {
  const days = [
    {
      date: "2026-06-20",
      tokens: 120,
      calls: 2,
      cacheHitRate: 0.9,
      fiveHourRemainingPercent: null,
      sevenDayRemainingPercent: null,
    },
  ];

  const calendarDays = buildCalendarDays(days);

  assert.equal(calendarDays.length, 365);
  assert.equal(calendarDays.at(-1)?.date, "2026-06-20");
  assert.equal(calendarDays[0]?.date, "2025-06-21");
});

test("hoverSummary describes the nearby heatmap day without changing range total", () => {
  const day = {
    date: "2026-06-20",
    tokens: 123456,
    calls: 7,
    cacheHitRate: 0.92,
    fiveHourRemainingPercent: 0.81,
    sevenDayRemainingPercent: 0.64,
    modelBreakdowns: [
      {
        model: "gpt-5.6-sol",
        breakdown: { inputTokens: 90, cachedInputTokens: 0, outputTokens: 0, totalTokens: 90, calls: 1 },
      },
      {
        model: "gpt-5.6-luna",
        breakdown: { inputTokens: 10, cachedInputTokens: 0, outputTokens: 0, totalTokens: 10, calls: 1 },
      },
    ],
  };

  assert.equal(hoverSummary(day, "daily"), "2026-06-20 · 12.3万 tokens · 7 calls");
  assert.equal(hoverSummary(day, "cache"), "2026-06-20 · 命中率 92% · 7 calls");
  assert.equal(hoverSummary(day, "quota"), "2026-06-20 · 7d 64% · 5h 81%");
  assert.equal(hoverSummary(day, "model"), "2026-06-20 · 12.3万 tokens · Sol 90% · Luna 10%");
  assert.equal(
    hoverSummary(day, "modelCost", "gpt56Sol"),
    "2026-06-20 · 模型费用 $0.00 · Sol $0.00 · Luna $0.00",
  );
});

test("model cost heatmap prices cache-aware model rows and excludes Spark", () => {
  const day = {
    date: "2026-06-20",
    tokens: 1_850_000,
    calls: 3,
    cacheHitRate: 0.5,
    fiveHourRemainingPercent: null,
    sevenDayRemainingPercent: null,
    modelBreakdowns: [
      {
        model: "gpt-5.6-sol",
        breakdown: {
          inputTokens: 1_000_000,
          cachedInputTokens: 500_000,
          outputTokens: 100_000,
          totalTokens: 1_100_000,
          calls: 2,
        },
      },
      {
        model: "gpt-5.3-codex-spark",
        breakdown: {
          inputTokens: 700_000,
          cachedInputTokens: 0,
          outputTokens: 50_000,
          totalTokens: 750_000,
          calls: 1,
        },
      },
    ],
  };

  const prepared = buildHeatmapDays([day], "modelCost", "gpt56Sol");
  assert.equal(prepared[0].intensity, 1);
  assert.equal(
    hoverSummary(day, "modelCost", "gpt56Sol"),
    "2026-06-20 · 模型费用 $5.75 · Sol $5.75 · Spark $1.93（不计入总计）",
  );
  assert.match(modelCostCellBackground(day, 1, "gpt56Sol"), /linear-gradient/);

  const range = summarizeRange([day], day.date, day.date, "modelCost", "gpt56Sol");
  assert.equal(range.value, "模型费用 $5.75 · Sol $5.75 · Spark $1.93（不计入总计）");
});

test("model cost heatmap marks active days without model projection unavailable", () => {
  const day = {
    date: "2026-06-20",
    tokens: 900,
    calls: 1,
    cacheHitRate: 0,
    fiveHourRemainingPercent: null,
    sevenDayRemainingPercent: null,
  };

  assert.equal(hoverSummary(day, "modelCost", "gpt56Sol"), "2026-06-20 · 模型明细待读取");
  assert.equal(
    summarizeRange([day], day.date, day.date, "modelCost", "gpt56Sol").value,
    "所选日期模型明细待读取",
  );
});

test("model cost heatmap keeps metadata-only placeholders pending", () => {
  const day = {
    date: "2026-06-20",
    tokens: 0,
    calls: 0,
    cacheHitRate: 0,
    fiveHourRemainingPercent: null,
    sevenDayRemainingPercent: null,
    modelBreakdowns: [],
  };

  assert.equal(buildHeatmapDays([day], "modelCost", "gpt56Sol", false)[0].intensity, 0);
  assert.equal(hoverSummary(day, "modelCost", "gpt56Sol", false), "2026-06-20 · 模型明细待读取");
  assert.equal(modelCostCellBackground(day, 1, "gpt56Sol", false), "var(--heatmap-empty)");
  assert.equal(
    summarizeRange([day], day.date, day.date, "modelCost", "gpt56Sol", false).value,
    "模型费用待读取",
  );
});

test("model cost availability distinguishes an empty startup placeholder from usable cached projection", () => {
  const emptyDay = {
    date: "2026-06-20",
    tokens: 0,
    calls: 0,
    cacheHitRate: 0,
    fiveHourRemainingPercent: null,
    sevenDayRemainingPercent: null,
    modelBreakdowns: [],
  };
  const cachedDay = {
    ...emptyDay,
    tokens: 100,
    modelBreakdowns: [{
      model: "gpt-5.6-sol",
      breakdown: { inputTokens: 100, cachedInputTokens: 0, outputTokens: 0, totalTokens: 100, calls: 1 },
    }],
  };

  assert.equal(modelCostRowsAvailable([], false), false);
  assert.equal(modelCostProjectionAvailable([emptyDay], false), false);
  assert.equal(modelCostProjectionAvailable([cachedDay], false), true);
  assert.equal(modelCostProjectionAvailable([emptyDay], true), true);
});
