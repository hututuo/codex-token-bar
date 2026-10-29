import test from "node:test";
import assert from "node:assert/strict";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { withSsrModules } from "../test/ssrHarness.mjs";

test("Claude interval speed rejects backfilled timestamps and outliers", async () => {
  await withSsrModules(async load => {
    const { qualifiedClaudeInterval } = await load("/src/multiClient/ClaudeLocalRuntime.tsx");
    assert.equal(qualifiedClaudeInterval({durationMs:8, outputTokens:1000}), null);
    assert.equal(qualifiedClaudeInterval({durationMs:400, outputTokens:30}), null);
    assert.equal(qualifiedClaudeInterval({durationMs:5000, outputTokens:250}), 50);
    assert.equal(qualifiedClaudeInterval({durationMs:1000, outputTokens:99999}), null);
  });
});

test("Claude-only scope keeps the original live-card and hides Codex readings", async () => {
  await withSsrModules(async load => {
    const { LiveRateCard } = await load("/src/components/LiveRateCard.tsx");
    const { DEFAULT_FLOATING_SETTINGS } = await load("/src/floating/floatingSettings.ts");
    const { emptyLiveRateSnapshot } = await load("/src/api/fallback/liveFallback.ts");
    const props = { includesCodex:false, localClients:["claudeCode"],
      floatingSettings:DEFAULT_FLOATING_SETTINGS, liveRateEnabled:true, snapshot:emptyLiveRateSnapshot(),
      platform:{platform:"windows", floatingWindow:{available:true},statusTray:{available:true},statusTrayLiveText:{available:true}} };
    const html = renderToStaticMarkup(React.createElement(LiveRateCard, props));
    assert.match(html, /class="live-card"/);
    assert.doesNotMatch(html, /activity-live-chart|activity-history-plot|最近3分钟/);
    assert.match(html, /活动速率/);
    assert.doesNotMatch(html, /请求区间 TPS|API 耗时 TPS/);
    assert.match(html, /等待本地活动记录/);
    assert.doesNotMatch(html, /全会话实时速度/);
    assert.doesNotMatch(html, /Codex.*[0-9]+.*TPS/);
  });
});

test("compact sidebar omits generic placeholders and keeps the real bars and quota markers", async () => {
  await withSsrModules(async load => {
    const { compactSidebarIDs, fixedSidebarRailLayout, sidebarUsesCompactDot } = await load("/src/quota-sidebar/sidebarLayoutPresentation.ts");
    const { clientBrand, defaultQuotaSelection } = await load("/src/multiClient/integratedClientModel.ts");
    const { SidebarCompactBars } = await load("/src/quota-sidebar/SidebarCompactBars.tsx");
    const items = ["modeltrace", "speed", "tps", "quota:claudeCode", "models", "tasks", "radar", "credits", "clientUsage"];
    const quotas = [
      { id: "claudeCode:7d", client: "claudeCode", window: "7d", remaining: 80 },
      { id: "claudeCode:5h", client: "claudeCode", window: "5h", remaining: 62 },
    ];
    assert.deepEqual(compactSidebarIDs(items, quotas), ["speed", "claudeCode:5h", "claudeCode:7d", "models", "tasks"]);
    for (const id of ["modeltrace", "tps", "radar", "credits", "clientUsage", "speed", "models", "tasks", "quota:claudeCode"])
      assert.equal(sidebarUsesCompactDot(id), false, id);
    assert.equal(fixedSidebarRailLayout(5, 900).height, 308);
    const html = renderToStaticMarkup(React.createElement(SidebarCompactBars, {
      items, quotas, selection: defaultQuotaSelection, ratePercent: 50,
      models: [{ key: "claude-sonnet", share: 1, color: "#c08b28" }],
      taskStatus: "ready", taskLabel: "运行任务：2 个，数据最新",
    }));
    for (const id of ["speed", "models", "tasks"]) assert.match(html, new RegExp(`data-sidebar-item="${id}"`));
    assert.deepEqual([...html.matchAll(/data-quota-marker-start="([^"]+)"/g)].map(match => match[1]), ["claudeCode:5h", "claudeCode:7d"]);
    assert.equal((html.match(/class="integrated-client-cap"/g) ?? []).length, 2);
    assert.ok(html.includes(`style="background:${clientBrand.claudeCode}"`));
    for (const id of ["modeltrace", "tps", "radar", "credits", "clientUsage"])
      assert.doesNotMatch(html, new RegExp(`data-sidebar-item="${id}"`), id);
  });
});

test("upstream estimate fraction is used only for the matching source selection", async () => {
  await withSsrModules(async load => {
    const { scopedClaudeEstimateShare } = await load("/src/multiClient/ClaudeLocalRuntime.tsx");
    assert.equal(scopedClaudeEstimateShare(.25, ["claudeCode"], ["claudeCode"]), .25);
    assert.equal(scopedClaudeEstimateShare(.75, ["claudeCode","claudeDesktop"], ["claudeCode"]), null);
    assert.equal(scopedClaudeEstimateShare(.75, ["claudeCode","claudeDesktop"], ["codex","claudeCode","claudeDesktop"]), .75);
    assert.equal(scopedClaudeEstimateShare(NaN, ["claudeCode"], ["claudeCode"]), null);
    assert.equal(scopedClaudeEstimateShare(.5, [], ["claudeCode"]), null);
  });
});
