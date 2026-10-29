import test from 'node:test';
import assert from 'node:assert/strict';
import {dashboardModelUsageColor,DASHBOARD_OTHER_MODEL_COLOR,modelUsageColor} from './modelUsagePresentation.ts';
import {writeSpeedColor,invalidateSpeedColors,SPEED_COLORS_KEY} from './liveRate/speedDisplay.ts';
test('homepage latest groups retain color while other models default to gray',()=>{
 assert.equal(dashboardModelUsageColor('gpt-6-astra',true),modelUsageColor('gpt-6-astra'));
 assert.equal(dashboardModelUsageColor('claudeCode|claude-opus-5-5',true),modelUsageColor('claude-opus-5-5'));
 for(const id of ['gpt-5.6-sol','claudeCode|claude-opus-4-5','deepseek-v4','custom-model'])assert.equal(dashboardModelUsageColor(id,false),DASHBOARD_OTHER_MODEL_COLOR);
});
test('explicit custom colors override gray and survive reading persisted configuration again',()=>{
 const previous=globalThis.window;const stored=new Map();
 globalThis.window={localStorage:{getItem:k=>stored.get(k)??null,setItem:(k,v)=>stored.set(k,v)},dispatchEvent(){}};
 try{
  invalidateSpeedColors();writeSpeedColor('gpt-5.6-sol','#abcdef');
  assert.equal(dashboardModelUsageColor('gpt-5.6-sol',false),'#abcdef');
  assert.equal(JSON.parse(stored.get(SPEED_COLORS_KEY))['gpt-5.6-sol'],'#abcdef');
  invalidateSpeedColors();assert.equal(dashboardModelUsageColor('gpt-5.6-sol',false),'#abcdef');
  writeSpeedColor('gpt-5.6-sol',null);assert.equal(dashboardModelUsageColor('gpt-5.6-sol',false),DASHBOARD_OTHER_MODEL_COLOR);
 }finally{globalThis.window=previous;invalidateSpeedColors();}
});
