import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import {renderToStaticMarkup} from "react-dom/server";
import {withSsrModules} from "../test/ssrHarness.mjs";

test("multi-client chart sums token totals once and keeps every window aligned",async()=>{
 await withSsrModules(async load=>{
  const {projectClientChart}=await load("/src/multiClient/multiClientProduct.ts");
  const now=1800000000, codex=[{startUnix:now-3600,tokens:110}], others=[{client:"gemini",startUnix:now-3600,inputTokens:100,outputTokens:20,cacheReadTokens:80,reasoningTokens:5,requests:1}];
  for(const days of [1,7,30]){
   const p=projectClientChart(codex,others,days,now,["codex","gemini"]);
   assert.equal(p.reduce((n,p)=>n+p.tokens,0),230);assert.equal(p.length,(days===1?24:days)*2);
   assert.equal(projectClientChart(codex,others,days,now,["gemini"]).reduce((n,p)=>n+p.tokens,0),120);
  }
  assert.equal(projectClientChart([{startUnix:now+1,tokens:999},{startUnix:now-40*86400,tokens:999}],[],1,now,["codex"]).reduce((n,p)=>n+p.tokens,0),0);
 });
});
test("quota adapters only reuse existing observations and expose setup instead of guessed percentages",async()=>{
 await withSsrModules(async load=>{
  const {codexQuotaProvider,unavailableQuota}=await load("/src/multiClient/multiClientProduct.ts");
  const p=codexQuotaProvider({fiveHour:{label:"5h",availability:"measured",usedPercent:25,resetsAt:""}});
  assert.equal(p.allowsNetwork,false);assert.equal(p.reading().windows[0].usedPercent,25);
  assert.equal(codexQuotaProvider().reading().state,"unavailable");
  const missing=unavailableQuota("claudeCode");assert.equal(missing.state,"notConnected");assert.deepEqual(missing.windows,[]);assert.match(missing.notice,/claude-monitor --statusline/);
 });
});
test("uninstalled clients stay hidden while configured and retained clients remain reachable",async()=>{
 await withSsrModules(async load=>{
  const {clientIsAvailable}=await load("/src/multiClient/multiClientProduct.ts");
  assert.equal(clientIsAvailable("gemini",[],[],[]),false);
  assert.equal(clientIsAvailable("gemini",[{client:"gemini",evidence:"binary"}],[],[]),true);
  assert.equal(clientIsAvailable("gemini",[],[{client:"gemini",enabled:false,path:"/custom"}],[]),true);
  assert.equal(clientIsAvailable("gemini",[],[],[{client:"gemini"}]),true);
 });
});
test("new controls preserve Codex defaults and no percent is added into the token graph",async()=>{
 await withSsrModules(async load=>{
  const {MultiClientUsageSettings,ClientUsageChart,MultiClientUsageDashboardCard}=await load("/src/multiClient/MultiClientUsage.tsx");
  const settings=renderToStaticMarkup(React.createElement(MultiClientUsageSettings));
  assert.doesNotMatch(settings,/<legend[^>]*>Gemini CLI/);assert.match(settings,/手动接入其他日志目录/);assert.match(settings,/联网额度：关闭/);
  assert.equal(renderToStaticMarkup(React.createElement(MultiClientUsageDashboardCard)),"");
  const chart=renderToStaticMarkup(React.createElement(ClientUsageChart,{points:[{client:"codex",startUnix:1800000000,tokens:120},{client:"gemini",startUnix:1800000000,tokens:30}],colors:{codex:"#00ff00",gemini:"#0000ff"}}));
  assert.match(chart,/role="button"/);assert.match(chart,/Codex 120/);assert.match(chart,/Gemini CLI 30/);assert.doesNotMatch(chart,/usedPercent/);
 });
});

test("sidebar combined totals retain exact Codex tokens despite identical rounded labels", async()=>{
 const {mergeFloatingUsageSummary}=await import("../surfaces/compactPanelSnapshotModel.ts");
 const first=mergeFloatingUsageSummary({tokensPerSecond:42,todayModelBreakdowns:[]},{totalTokens:1234001,todayTokens:50,todayRequests:5});
 const next=mergeFloatingUsageSummary(first,{totalTokens:1234002,todayTokens:50,todayRequests:5});
 assert.equal(next.totalTokensLabel,first.totalTokensLabel);
 assert.equal(next.totalTokensValue,1234002);
 assert.equal(next.tokensPerSecond,42);
 assert.equal(mergeFloatingUsageSummary(next,{totalTokens:1234002,todayTokens:50,todayRequests:5}),next);
});
