import assert from 'node:assert/strict';
import test from 'node:test';
import {withSsrModules} from '../../test/ssrHarness.mjs';

test('all clients enter the original chart pipeline with conserved tokens calls and ledger fees',async()=>withSsrModules(async load=>{
 const {projectOriginalDashboard}=await load('/src/multiClient/originalDashboardProjection.ts');
 const {emptyDashboardSnapshot}=await load('/src/api/fallback/dashboardFallback.ts');
 const {prepareRecentChartData,plotChartPoints}=await load('/src/components/recentUsageChart/model.ts');
 const {recordedChartCosts}=await load('/src/components/recentUsageChart/recordedCosts.ts');
 const now=1_800_000_000,codex=emptyDashboardSnapshot();codex.generatedAt=new Date(now*1000).toISOString();
 const point={startUnix:now,label:'',tokens:1000,calls:1,inputTokens:1000,cachedInputTokens:200,outputTokens:0,cacheHitRate:.2,fiveHourRemainingPercent:null,sevenDayRemainingPercent:null};
 codex.recentUsage24h=[point];codex.recentUsage7d=[point];codex.recentUsage30d=[point];
 const clients=['claudeCode','claudeDesktop','antigravity','gemini','deepseek','opencode'];
 const external=clients.map((client,i)=>({client,startUnix:now,inputTokens:(i+1)*2000,outputTokens:10,requests:i+1,cacheReadTokens:0,apiCostMicroUSD:(i+1)*100_000,unpricedRequests:0}));
 const snapshot={preferences:[],summaries:[],trendBuckets:external,dailyBuckets:[],diagnostics:[],updatedAt:codex.generatedAt};
 for(const range of ['24h','7d','30d']){
  const all=projectOriginalDashboard(codex,snapshot,['codex',...clients]);
  const data=prepareRecentChartData(range,all);
  assert.equal(data.tokenTotal,1000+external.reduce((sum,x)=>sum+x.inputTokens+x.outputTokens,0));
  assert.equal(data.callTotal,1+external.reduce((sum,x)=>sum+x.requests,0));
  const costs=recordedChartCosts(data.points,data.bucketSeconds,external,data.points.map(x=>x.startUnix===Math.floor(now/data.bucketSeconds)*data.bucketSeconds?2:0),true);
  assert.ok(Math.abs(costs.reduce((sum,x)=>sum+x.cost,0)-4.1)<.000001);
  const plot=plotChartPoints(data,980,215,'gpt56Sol',{bucketCostsUSD:costs.map(x=>x.cost)});
  assert.ok(plot.tokenPoints.some(x=>x.y<200));
  assert.ok(plot.tokenPoints.every(x=>Number.isFinite(x.y)&&x.y>=0&&x.y<=215));
 }
 const unknown=recordedChartCosts([{startUnix:now}],300,[{client:'antigravity',startUnix:now,inputTokens:20,outputTokens:0,requests:1,apiCostMicroUSD:null,unpricedRequests:1}],[99],false);
 assert.deepEqual(unknown,[{cost:0,unknown:1,known:false}]);
}));
