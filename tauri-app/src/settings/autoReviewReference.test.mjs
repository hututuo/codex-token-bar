import assert from 'node:assert/strict';
import test from 'node:test';
import { autoReviewReferenceCostUSD, isAutoReviewUsage, modelAwareAPICostUSD, officialAPICostUSD } from './quotaPriceModel.ts';
import { floatingTodayModelUsageItems, floatingModelUsageKnownCostUSD, floatingModelUsageValue, hasUnknownModelPrices } from '../floating/floatingModelUsage.ts';
const breakdown={inputTokens:1_000_000,cachedInputTokens:0,outputTokens:0,totalTokens:1_000_000,calls:1};
const row=model=>({model,breakdown:{...breakdown}});

test('free review keeps tokens and a dated reference but never enters the paid subtotal',()=>{
 const rows=[row('codex-auto-review'),row('gpt-5.6-luna')];
 const total={inputTokens:2_000_000,cachedInputTokens:0,outputTokens:0,calls:2};
 const value=modelAwareAPICostUSD(rows,total,'gpt56Sol');
 assert.equal(value.costUSD,officialAPICostUSD(1_000_000,0,0,'gpt56Luna'));
 assert.deepEqual(value.excludedModels,['codex-auto-review']);assert.equal(value.excludedCalls,1);
 const items=floatingTodayModelUsageItems(rows,'gpt56Sol',{mergeAutoReview:false});
 const review=items.find(x=>x.label.includes('Auto Review'));
 assert.equal(items.length,2);assert.equal(items.reduce((n,x)=>n+x.tokens,0),2_000_000);
 assert.equal(review.costUSD,null);assert.equal(review.usesIndependentQuota,false);
 assert.ok(review.referenceCostUSD>0);assert.match(floatingModelUsageValue(review,'cost'),/不计入总计/);
 assert.equal(hasUnknownModelPrices(items),false);assert.equal(floatingModelUsageKnownCostUSD(items),value.costUSD);
 assert.equal(rows[0].model,'codex-auto-review');
});

test('old and new review price cards remain reference-only',()=>{
 const before=Date.parse('2026-07-29T23:59:59Z')/1000,after=before+1;
 assert.equal(autoReviewReferenceCostUSD('codex-auto-review',1_000_000,0,0,before),2.5);
 assert.equal(autoReviewReferenceCostUSD('codex-auto-review',1_000_000,0,0,after),0.2);
 for(const model of ['codex-auto-review','codex_auto_review','codex-auto-review@luna','codex-auto-review@5.4']) {
  assert.equal(isAutoReviewUsage(model),true);
  const items=floatingTodayModelUsageItems([row(model)],'gpt56Sol',{mergeAutoReview:false});
  assert.equal(floatingModelUsageKnownCostUSD(items),0);
  assert.equal(modelAwareAPICostUSD([row(model)],breakdown,'gpt56Sol').costUSD,0);
 }
 assert.equal(isAutoReviewUsage('codex-auto-review-fast'),false);
 assert.equal(isAutoReviewUsage('gpt-5.6-luna'),false);
});

test('known free review is removed even when remaining model coverage is incomplete',()=>{
 const value=modelAwareAPICostUSD([row('codex-auto-review')],{inputTokens:2_000_000,cachedInputTokens:0,outputTokens:0,calls:2},'gpt56Sol');
 assert.equal(value.costUSD,officialAPICostUSD(1_000_000,0,0,'gpt56Sol'));
 assert.equal(value.fallbackCalls,1);assert.equal(value.excludedCalls,1);
});

test('compact share merging cannot make review billable regardless of row order',()=>{
 for(const rows of [[row('codex-auto-review'),row('gpt-5.6-luna')],[row('gpt-5.6-luna'),row('codex-auto-review')]]) {
  const items=floatingTodayModelUsageItems(rows,'gpt56Sol',{mergeAutoReview:true});
  assert.equal(items.length,1);assert.equal(items[0].tokens,2_000_000);
  assert.equal(floatingModelUsageKnownCostUSD(items),officialAPICostUSD(1_000_000,0,0,'gpt56Luna'));
 }
});
