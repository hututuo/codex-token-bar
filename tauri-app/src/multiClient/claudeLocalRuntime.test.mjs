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
    assert.match(html, /聚合活动速度/);
    assert.doesNotMatch(html, /请求区间 TPS|API 耗时 TPS/);
    assert.match(html, /等待本地活动记录/);
    assert.doesNotMatch(html, /全会话实时速度/);
    assert.doesNotMatch(html, /Codex.*[0-9]+.*TPS/);
  });
});

test("compact dots use the same item identities and budget six points each", async () => {
  await withSsrModules(async load => {
    const { compactSidebarIDs, fixedSidebarRailLayout, sidebarUsesCompactDot } = await load("/src/quota-sidebar/sidebarLayoutPresentation.ts");
    assert.deepEqual(compactSidebarIDs(["modeltrace","speed","tps"], []), ["modeltrace","speed","tps"]);
    assert.equal(sidebarUsesCompactDot("tps"), true);
    assert.equal(sidebarUsesCompactDot("quota:claudeCode"), false);
    assert.equal(fixedSidebarRailLayout(3, 900, 2).height, 112);
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
