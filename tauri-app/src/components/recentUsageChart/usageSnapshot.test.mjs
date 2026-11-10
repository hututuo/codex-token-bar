import assert from "node:assert/strict";
import test from "node:test";
import {withSsrModules} from "../../test/ssrHarness.mjs";
import {usageFixture as fixture,chartFixtureSources} from "./usageSnapshotFixture.mjs";

test("shared multi-client fixture conserves every displayed model and amount in all ranges and scopes",async()=>withSsrModules(async load=>{
  const {codex,clients}=await chartFixtureSources(load);
  const {projectOriginalDashboard}=await load("/src/multiClient/originalDashboardProjection.ts");
  const {prepareRecentChartData,alignProviderPoints,prepareQuotaEvidenceData,chartQuotaConsumptionSelection}=await load("/src/components/recentUsageChart/model.ts");
  const {buildChartUsageSnapshot,chartUsageSummary,chartModelCacheText}=await load("/src/components/recentUsageChart/usageSnapshot.ts");
  const all=["codex","claudeCode","antigravity","gemini"];
  for(const [range,seconds]of Object.entries(fixture.ranges))for(const scope of [all,["codex"],["claudeCode"],["antigravity"],["gemini"],["claudeCode","antigravity"]]){
    const external=fixture.external.filter(row=>scope.includes(row.client)),includes=scope.includes("codex");
    const projected=projectOriginalDashboard(codex,clients,scope),data=prepareRecentChartData(range,projected);
    const provider=prepareRecentChartData(range,codex),aligned=alignProviderPoints(data.points,includes?provider.points:[]);
    const snapshot=buildChartUsageSnapshot(data,aligned,external,includes,"gpt56Sol");
    const last=data.points.length-1,selected=chartUsageSummary(snapshot.buckets,last,0);
    assert.equal(data.bucketSeconds,seconds);
    const expected=(includes?360:0)+external.reduce((n,row)=>n+row.inputTokens+row.outputTokens,0);
    assert.equal(selected.totalTokens,expected);
    assert.equal(selected.models.reduce((n,row)=>n+row.totalTokens,0),expected);
    assert.equal(selected.calls,data.callTotal);
    assert.equal(selected.knownCostUSD,snapshot.bucketCostsUSD.reduce((a,b)=>a+b,0));
    assert.deepEqual(selected,chartUsageSummary(snapshot.buckets,0,last));
    assert.ok(selected.models.every(row=>scope.includes(row.client)));
    for(const row of selected.models) assert.equal(chartModelCacheText(row),fixture.expected.modelCacheText[row.id],range+row.id);
    if(scope===all){
      assert.equal(selected.totalTokens,fixture.expected.tokens);assert.equal(selected.calls,fixture.expected.calls);
      assert.equal(selected.inputTokens,fixture.expected.input);assert.equal(selected.cachedInputTokens,fixture.expected.cached);
      assert.deepEqual(selected.models.map(row=>row.id).sort(),[...fixture.expected.models].sort());
      assert.equal(selected.unpricedRequests,fixture.expected.unpriced);assert.equal(selected.cacheHitRate,null);
      const quota=chartQuotaConsumptionSelection(data,prepareQuotaEvidenceData(range,codex),0,last,"gpt56Sol");
      assert.equal(quota.totalTokens,360);assert.equal(quota.startIndex,0);assert.equal(quota.endIndex,last);
      assert.ok(quota.modelBreakdowns.every(row=>row.model.startsWith("gpt")),"only the provider enters quota estimation");
    }
  }
}));

test("shared model cache cases preserve weighted hits and per-model completeness",async()=>withSsrModules(async load=>{
  const {combineChartModels,chartModelCacheHitRate}=await load("/src/components/recentUsageChart/usageSnapshot.ts");
  for(const item of fixture.cacheMergeCases){
    const rows=item.rows.map(row=>({id:"claudeCode|claude-sonnet-4-6",client:"claudeCode",model:"claude-sonnet-4-6",sourceModels:["claude-sonnet-4-6"],
      totalTokens:row.input+10,inputTokens:row.input,cachedInputTokens:row.cached,outputTokens:10,calls:1,
      cacheReadComplete:row.complete,cacheWriteTokens:null,knownCostUSD:null,unpricedRequests:1}));
    const [model]=combineChartModels(rows);
    assert.equal(model.cacheReadComplete,item.expectedComplete,item.name);
    assert.equal(chartModelCacheHitRate(model),item.expectedRate,item.name);
  }
}));

test("legacy missing model fields stay unknown and partial cache input never becomes zero usage",async()=>withSsrModules(async load=>{
  const {buildChartUsageSnapshot,chartUsageSummary}=await load("/src/components/recentUsageChart/usageSnapshot.ts");
  const {prepareRecentChartData}=await load("/src/components/recentUsageChart/model.ts");
  const point={startUnix:0,label:"",tokens:120,calls:2,inputTokens:100,cachedInputTokens:5,outputTokens:20,cacheHitRate:null,fiveHourRemainingPercent:null,sevenDayRemainingPercent:null};
  const data=prepareRecentChartData("24h",{recentUsage24h:[point],recentUsage7d:[],recentUsage30d:[]});
  const external=[{client:"gemini",startUnix:0,inputTokens:100,outputTokens:20,requests:2,cacheReadTokens:5,cacheReadComplete:false}];
  const selected=chartUsageSummary(buildChartUsageSnapshot(data,[],external,false,"gpt56Sol").buckets,0,0);
  assert.equal(selected.totalTokens,120);assert.equal(selected.calls,2);assert.equal(selected.cacheHitRate,null);
  assert.equal(selected.models.length,1);assert.equal(selected.models[0].client,"gemini");
  assert.equal(selected.hasKnownCost,false);assert.equal(selected.unpricedRequests,2);
}));
