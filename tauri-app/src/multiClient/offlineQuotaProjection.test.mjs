import assert from "node:assert/strict";
import test from "node:test";
import {readFile} from "node:fs/promises";
import React from "react";
import {renderToStaticMarkup} from "react-dom/server";
import {withSsrModules} from "../test/ssrHarness.mjs";

const fixture=JSON.parse(await readFile(new URL("../../../../fixtures/local-quota-caches.json",import.meta.url),"utf8"));

test("shared offline quotas retain Antigravity model pools and Claude resets across scopes",async()=>withSsrModules(async load=>{
  const {quotaItems,orderedQuotaItems,defaultQuotaSelection}=await load("/src/multiClient/integratedClientModel.ts");
  const rows=quotaItems(undefined,fixture.readings);
  const ag=orderedQuotaItems(rows,defaultQuotaSelection,["antigravity"]);
  assert.deepEqual(ag.map(r=>[r.id,r.remaining]),[["antigravity:gemini-4-argon",70],["antigravity:claude-opus-5-5",0]]);
  const desktop=orderedQuotaItems(rows,defaultQuotaSelection,["claudeDesktop"]);
  assert.deepEqual(desktop.map(r=>r.remaining),[70,10]);
  assert.ok(desktop.every(r=>r.resetsAt===fixture.readings[1].windows[0].resetsAt));
  const hidden={...defaultQuotaSelection,hidden:[ag[0].id]};
  assert.deepEqual(orderedQuotaItems(rows,hidden,["antigravity"]).map(r=>r.id),[ag[1].id]);
  const {ClientQuotaDetailRings}=await load("/src/multiClient/ClientQuotaViews.tsx");
  const html=renderToStaticMarkup(React.createElement(ClientQuotaDetailRings,{items:ag,selection:defaultQuotaSelection}));
  assert.match(html,/Argon 4/);assert.match(html,/Opus 5.5/);assert.match(html,/70%/);assert.match(html,/0%/);
  assert.match(html,/integrated-quota-card/);
}));

test("old or undated cache remains an honest notice, not a full quota ring",async()=>withSsrModules(async load=>{
  const {quotaItems}=await load("/src/multiClient/integratedClientModel.ts");
  const {ClientQuotaPanel}=await load("/src/multiClient/MultiClientUsage.tsx");
  for(const state of ["stale","cached"]){
    const reading={...fixture.readings[0],state};
    const rows=quotaItems(undefined,[reading]).filter(r=>r.client==="antigravity");
    assert.equal(rows.length,1);assert.equal(rows[0].remaining,null);assert.equal(rows[0].id,"antigravity:cache");
    assert.equal(rows[0].status,state==="stale"?"额度采样已过期":"采样时间未知");
    const html=renderToStaticMarkup(React.createElement(ClientQuotaPanel,{reading}));
    assert.match(html,/非当前余额/);assert.match(html,/上次剩余 70%/);
    assert.doesNotMatch(html,/DO-NOT-PROJECT/);
  }
}));

test("Desktop HTTP source preserves reset times and labels itself without implying a paused app",async()=>withSsrModules(async load=>{
  const {claudeQuotaFromLocalCache}=await load("/src/multiClient/multiClientProduct.ts");
  const reset=fixture.readings[1].windows[0].resetsAt;
  const reading=claudeQuotaFromLocalCache({source:"local-desktop-http-cache",state:"available",capturedAt:fixture.readings[1].capturedAt,fiveHour:{usedPercent:30,resetsAt:reset}},"claudeDesktop");
  assert.equal(reading.windows[0].resetsAt,reset);assert.match(reading.notice,/HTTP 缓存/);
  assert.doesNotMatch(reading.notice,/重置时间未知|暂停/);
}));
