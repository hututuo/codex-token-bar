import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
import { withSsrModules } from "../test/ssrHarness.mjs";

const fixture=JSON.parse(await readFile(new URL("../../../fixtures/multi-client-heatmap.json",import.meta.url),"utf8"));
const day=(date,tokens=0,calls=0)=>({date,tokens,calls,cacheHitRate:0,fiveHourRemainingPercent:null,sevenDayRemainingPercent:null});
test("shared fixture preserves client identity, exact known money and local unknowns",async()=>withSsrModules(async load=>{
  const {projectHeatmapDays,localDayKey}=await load("/src/multiClient/heatmapProjection.ts");
  const {modelCostUSD,cellLabel,buildHeatmapDays}=await load("/src/components/tokenActivity/heatmap.ts");
  const {summarizeRange}=await load("/src/components/tokenActivity/rangeSummary.ts");
  const rows=fixture.rows.map(row=>({client:row.client,model:row.model,startUnix:fixture.now,inputTokens:row.input,
    outputTokens:row.output,cacheReadTokens:row.cached,cacheReadComplete:row.cached!=null,requests:1,
    apiCostMicroUSD:row.costMicroUSD,unpricedRequests:row.unpriced}));
  const date=localDayKey(fixture.now),days=projectHeatmapDays([day(date,1450,3)],[],rows,["claudeDesktop","antigravity"],"gpt56Sol");
  const u=days[0].recordedUsage,e=fixture.expected;
  assert.equal(u.totalTokens,e.tokens);assert.equal(u.calls,e.calls);assert.equal(u.knownCostUSD,e.knownCostUSD);
  assert.equal(u.unpricedRequests,e.unpriced);assert.equal(u.cacheReadComplete,e.cacheComplete);assert.equal(u.modelComplete,e.modelComplete);
  assert.equal(u.models.length,3);
  assert.equal(modelCostUSD(days[0],"gpt56Sol"),1.5);
  assert.match(cellLabel(days[0],"modelCost"),/已知金额/);
  assert.match(summarizeRange(days,date,date,"modelCost").value,/已知金额/);
  assert.equal(buildHeatmapDays(days,"cache")[0].intensity,0);
  const standalone=projectHeatmapDays([day(date,1100,1)],[],rows,["claudeDesktop"],"gpt56Sol");
  assert.equal(standalone[0].recordedUsage.cacheHitRate,0.9);
  assert.equal(standalone[0].recordedUsage.knownCostUSD,1.25);
}));
test("quota days use selected pool/window, preserve decimals and leave missing days empty",async()=>withSsrModules(async load=>{
  const {localDayKey}=await load("/src/multiClient/heatmapProjection.ts");
  const {applyClientQuotaDays,resolveQuotaChartSource}=await load("/src/multiClient/clientQuotaHistory.ts");
  const {buildHeatmapDays,cellLabel}=await load("/src/components/tokenActivity/heatmap.ts");
  const {summarizeRange}=await load("/src/components/tokenActivity/rangeSummary.ts");
  const date=localDayKey(fixture.now),next=localDayKey(fixture.now+86400);
  const sample=(windowId,remainingPercent)=>({source:"local-antigravity-rpc",windowId,startUnix:fixture.now,
    remainingPercent,sampleCount:2,firstObservedAt:fixture.now-60,lastObservedAt:fixture.now});
  const reading={client:"antigravity",source:"local-antigravity-rpc",dailyHistory:[sample("gemini-5h",83.125),sample("3p-weekly",0)]};
  const source=resolveQuotaChartSource("antigravity:gemini",["antigravity"],[reading]);
  const days=applyClientQuotaDays([day(date),day(next)],[],reading,source,"5h");
  assert.equal(days[0].fiveHourRemainingPercent,0.83125);assert.equal(days[0].sevenDayRemainingPercent,null);
  assert.equal(days[1].fiveHourRemainingPercent,null);
  assert.match(cellLabel(days[0],"quota"),/83.13%/);
  assert.match(summarizeRange(days,date,next,"quota").value,/覆盖 1\/2 天/);
  assert.equal(buildHeatmapDays(applyClientQuotaDays([day(date)],[],reading,source,"7d"),"quota")[0].intensity,0);
  const third=applyClientQuotaDays([day(date)],[],reading,resolveQuotaChartSource("antigravity:3p",["antigravity"],[reading]),"7d");
  assert.equal(third[0].sevenDayRemainingPercent,0);
}));
test("Codex independent references and unknown models preserve existing cost totals",async()=>withSsrModules(async load=>{
  const {projectHeatmapDays}=await load("/src/multiClient/heatmapProjection.ts");
  const {floatingTodayModelUsageItems,floatingModelUsageKnownCostUSD}=await load("/src/floating/floatingModelUsage.ts");
  const {recordedCostText,recordedModelsText}=await load("/src/components/tokenActivity/recordedUsage.ts");
  for(const names of [["gpt-5.3-codex-spark","codex-auto-review"],
    ["future-unpriced-model","gpt-5.3-codex-spark"],
    ["gpt-5.6-sol","future-unpriced-model","gpt-5.3-codex-spark"]]){
    const rows=names.map(model=>({model,breakdown:{inputTokens:1000,cachedInputTokens:0,outputTokens:200,totalTokens:1200,calls:1}}));
    const base={...day("2026-11-17",1200*rows.length,rows.length),modelBreakdowns:rows};
    const usage=projectHeatmapDays([base],[base],[],["codex"],"gpt56Sol")[0].recordedUsage;
    const expected=floatingModelUsageKnownCostUSD(floatingTodayModelUsageItems(rows,"gpt56Sol",{mergeAutoReview:false}));
    assert.equal(usage.hasKnownCost,expected!==null);
    assert.equal(usage.knownCostUSD,expected??0);
    assert.match(recordedModelsText(usage,true),/不计入合计/);
    if(names.includes("future-unpriced-model"))assert.ok(usage.unpricedRequests>0);
    if(names.includes("gpt-5.6-sol"))assert.match(recordedCostText(usage),/已知金额/);
  }
}));
