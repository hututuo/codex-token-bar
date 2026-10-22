import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import { modelRateSlices, modelRateGradient } from './modelRatePresentation.ts';
import { modelUsageColor } from '../modelUsagePresentation.ts';
import { changedLiveRateDisplayBucket, liveRateDisplayBucket, rateFillStyle } from './rateDisplay.ts';
test('current model contributions merge aliases, keep unknown amounts, and use usage colors',()=>{
 const rates=[{model:'gpt6astra',tokensPerSecond:10},{model:'gpt-6-astra',tokensPerSecond:30},{model:'gpt-6.1-sol',tokensPerSecond:60},{model:'bad',tokensPerSecond:NaN}];
 const slices=modelRateSlices(rates);
 assert.deepEqual(slices.map(s=>s.share),[.4,.6]);
 assert.deepEqual(slices.map(s=>s.color),[modelUsageColor('gpt-6-astra'),modelUsageColor('gpt-6.1-sol')]);
 assert.equal(modelRateGradient(rates),'linear-gradient(90deg, #d4512c 0%, #d4512c 40%, #268ceb 40%, #268ceb 100%)');
 assert.equal(modelRateSlices([{model:'',tokensPerSecond:10}])[0].model,'unknown');
 assert.equal(modelRateGradient([]),modelUsageColor('unknown'));
 assert.equal(rateFillStyle(100,200,rates)['--rate-fill-scale'],'0.5');
});
test('same total but changed model contribution is published',()=>{
 const base={tokensPerSecond:100,selectedTokensPerSecond:0,warnings:[],unreadSummary:{active:false},modelRates:[{model:'gpt-6-astra',tokensPerSecond:100}]};
 const bucket=liveRateDisplayBucket(base);
 assert.notEqual(changedLiveRateDisplayBucket(bucket,{...base,modelRates:[{model:'gpt-6.1-sol',tokensPerSecond:100}]}),null);
});
test('both platform palette registries agree, including unknown UTF8 models',async()=>{
 const swift=await readFile(new URL('../../../../Sources/CodexTokenBar/ModelUsagePresentation.swift',import.meta.url),'utf8');
 const pairs=[...swift.matchAll(/"([^"]+)": "(#[0-9a-f]{6})"/g)];
 assert.ok(pairs.length>=15);
 for(const [,model,color]of pairs)assert.equal(modelUsageColor(model),color,model);
 assert.equal(modelUsageColor('未来-model-Ω'),'#9b9b81');
 assert.equal(modelUsageColor('codex-auto-review@luna'),modelUsageColor('gpt-5.6-luna'));
});
