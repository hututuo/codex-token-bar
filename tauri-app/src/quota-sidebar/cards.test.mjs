import assert from 'node:assert/strict';
import test from 'node:test';
import React from 'react';
import {renderToStaticMarkup} from 'react-dom/server';
import {Window} from 'happy-dom';
import {withSsrModules} from '../test/ssrHarness.mjs';

test('radar tabs select independent official and crowd rankings',async()=>{
 const window=new Window();const keys=['window','document','navigator','Element','HTMLElement','IS_REACT_ACT_ENVIRONMENT'];
 const prev=keys.map(k=>[k,Object.getOwnPropertyDescriptor(globalThis,k)]);
 for(const key of keys)Object.defineProperty(globalThis,key,{value:key==='IS_REACT_ACT_ENVIRONMENT'?true:window[key]??window,configurable:true,writable:true});
 try{await withSsrModules(async load=>{
  const {RadarDetails,SidebarRailContent}=await load('/src/quota-sidebar/QuotaSidebarApp.tsx');
  const {createRoot}=await import('react-dom/client');
  const row=(model,iq)=>({rank:1,model,iq,effort:'high',passed:45,samples:50});
  const radar={official:{available:true,fresh:true,primary:null,rows:[row('official-model',141)]},crowd:{available:true,rows:[row('crowd-model',135)],minimumSamples:45}};
  const root=createRoot(window.document.body);
  try{
   await React.act(async()=>root.render(React.createElement(RadarDetails,{radar})));
   assert.match(window.document.body.textContent,/official-model/);assert.ok(!window.document.body.textContent.includes('crowd-model'));
   await React.act(async()=>window.document.querySelectorAll('[role=tab]')[1].click());
   assert.match(window.document.body.textContent,/crowd-model/);assert.ok(!window.document.body.textContent.includes('official-model'));
   const calls=[];
   const expires=Math.floor(Date.now()/1000)+3600;
   const data={snapshot:{todayModelBreakdowns:[],sevenDayAvailability:'measured',sevenDayRemainingPercent:.5,fiveHourAvailability:'absent'},runningThreads:{total:2,status:'ready'},quota:{quota:{resetCredit:{updatedAt:'known',availableCount:3,credits:[{cardId:'one',status:'可用',expiresAtUnix:expires,redeemedAt:''}]}}}};
   await React.act(async()=>root.render(React.createElement(SidebarRailContent,{data,radar,state:{mode:'hover'},onOpen:(...args)=>calls.push(args)})));
   for(const selector of ['.qs-rate-trigger','.qs-model-trigger','.qs-running-trigger','.qs-reset-count','.qs-recommendations']) await React.act(async()=>window.document.querySelector(selector).click());
   assert.deepEqual(calls,[['quota','usage'],['quota','models'],['running','top'],['credits','top'],['radar','ranking']]);
   assert.match(window.document.querySelector('.qs-reset-count').textContent,/重置卡 3 张/);

  }finally{await React.act(async()=>root.unmount());}
 });}finally{for(const[k,v]of prev)v?Object.defineProperty(globalThis,k,v):delete globalThis[k];window.close();}
});

test('quota pace stays with percentage and each reset card includes its own dates',async()=>{
 await withSsrModules(async load=>{
  const {QuotaDetails,SidebarRailContent,ResetCreditDetails}=await load('/src/quota-sidebar/QuotaSidebarApp.tsx');
  const {emptyAccountQuotaBundle}=await load('/src/api/fallback/quotaFallback.ts');
  const quota=emptyAccountQuotaBundle();
  quota.quota.resetCredit={availableCount:2,updatedAt:'2026-09-10T00:00:00Z',status:'可用',credits:[1,2].map(n=>({cardId:String(n),status:'可用',issuedAt:`2026-09-0${n}T00:00:00Z`,expiresAt:`2026-10-0${n}T00:00:00Z`,redeemedAt:''}))};
  const data={quota,snapshot:{trendLabel:'先省着用',todayModelBreakdowns:[],unreadSummary:{source:'local',label:''},fiveHourAvailability:'absent',sevenDayAvailability:'measured',sevenDayRemainingPercent:.4},runningThreads:{status:'ready',total:0}};
  const html=renderToStaticMarkup(React.createElement(QuotaDetails,{data}));
  assert.ok(html.indexOf('先省着用')<html.indexOf('Token 用量'));
  assert.ok(!html.includes('class="qs-reset-card"'));
  const creditsHtml=renderToStaticMarkup(React.createElement(ResetCreditDetails,{data}));
  assert.equal((creditsHtml.match(/class="qs-reset-card"/g)||[]).length,2);
  assert.match(creditsHtml,/10\/1/);assert.match(creditsHtml,/10\/2/);
  const rail=renderToStaticMarkup(React.createElement(SidebarRailContent,{data,state:{mode:'hover'},onOpen(){}}));
  assert.match(rail,/重置卡 2 张/);
 });
});


test('section navigation retains the destination, repeats same-section requests and clears it for tabs',async()=>{
 const {sidebarReducer,initialSidebarState,isSidebarAction}=await import('./model.ts');
 let state=sidebarReducer(initialSidebarState,{type:'open',tab:'quota',section:'credits'});
 assert.equal(state.section,'credits');assert.equal(state.focusRevision,1);
 state=sidebarReducer(state,{type:'open',tab:'quota',section:'credits'});
 assert.equal(state.focusRevision,2);
 assert.ok(isSidebarAction({type:'open',tab:'quota',section:'models'}));
 assert.ok(!isSidebarAction({type:'open',tab:'quota',section:'made-up'}));
 state=sidebarReducer(state,{type:'open',tab:'running'});
 assert.equal(state.section,undefined);assert.equal(state.tab,'running');
});
