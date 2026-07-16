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
      planLabel: "Pro",
      warnings: [],
    }));

    assert.equal((html.match(/class="stats-cell/g) ?? []).length, 6);
    assert.match(html, /累计 Token 数/);
    assert.match(html, /累计薅到（估）/);
    assert.match(html, /API 等值/);
    assert.match(html, /PRO/);
    assert.match(html, /历史套餐或模型变化未计入/);
  });
});
