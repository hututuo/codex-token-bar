import test from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import {renderToStaticMarkup} from 'react-dom/server';
import {Window} from 'happy-dom';
import {withSsrModules} from '../test/ssrHarness.mjs';
import {expectedRemainingPercentByEvenPace} from '../utils/quota.ts';
import {sidebarExpectedFraction} from './meterFeedback.ts';
test('expected marker preserves reference direction, real zero, and hides absent or stale references',()=>{
 assert.equal(sidebarExpectedFraction(40,70),.7);
 assert.equal(sidebarExpectedFraction(0,0),0);
 assert.equal(sidebarExpectedFraction(40,100),1);
 assert.equal(sidebarExpectedFraction(40,1),.01);
 for(const expected of [null,undefined,NaN,Infinity,-.1,100.1])assert.equal(sidebarExpectedFraction(40,expected),null);
 assert.equal(sidebarExpectedFraction(null,70),null);
 assert.equal(sidebarExpectedFraction(40,70,true),null);
});
test('quota reference marks and model strip use snapshot references and floating model shares',async()=>{
 await withSsrModules(async load=>{
  const {SidebarRailContent}=await load('/src/quota-sidebar/QuotaSidebarApp.tsx');
  const {floatingTodayModelUsageItems}=await load('/src/floating/floatingModelUsage.ts');
  const rows=[['gpt-6-astra',80],['gpt-5.6-sol',20]].map(([model,totalTokens])=>({model,breakdown:{totalTokens}}));
  const data={snapshot:{fiveHourAvailability:'absent',fiveHourRemainingPercent:null,sevenDayAvailability:'measured',sevenDayRemainingPercent:.4,sevenDayExpectedRemainingPercent:expectedRemainingPercentByEvenPace({label:"7d",availability:"measured",resetsAtUnix:1_000+7*24*3600*.7},1_000),todayModelBreakdowns:rows},runningThreads:{total:0,status:'ready'}};
  const dom=new Window();try {
   dom.document.body.innerHTML=renderToStaticMarkup(React.createElement(SidebarRailContent,{data,state:{mode:'hover'},onOpen(){}}));
   assert.equal(dom.document.querySelectorAll('.qs-pace-mark').length,1);
   assert.equal(dom.document.querySelector('.qs-pace-mark').style.bottom,'70%');
   assert.ok(Math.abs(parseFloat(dom.document.querySelector('.qs-pace-tick').getAttribute('transform').slice(7))-252)<1e-8);
   const expected=floatingTodayModelUsageItems(rows,'gpt56Sol',{showPlaceholders:false});
   const segments=[...dom.document.querySelectorAll('.qs-model-strip-vertical i')];
   assert.deepEqual(segments.map(el=>Number(el.style.flexGrow)),expected.map(item=>item.share));
   assert.equal(dom.document.querySelectorAll('.qs-rate-trigger .qs-pace-tick').length,0);
  }finally{dom.close();}
 });
});
