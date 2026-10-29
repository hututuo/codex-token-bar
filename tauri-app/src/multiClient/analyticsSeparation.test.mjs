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

test("aggregate dashboard renders distinct Codex and Claude analytics while keeping Codex controls", async () => {
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
      const codexSection = dom.document.querySelector('[data-client="codex"]');
      const claudeSection = dom.document.querySelector('[data-client="claudeCode"]');
      assert.ok(codexSection, "aggregate scope should render a Codex section");
      assert.ok(claudeSection, "aggregate scope should render a separate Claude CLI section");
      assert.match(codexSection.textContent, /Codex · 用量与缓存/);
      assert.match(claudeSection.textContent, /Claude CLI · 用量与缓存/);

      // The synthetic Claude row is 700 input + 300 output tokens; it remains client-scoped.
      const projectedClaude = (await load("/src/multiClient/originalDashboardProjection.ts"))
        .projectOriginalDashboard(codex, clients, ["claudeCode"]);
      assert.equal(projectedClaude.stats.totalTokens, 1000);
      assert.equal(projectedClaude.recentUsage24h.reduce((sum, point) => sum + point.tokens, 0), 1000);

      // Codex retains its original quota, price visibility, and cache ranking controls.
      assert.ok(codexSection.querySelector(".chart-line-toggle.toggle-five"));
      assert.ok(codexSection.querySelector(".chart-line-toggle.toggle-seven"));
      assert.equal(codexSection.querySelector(".chart-line-toggle.toggle-cost")?.getAttribute("aria-pressed"), "true");
      assert.ok(codexSection.querySelector('[aria-label="缓存命中排行控制"]'));
      assert.match(codexSection.textContent, /查看完整排行/);

      // A Claude projection may inherit Codex source fields internally, but no Codex quota series or API price is exposed.
      assert.equal(claudeSection.querySelector(".chart-line-toggle.toggle-five"), null);
      assert.equal(claudeSection.querySelector(".chart-line-toggle.toggle-seven"), null);
      assert.equal(claudeSection.querySelector(".chart-line-toggle.toggle-cost")?.getAttribute("aria-pressed"), "false");
      assert.equal(claudeSection.querySelector('[aria-label="缓存命中排行控制"]'), null);
      assert.ok(claudeSection.querySelector(".ranking-section"));
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
      assert.equal(section.querySelector('[aria-label="缓存命中排行控制"]'), null);
      assert.ok(section.querySelector(".ranking-section"));
    } finally {
      dom.close();
    }
  });
});

test("activity panel defaults to Agent Speed day detail without rolling mean tables or a fabricated zero", async () => {
  await withSsrModules(async load => {
    const { ClientActivitySpeedPanel } = await load("/src/multiClient/ClaudeLocalRuntime.tsx");
    const markup = renderToStaticMarkup(React.createElement(ClientActivitySpeedPanel, {
      allowed: ["claudeCode"],
      monitoringEnabled: true,
    }));

    assert.match(markup, /活动速率 · Agent Speed/);
    assert.match(markup, /每30秒平均速率 · 无活动采样的时段留空/);
    assert.match(markup, /aria-pressed="true">24小时/);
    assert.match(markup, /等待本地活动记录/);
    assert.doesNotMatch(markup, /(?:5|15|30)\s*分钟均速|5、15、30分钟|rolling5m/i);
    assert.doesNotMatch(markup, /(?:^|\D)0\.0\s*(?:t|tok)\/s/);
  });
});
