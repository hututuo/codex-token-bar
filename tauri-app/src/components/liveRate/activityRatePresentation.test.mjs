import test from 'node:test';
import assert from 'node:assert/strict';
import {withSsrModules} from '../../test/ssrHarness.mjs';

test('yuan rate uses each model output price and preserves unknown price gaps',async()=>{
 await withSsrModules(async load=>{
  const {activityRateValue,activityRateText,safeActivityRateFX}=await load('/src/components/liveRate/activityRatePresentation.ts');
  const {currentStandardAPIPriceQuote}=await load('/src/settings/standardAPIPriceSchedule.ts');
  const rates=[{model:'gpt-6-astra',tokensPerSecond:40},{model:'gpt-6.1-sol',tokensPerSecond:60}];
  const expected=(40*currentStandardAPIPriceQuote('gpt-6-astra').rates.outputUSDPerMillion+60*currentStandardAPIPriceQuote('gpt-6.1-sol').rates.outputUSDPerMillion)*7.2/1e6;
  assert.ok(Math.abs(activityRateValue(100,rates,'CN 元/s',7.2)-expected)<1e-10);
  assert.equal(activityRateValue(101,rates,'CN 元/s',7.2),null);
  assert.equal(activityRateValue(10,[{model:'private-model',tokensPerSecond:10}],'CN 元/s',7.2),null);
  assert.equal(activityRateValue(0,[],'CN 元/s',7.2),0);
  assert.equal(activityRateValue(100,[],'tok/s',NaN),100);
  assert.equal(safeActivityRateFX(NaN),7.2);
  assert.equal(activityRateText(.00001,'CN 元/s'),'<0.0001');
 });
});
