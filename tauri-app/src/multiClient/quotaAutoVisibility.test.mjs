import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import {renderToStaticMarkup} from "react-dom/server";
import {withSsrModules} from "../test/ssrHarness.mjs";

test("recent quota appears on first observation while API, old and unknown caches default hidden",async()=>withSsrModules(async load=>{
  const {quotaAutomaticallyVisible}=await load("/src/multiClient/multiClientProduct.ts");
  const {quotaItems,orderedQuotaItems,defaultQuotaSelection}=await load("/src/multiClient/integratedClientModel.ts");
  const now=1_800_000_000_000;
  const base={client:"claudeCode",state:"available",source:"fixture",windows:[{label:"5h",usedPercent:90.8865,resetsAt:null}],notice:"",capturedAt:new Date(now).toISOString()};
  for(const client of ["claudeCode","claudeDesktop","antigravity"]){
    for(const [age,expected] of [[0,true],[259_200_000,true],[259_200_001,false],[-60_000,true],[-60_001,false]]){
      assert.equal(quotaAutomaticallyVisible({...base,client,state:"stale",capturedAt:new Date(now-age).toISOString()},now),expected,`${client} age ${age}`);
    }
  }
  for(const state of ["api","invalid","unavailable","missing","notConnected"])assert.equal(quotaAutomaticallyVisible({...base,state},now),false);
  assert.equal(quotaAutomaticallyVisible({...base,capturedAt:null},now),false);
  const catalog=quotaItems(undefined,[base],false,now);
  const items=orderedQuotaItems(catalog,defaultQuotaSelection,["claudeCode"]);
  assert.equal(items.length,1);
  assert.equal(orderedQuotaItems(catalog,{...defaultQuotaSelection,hidden:[items[0].id]},["claudeCode"]).length,0);
  const api=quotaItems(undefined,[{...base,state:"api"}],false,now);
  assert.equal(orderedQuotaItems(api,defaultQuotaSelection,["claudeCode"]).length,0);
  assert.equal(orderedQuotaItems(api,{...defaultQuotaSelection,enabled:["claudeCode:api"]},["claudeCode"]).length,1);
  assert.equal(orderedQuotaItems(quotaItems(undefined,[],false,now),defaultQuotaSelection,["codex"]).length,0);
}));

test("fractional quota survives detail, paired rings, panel and accessible text",async()=>withSsrModules(async load=>{
  const {quotaPercentNumber}=await load("/src/multiClient/multiClientProduct.ts");
  const {compactQuotaValue}=await load("/src/multiClient/integratedClientModel.ts");
  const {value}=await load("/src/multiClient/useClientScope.ts");
  const {ClientQuotaDetailRings,PairedQuotaRing}=await load("/src/multiClient/ClientQuotaViews.tsx");
  const {ClientQuotaPanel}=await load("/src/multiClient/MultiClientUsage.tsx");
  for(const [number,text] of [[9.1135,"9.11"],[12.5,"12.5"],[0.1,"0.1"],[100,"100"],[0,"0"]])assert.equal(quotaPercentNumber(number),text);
  const item={id:"antigravity:gemini",client:"antigravity",window:"Gemini",remaining:9.1135,resetsAt:null,source:"本机语言服务",status:""};
  assert.equal(compactQuotaValue(item),"9.11");assert.equal(value(item),"9.11%");
  const detail=renderToStaticMarkup(React.createElement(ClientQuotaDetailRings,{items:[item]}));assert.match(detail,/9\.11%/);
  const paired=renderToStaticMarkup(React.createElement(PairedQuotaRing,{left:item,right:{...item,id:"antigravity:claude",window:"Claude",remaining:100}}));assert.match(paired,/data-digits="4"/);assert.match(paired,/9\.11/);
  const panel=renderToStaticMarkup(React.createElement(ClientQuotaPanel,{reading:{client:"antigravity",state:"available",source:"local-antigravity-rpc",windows:[{id:"gemini",label:"Gemini",usedPercent:90.8865,resetsAt:null}],notice:"",capturedAt:new Date().toISOString()}}));
  assert.match(panel,/剩余 9\.11%/);assert.match(panel,/读取于/);assert.doesNotMatch(panel,/采样于/);
}));
