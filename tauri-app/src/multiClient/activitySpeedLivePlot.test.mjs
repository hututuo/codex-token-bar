import test from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import {renderToStaticMarkup} from 'react-dom/server';
import {withSsrModules} from '../test/ssrHarness.mjs';
const row={client:'codex',points:[{time:100,rate:40,modelRates:[{model:'gpt-6.1-sol',tokensPerSecond:40}]},{time:102,rate:50,modelRates:[{model:'gpt-6.1-sol',tokensPerSecond:50}]}]};
test('compact and detail render one three-minute point-preserving line plot with only observed client labels',async()=>withSsrModules(async load=>{
 const {ActivitySpeedLivePlot}=await load('/src/multiClient/ActivitySpeedLivePlot.tsx');
 for(const compact of [false,true]){
  const html=renderToStaticMarkup(React.createElement(ActivitySpeedLivePlot,{rows:[row],asOf:103,compact}));
  assert.equal((html.match(/<svg/g)||[]).length,1);assert.match(html,/最近3分钟活动速率/);assert.match(html,/Codex/);assert.doesNotMatch(html,/Claude|24小时|30分钟/);
  assert.doesNotMatch(html,/linearGradient/);assert.match(html,/ C/);assert.match(html,/data-live-point-count="2"/);
 }
}));
test('a new chart never adds detected client names before a real speed reading',async()=>withSsrModules(async load=>{
 const {ActivitySpeedLivePlot}=await load('/src/multiClient/ActivitySpeedLivePlot.tsx');
 const html=renderToStaticMarkup(React.createElement(ActivitySpeedLivePlot,{rows:[],asOf:103}));
 assert.match(html,/等待速度读数/);assert.doesNotMatch(html,/Codex|Claude|data-live-client=/);
}));

test('the compact menu reserves no empty chart height before the first speed reading',async()=>withSsrModules(async load=>{
 const {ActivitySpeedLivePlot}=await load('/src/multiClient/ActivitySpeedLivePlot.tsx');
 assert.equal(renderToStaticMarkup(React.createElement(ActivitySpeedLivePlot,{rows:[],asOf:103,compact:true})), '');
}));
