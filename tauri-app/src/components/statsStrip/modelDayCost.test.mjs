import test from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import {renderToStaticMarkup} from 'react-dom/server';
import {withSsrModules} from '../../test/ssrHarness.mjs';

test('day bounds use the selected local calendar date including DST',async()=>withSsrModules(async load=>{
 const {modelDayBounds,localDayKey}=await load('/src/components/statsStrip/ModelDayCalendar.tsx');
 const previous=process.env.TZ;
 try {
  for(const [zone,key,hours] of [['Asia/Shanghai','2026-11-05',24],['America/Los_Angeles','2026-03-08',23],['America/Los_Angeles','2026-11-01',25]]) {
   process.env.TZ=zone;const bounds=modelDayBounds(key);
   assert.equal(bounds.endUnix-bounds.startUnix,hours*3600);
   assert.equal(localDayKey(new Date(bounds.startUnix*1000)),key);
   assert.equal(new Date(bounds.endUnix*1000).getHours(),0);
  }
  assert.equal(modelDayBounds('2026-02-30'),null);assert.equal(modelDayBounds('2026-1-1'),null);
 }finally{if(previous===undefined)delete process.env.TZ;else process.env.TZ=previous;}
}));

test('calendar offers individual historical days and disables future dates',async()=>withSsrModules(async load=>{
 const {ModelDayCalendar}=await load('/src/components/statsStrip/ModelDayCalendar.tsx');
 const html=renderToStaticMarkup(React.createElement(ModelDayCalendar,{selected:'2026-11-04',now:new Date(2026,10,6),onSelect(){}}));
 assert.match(html,/单日金额日历/);assert.match(html,/aria-label="2026-11-04的模型金额" aria-pressed="true"/);
 assert.match(html,/aria-label="2026-11-07的模型金额" aria-pressed="false" disabled=""/);
 assert.match(html,/选择历史日期/);assert.match(html,/单日日历上个月/);
}));

test('daily request identity separates date, timezone boundaries, Home, clients and refresh',async()=>withSsrModules(async load=>{
 const {modelDayRequestKey:key}=await load('/src/components/statsStrip/useModelDayUsage.ts');
 const a=key('2026-11-04',{canonicalHomeKey:'a'},['codex','antigravity'],'1');
 assert.equal(a,key('2026-11-04',{canonicalHomeKey:'a'},['antigravity','codex'],'1'));
 for(const b of [key('2026-11-05',{canonicalHomeKey:'a'},['codex','antigravity'],'1'),key('2026-11-04',{canonicalHomeKey:'b'},['codex','antigravity'],'1'),key('2026-11-04',{canonicalHomeKey:'a'},['codex'],'1'),key('2026-11-04',{canonicalHomeKey:'a'},['codex','antigravity'],'2')])assert.notEqual(a,b);
}));

test('calendar entry remains visible in Codex and aggregate fee cards',async()=>withSsrModules(async load=>{
 const {StatsStrip}=await load('/src/components/StatsStrip.tsx');
 const stats={totalTokens:100,peakDayTokens:100,peakThreadTokens:100,currentStreakDays:1,longestStreakDays:1,totalCalls:1,totalThreads:1,modelBreakdowns:[]};
 for(const costs of [undefined,{lifetime:[],today:[],sevenDay:[]}]){
  const html=renderToStaticMarkup(React.createElement(StatsStrip,{stats,planLabel:'',clientCosts:costs}));
  assert.match(html,/单日金额/);
  if(costs)assert.doesNotMatch(html,/选择周期，查看该周期/);else assert.match(html,/历史周期/);
 }
}));
