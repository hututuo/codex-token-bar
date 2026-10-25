import assert from 'node:assert/strict';
import test from 'node:test';
import React from 'react';
import {renderToStaticMarkup} from 'react-dom/server';
import {withSsrModules} from '../test/ssrHarness.mjs';
const stamp=Date.parse('2026-10-25T12:00:00Z')/1000;
const stats={totalTokens:0,totalInputTokens:0,totalOutputTokens:0,totalCachedInputTokens:0,peakDayTokens:0,peakThreadTokens:0,currentStreakDays:0,longestStreakDays:0,totalCalls:0,totalThreads:0,modelBreakdowns:[]};
const dashboard=()=>({generatedAt:new Date(stamp*1000).toISOString(),stats:{...stats},activityDays:[],recentUsage24h:[],recentUsage7d:[],recentUsage30d:[],cacheUsage:{sessions:[],turns:[]},cacheHitRanking:[],warnings:[]});
const row={client:'claudeCode',model:'claude-sonnet-4-6',inputTokens:1000,outputTokens:200,cacheReadTokens:800,cacheWriteTokens:0,reasoningTokens:0,requests:2,lastSeen:new Date(stamp*1000).toISOString(),apiCostUSD:0.03,unpricedRequests:0,cacheReadComplete:true};
const bucket={client:'claudeCode',startUnix:stamp-3600,inputTokens:1000,outputTokens:200,cacheReadTokens:800,cacheWriteTokens:0,reasoningTokens:0,requests:2};
const snapshot=()=>({preferences:[],summaries:[row],todaySummaries:[],sevenDaySummaries:[row],dailyBuckets:[bucket],trendBuckets:[bucket],updatedAt:new Date(stamp*1000).toISOString()});
test('Codex-only uses the original snapshot object',async()=>withSsrModules(async load=>{
 const {projectOriginalDashboard}=await load('/src/multiClient/originalDashboardProjection.ts');const original=dashboard();assert.equal(projectOriginalDashboard(original,snapshot(),['codex']),original);
}));
test('short client history uses the original 365-day calendar and real five-minute gaps',async()=>withSsrModules(async load=>{
 const {projectOriginalDashboard}=await load('/src/multiClient/originalDashboardProjection.ts');const original=dashboard();const result=projectOriginalDashboard(original,snapshot(),['claudeCode']);
 assert.equal(result.stats.totalTokens,1200);assert.equal(result.activityDays.length,365);assert.equal(result.activityDays.filter(x=>x.tokens===0).length,364);
 assert.equal(result.recentUsage24h.length,13);assert.equal(result.recentUsage24h.reduce((n,x)=>n+x.tokens,0),1200);assert.equal(result.recentUsage24h[1].calls,0);assert.equal(result.recentUsage24h[1].cacheHitRate,null);
 assert.equal(original.stats.totalTokens,0);assert.equal(result.attributionIdentity,null);
}));
test('unknown cache read does not become a zero hit-rate point',async()=>withSsrModules(async load=>{
 const {projectOriginalDashboard}=await load('/src/multiClient/originalDashboardProjection.ts');const source=snapshot();source.summaries=[{...row,cacheReadTokens:null,cacheReadComplete:false}];source.trendBuckets=[{...bucket,cacheReadTokens:null}];
 const result=projectOriginalDashboard(dashboard(),source,['claudeCode']);assert.equal(result.recentUsage24h[0].cacheHitRate,null);assert.equal(result.stats.totalTokens,1200);
}));
test('client fee scopes retain the original six metrics and model chips',async()=>withSsrModules(async load=>{
 const {StatsStrip}=await load('/src/components/StatsStrip.tsx');const {clientCostPeriods}=await load('/src/multiClient/originalDashboardProjection.ts');const periods=clientCostPeriods(dashboard(),snapshot(),['claudeCode'],stamp);
 assert.equal(periods.today.length,0);assert.equal(periods.sevenDay[0].key,'claudeCode|claude-sonnet-4-6');
 const html=renderToStaticMarkup(React.createElement(StatsStrip,{stats:{...stats,totalTokens:1200},planLabel:'',clientCosts:periods}));
 assert.equal((html.match(/class="stats-cell/g)??[]).length,6);assert.match(html,/stats-model-cost-secondary-chip/);assert.match(html,/近7天/);assert.match(html,/sonnet 4 6/);assert.doesNotMatch(html,/<table|integrated-stats|选择周期|累计净薅到/);
}));
test('client quota reuses original quota bars without the Codex attribution owner',async()=>withSsrModules(async load=>{
 const {QuotaStrip}=await load('/src/components/QuotaStrip.tsx');const html=renderToStaticMarkup(React.createElement(QuotaStrip,{clientItems:[{id:'claudeCode:5h',client:'claudeCode',window:'5h',remaining:62,resetsAt:null,status:'',source:'模拟'}]}));
 assert.match(html,/class="quota-strip"/);assert.match(html,/class="quota-bar"/);assert.match(html,/62%/);assert.doesNotMatch(html,/重置卡|官方直连/);
}));
