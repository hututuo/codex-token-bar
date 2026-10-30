import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { Window } from "happy-dom";
import { withSsrModules } from "../test/ssrHarness.mjs";

function renderWithBrowserStorage(element) {
  const previousWindow = globalThis.window;
  const browser = new Window({ url: "http://localhost/" });
  globalThis.window = browser;
  try {
    return renderToStaticMarkup(element);
  } finally {
    browser.close();
    if (previousWindow === undefined) delete globalThis.window;
    else globalThis.window = previousWindow;
  }
}

function measuredQuota(limit, remainingPercent, resetsAtUnix) {
  return {
    ...limit,
    availability: "measured",
    remainingPercent,
    usedPercent: 1 - remainingPercent,
    resetsAt: new Date(resetsAtUnix * 1000).toISOString(),
    resetsAtUnix,
  };
}

function usagePoint(startUnix, { tokens, calls, inputTokens, cachedInputTokens, outputTokens, hitRate }) {
  return {
    label: new Date(startUnix * 1000).toISOString(),
    startUnix,
    tokens,
    calls,
    inputTokens,
    cachedInputTokens,
    outputTokens,
    cacheHitRate: hitRate,
    fiveHourRemainingPercent: null,
    sevenDayRemainingPercent: null,
  };
}

test("aggregate dashboard renders one combined analytics block and preserves provider controls", async () => {
  await withSsrModules(async load => {
    const { emptyDashboardSnapshot } = await load("/src/api/fallback/dashboardFallback.ts");
    const { DashboardAnalyticsSection } = await load("/src/pages/dashboard/DashboardAnalyticsSection.tsx");
    const now = Math.floor(Date.now() / 300) * 300;

    // Disposable fixture values make the two client projections easy to distinguish.
    const codex = emptyDashboardSnapshot();
    codex.generatedAt = new Date(now * 1000).toISOString();
    codex.quota.fiveHour = measuredQuota(codex.quota.fiveHour, 0.62, now + 3600);
    codex.quota.sevenDay = measuredQuota(codex.quota.sevenDay, 0.41, now + 86400);
    codex.recentUsage24h = [usagePoint(now, { tokens: 500, calls: 1, inputTokens: 400, cachedInputTokens: 200, outputTokens: 100, hitRate: 0.5 })];
    codex.recentUsage7d = [...codex.recentUsage24h];
    codex.recentUsage30d = [...codex.recentUsage24h];
    codex.cacheHitRanking = [{ rank: 1, title: "fixture-codex-session", subtitle: "synthetic fixture", hitRate: 0.75, inputTokens: 400, cachedTokens: 300 }];

    const clients = {
      preferences: [],
      summaries: [{ client: "claudeCode", model: "claude-sonnet-4-5", inputTokens: 700, outputTokens: 300,
        cacheReadTokens: 500, cacheWriteTokens: 20, reasoningTokens: null, requests: 2,
        lastSeen: new Date(now * 1000).toISOString(), cacheReadComplete: true }],
      todaySummaries: [],
      sevenDaySummaries: [],
      trendBuckets: [{ client: "claudeCode", startUnix: now, inputTokens: 700, outputTokens: 300,
        cacheReadTokens: 500, cacheWriteTokens: 20, requests: 2 }],
      dailyBuckets: [],
      diagnostics: [],
      updatedAt: new Date(now * 1000).toISOString(),
    };

    const markup = renderWithBrowserStorage(React.createElement(DashboardAnalyticsSection, {
      dashboard: codex,
      originalCodex: codex,
      clients,
      allowed: ["claudeCode", "codex"],
      sharedAccountAttribution: null,
    }));
    const dom = new Window({ url: "http://localhost/" });
    dom.document.body.innerHTML = markup;
    try {
      const section = dom.document.querySelector('[data-client="all"]');
      assert.ok(section);
      assert.equal(dom.document.querySelectorAll('.client-analytics').length,1);
      assert.equal(section.querySelectorAll('.activity-section').length,1);
      assert.equal(section.querySelectorAll('.ranking-section').length,1);
      assert.equal(section.querySelectorAll('[aria-label="曲线范围"]').length,1);
      assert.doesNotMatch(section.textContent,/Claude CLI · 用量与缓存|Codex · 用量与缓存/);
      const projected = (await load("/src/multiClient/originalDashboardProjection.ts"))
        .projectOriginalDashboard(codex,clients,["codex","claudeCode","opencode"]);
      const point=projected.recentUsage24h.find(point=>point.startUnix===now);
      assert.equal(point.tokens,1500);
      assert.equal(point.calls,3);
      assert.equal(point.cacheHitRate,700/1100,"cache is input-weighted, not a mean of client percentages");
      assert.ok(section.querySelector('.toggle-five'));
      assert.ok(section.querySelector('.toggle-seven'));
      assert.equal(section.querySelector('.toggle-cost').getAttribute('aria-pressed'),'true');
      assert.match(section.querySelector('.toggle-cost').textContent,/Codex/);
      assert.match(section.textContent,/fixture-codex-session|查看完整排行/);
      assert.ok(section.querySelector('[aria-label="缓存命中排行控制"]'));
      assert.equal(dom.document.querySelector('[data-client="opencode"]'),null,"detected empty clients add no placeholder blocks");

    } finally {
      dom.close();
    }
  });
});

test("Claude-only analytics does not expose Codex quota, pricing, or cache-rank controls", async () => {
  await withSsrModules(async load => {
    const { emptyDashboardSnapshot } = await load("/src/api/fallback/dashboardFallback.ts");
    const { DashboardAnalyticsSection } = await load("/src/pages/dashboard/DashboardAnalyticsSection.tsx");
    const codex = emptyDashboardSnapshot();
    const clients = {
      preferences: [], summaries: [], todaySummaries: [], sevenDaySummaries: [],
      trendBuckets: [], dailyBuckets: [], diagnostics: [], updatedAt: null,
    };
    const markup = renderWithBrowserStorage(React.createElement(DashboardAnalyticsSection, {
      dashboard: codex,
      originalCodex: codex,
      clients,
      allowed: ["claudeCode"],
      clientScoped: true,
      sharedAccountAttribution: null,
    }));
    const dom = new Window({ url: "http://localhost/" });
    dom.document.body.innerHTML = markup;
    try {
      const section = dom.document.querySelector('[data-client="claudeCode"]');
      assert.ok(section);
      assert.equal(section.querySelector(".chart-line-toggle.toggle-five"), null);
      assert.equal(section.querySelector(".chart-line-toggle.toggle-seven"), null);
      assert.equal(section.querySelector(".chart-line-toggle.toggle-cost")?.getAttribute("aria-pressed"), "false");
      assert.equal(section.querySelector('[aria-label="排行类型"]'), null);
      assert.equal(section.querySelector(".ranking-check"),null);
      assert.ok(section.querySelector(".ranking-section"));
    } finally {
      dom.close();
    }
  });
});

test("activity panel uses only a three-minute memory plot without a history query or fabricated zero", async () => {
  await withSsrModules(async load => {
    const { ClientActivitySpeedPanel } = await load("/src/multiClient/ClaudeLocalRuntime.tsx");
    const markup = renderToStaticMarkup(React.createElement(ClientActivitySpeedPanel, {
      allowed: ["claudeCode"],
      monitoringEnabled: true,
    }));

    assert.match(markup, /活动速率/);
    assert.match(markup, /Agent Speed/);
    assert.match(markup, /仅保留内存中的近3分钟/);
    assert.doesNotMatch(markup, /24小时|近30分钟/);
    assert.match(markup, /等待速度读数/);
    assert.doesNotMatch(markup, /(?:5|15|30)\s*分钟均速|5、15、30分钟|rolling5m/i);
    assert.doesNotMatch(markup, /(?:^|\D)0\.0\s*(?:t|tok)\/s/);
  });
});
