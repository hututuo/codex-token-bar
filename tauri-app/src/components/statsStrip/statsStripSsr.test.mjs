import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { withSsrModules } from "../../test/ssrHarness.mjs";

test("StatsStrip renders six historical metrics with an explainable savings estimate", async () => {
  await withSsrModules(async (load) => {
    const { StatsStrip } = await load("/src/components/StatsStrip.tsx");
    const html = renderToStaticMarkup(React.createElement(StatsStrip, {
      stats: {
        totalTokens: 3_000_000,
        peakDayTokens: 1_000_000,
        peakThreadTokens: 2_000_000,
        currentStreakDays: 3,
        longestStreakDays: 8,
        totalCalls: 10,
        totalThreads: 2,
        totalInputTokens: 2_000_000,
        totalCachedInputTokens: 1_000_000,
        totalOutputTokens: 1_000_000,
        firstUsageAt: "2026-07-01T00:00:00Z",
      },
      todayTokens: 1_100_000,
      todayModelBreakdowns: [{
        model: "gpt-5.6-sol",
        breakdown: {
          inputTokens: 1_000_000,
          cachedInputTokens: 500_000,
          outputTokens: 100_000,
          totalTokens: 1_100_000,
          calls: 2,
        },
      }],
      planLabel: "Pro",
      warnings: [],
    }));

    assert.equal((html.match(/class="stats-cell/g) ?? []).length, 6);
    assert.match(html, /累计 Token 数/);
    assert.match(html, /累计薅到（估）/);
    assert.match(html, /API 等值/);
    assert.match(html, /PRO/);
    assert.match(html, /历史套餐或模型变化未计入/);
    assert.match(html, /各模型 API 等值费用/);
    assert.match(html, /Sol/);
    assert.match(html, /Terra/);
    assert.match(html, /Luna/);
    assert.match(html, /主力/);
    assert.equal((html.match(/stats-model-cost-primary-card/g) ?? []).length, 3);
    assert.match(html, /\$5\.75/);
    assert.match(html, /合计/);
  });
});

test("StatsStrip keeps model costs pending while precise usage is unavailable", async () => {
  await withSsrModules(async (load) => {
    const { StatsStrip } = await load("/src/components/StatsStrip.tsx");
    const html = renderToStaticMarkup(React.createElement(StatsStrip, {
      stats: {
        totalTokens: 0,
        peakDayTokens: 0,
        peakThreadTokens: 0,
        currentStreakDays: 0,
        longestStreakDays: 0,
        totalCalls: 0,
        totalThreads: 0,
        totalInputTokens: 0,
        totalCachedInputTokens: 0,
        totalOutputTokens: 0,
        firstUsageAt: null,
      },
      todayTokens: 0,
      todayModelBreakdowns: [],
      preciseDataFresh: false,
      planLabel: "Pro",
      warnings: [{ source: "usage_precision", message: "精确统计准备中" }],
    }));

    assert.match(html, /模型费用待读取/);
    assert.doesNotMatch(html, /今日暂无模型用量/);
  });
});

test("StatsStrip does not treat the initial warning-free placeholder as real zero usage", async () => {
  await withSsrModules(async (load) => {
    const { StatsStrip } = await load("/src/components/StatsStrip.tsx");
    const html = renderToStaticMarkup(React.createElement(StatsStrip, {
      stats: {
        totalTokens: 0,
        peakDayTokens: 0,
        peakThreadTokens: 0,
        currentStreakDays: 0,
        longestStreakDays: 0,
        totalCalls: 0,
        totalThreads: 0,
      },
      todayTokens: 0,
      todayModelBreakdowns: [],
      preciseDataFresh: false,
      planLabel: "计划待读取",
      warnings: [],
    }));

    assert.match(html, /模型费用待读取/);
    assert.doesNotMatch(html, /今日暂无模型用量/);
  });
});
