import test from "node:test";
import assert from "node:assert/strict";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { Window } from "happy-dom";
import { withSsrModules } from "../test/ssrHarness.mjs";

test("local task titles remain associated with their own parent and escape markup", async () => {
  await withSsrModules(async load => {
    const { RunningTaskDetails } = await load("/src/quota-sidebar/RunningTaskDetails.tsx");
    const { localTaskSummary } = await load("/src/quota-sidebar/runningTaskPresentation.ts");
    const base={client:'claudeCode',model:'claude-sonnet',phase:'tools',lastActivity:new Date().toISOString(),liveOutputTps:0,liveTotalTps:0,recentSpeed:null};
    const running=localTaskSummary([{...base,id:'main',parentId:null,title:'主任务'}],
      [{...base,id:'child',parentId:'main',title:'审核 <patch>'},{...base,id:'orphan',parentId:null,title:null}]);
    const html=renderToStaticMarkup(React.createElement(RunningTaskDetails,{running}));
    assert.match(html,/主任务/); assert.match(html,/审核 &lt;patch&gt;/);
    assert.doesNotMatch(html,/<patch>/); assert.match(html,/Claude Code/);
    const window=new Window();
    try {
      window.document.body.innerHTML=html;
      assert.equal(window.document.querySelectorAll('.qs-task-group .qs-child-task').length,1);
      assert.equal(window.document.querySelector('.qs-task-group .qs-child-task .qs-task-title').textContent,'审核 <patch>');
      assert.deepEqual([...window.document.querySelectorAll('.qs-task-totals strong')].map(n=>n.textContent),['1','2']);
      assert.match(window.document.querySelector('.qs-unassigned-tasks').textContent,/未命名子代理/);
    } finally {window.close();}
  });
});

test("missing Claude task records are described in details without fabricating zero tasks", async () => {
  await withSsrModules(async load => {
    const { RunningTaskDetails } = await load("/src/quota-sidebar/RunningTaskDetails.tsx");
    const { combinedRunningTasks } = await load("/src/quota-sidebar/runningTaskPresentation.ts");
    const running=combinedRunningTasks({status:'unavailable'},
      {enabled:true,capturedAt:null,configuredClients:['claudeCode'],sourceAvailable:{},mainAgents:[],subagents:[]},['claudeCode']);
    const html = renderToStaticMarkup(React.createElement(RunningTaskDetails, {running}));
    assert.match(html, /Claude Code · 暂无任务数据/);
    assert.match(html, /合计仅包含已读到的任务/);
    assert.doesNotMatch(html, /<strong>0<\/strong>/);
    assert.match(html, /<strong>未知<\/strong>/);
  });
});

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
    const { sidebarTaskMeter } = await load("/src/quota-sidebar/SidebarTaskMeter.tsx");
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
      taskMeter: sidebarTaskMeter(1, 1, "ready", [{model:"claude-sonnet",count:2}]),
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
