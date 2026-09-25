import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { Window } from "happy-dom";
import { withSsrModules } from "../test/ssrHarness.mjs";

const row = model => ({ model, breakdown: {
  inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0, totalTokens: 1_000_000, calls: 1,
} });

function data(rows) {
  const limit = { availability: "measured", remainingPercent: 0.5, resetsAt: "待读取" };
  return {
    quota: { quota: { fiveHour: limit, sevenDay: limit } },
    snapshot: {
      todayModelBreakdowns: rows, unreadSummary: { source: "local", label: "0 未读", detail: "" },
      sevenDayAvailability: "measured", sevenDayRemainingPercent: 0.5,
      todayTokensLabel: "200万", totalTokensLabel: "300万", requestsLabel: "2",
      liveRateAvailable: false, quotaDataStale: false, trendLabel: "用量趋势",
    },
    runningThreads: { total: 0, mainThreads: 0, subagents: 0, status: "ready" },
  };
}

test("sidebar retains known API subtotal and confines unknown prices to model rows", async () => {
  await withSsrModules(async load => {
    const { QuotaDetails } = await load("/src/quota-sidebar/QuotaSidebarApp.tsx");
    const window = new Window();
    try {
      for (const model of [null, "  ", "future-model"]) {
        for (const mixed of [false, true]) {
          const rows = mixed ? [row("gpt-6-astra"), row(model)] : [row(model)];
          window.document.body.innerHTML = renderToStaticMarkup(React.createElement(QuotaDetails, { data: data(rows) }));
          const metrics = window.document.querySelector(".qs-metrics");
          assert.match(metrics.textContent, /今日 API 等值 · 已知小计/);
          assert.doesNotMatch(metrics.textContent, /价格未知|价格待定/);
          if (mixed) assert.match(metrics.textContent, /\$10\.00/);
          else assert.doesNotMatch(metrics.textContent, /\$/);
          const modelRows = [...window.document.querySelectorAll(".qs-model-row")];
          assert.equal(modelRows.length, rows.length);
          assert.equal(modelRows.filter(item => item.textContent.includes("价格未知")).length, 1);
          if (mixed) assert.match(modelRows.find(item => item.textContent.includes("Astra")).textContent, /\$10\.0/);
        }
      }
    } finally { window.close(); }
  });
});
