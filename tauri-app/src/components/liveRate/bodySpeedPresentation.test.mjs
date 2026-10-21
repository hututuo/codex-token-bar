import assert from 'node:assert/strict';
import test from 'node:test';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { Window } from 'happy-dom';
import { withSsrModules } from '../../test/ssrHarness.mjs';
const row = (id, model, end, seconds=2) => ({id,model,threadId:'session',turnId:'turn',itemId:id,startedAt:end-seconds,endedAt:end,outputTokens:100,durationSeconds:seconds,tokensPerSecond:100/seconds,measurementKind:'completed_body',tokenizer:'o200k_base',confidence:'high'});
const summary = (model, end, tps=50) => ({model,lastMeasuredAt:end,tokensPerSecond:tps,sampleCount:1,outputTokens:100,durationSeconds:2});

test('home shows latest six known-model bodies without mutating history; exclusion explains timing', async () => {
 await withSsrModules(async load => {
  const {recentBodySpeedSamples,bodySpeedStatus}=await load('/src/components/liveRate/bodySpeedPresentation.ts');
  const rows=[row('old','sol',10),row('new','luna',50),row('short','sol',40,.5),row('unknown',' unknown ',60),row('middle','astra',30)];
  assert.deepEqual(recentBodySpeedSamples(rows).map(s=>s.id),['new','short','middle','old']);
  assert.equal(rows[0].id,'old');
  assert.equal(bodySpeedStatus(row('short','sol',40,.5)).label,'时长≤0.55秒');
 });
});
test('all retained models appear in overview and current window overrides historical average',async()=>{
 await withSsrModules(async load=>{
  const {modelSpeedReadings}=await load('/src/components/liveRate/bodySpeedPresentation.ts');
  const readings=modelSpeedReadings([summary('sol',100,60)],[summary('sol',50,40),summary('luna',10,120),summary(' unknown ',200)]);
  assert.deepEqual(readings.map(s=>[s.model,s.tokensPerSecond,s.historical]),[['sol',60,false],['luna',120,true]]);
 });
});
test('sidebar keeps all models with single-body reading in 30 minutes; no aggregate fallback or stale model',async()=>{
 await withSsrModules(async load=>{
  const {latestSidebarModelSpeeds}=await load('/src/components/liveRate/bodySpeedPresentation.ts');
  const now=5000;
  const rows=Array.from({length:12},(_,i)=>summary(`model-${i}`,now-i));
  const result=latestSidebarModelSpeeds([...rows,summary('expired',now-1800.001),summary(' unknown ',now),summary('future',now+1),{...summary('average',now),sampleCount:3}],now);
  assert.equal(result.length,12);
  assert.equal(latestSidebarModelSpeeds(rows,now+1801).length,0);
  assert.equal(latestSidebarModelSpeeds([summary('boundary',now-1800)],now).length,1);
 });
});
test('actual home markup has model overview, explicit timestamps and six dense rows, with details button',async()=>{
 await withSsrModules(async load=>{
  const {ObservedSpeedDetails}=await load('/src/components/liveRate/ObservedSpeedDetails.tsx');
  const win=new Window();
  try{
   win.document.body.innerHTML=renderToStaticMarkup(React.createElement(ObservedSpeedDetails,{data:{speedSamples:[...Array.from({length:8},(_,i)=>row(String(i),'sol',100-i)),row('x','unknown',110)],modelSpeeds15m:[summary('sol',40)],modelSpeeds:[summary('luna',20,120)]},sourceToken:{canonicalHomeKey:'test',physicalHomeKey:'test',transitionGeneration:1}}));
   assert.equal(win.document.querySelectorAll('.body-speed-recent-list > li').length,6);
   assert.equal(win.document.querySelectorAll('.body-speed-recent-list time').length,6);
   assert.equal(win.document.querySelectorAll('.body-speed-model').length,2);
   assert.equal(win.document.querySelectorAll('table').length,0);
   assert.match(win.document.body.textContent,/查看详情/);
   assert.doesNotMatch(win.document.body.textContent,/展开历史/);
   assert.match(win.document.body.textContent,/近7天均速/);
  }finally{win.close();}
 });
});
test('actual sidebar is compact, contains all recent models, and has no window selector',async()=>{
 await withSsrModules(async load=>{
  const {SidebarRailContent}=await load('/src/quota-sidebar/QuotaSidebarApp.tsx');
  const now=Date.now()/1000;
  const win=new Window();
  try{
   win.document.body.innerHTML=renderToStaticMarkup(React.createElement(SidebarRailContent,{data:{snapshot:{latestModelSpeeds30m:[summary('gpt-6.1-sol',now-10,47.9),summary('gpt-6-luna',now-20,123.4),summary('old',now-1801)],sevenDayAvailability:'unavailable'},runningThreads:{total:2,status:'ready'}},state:{mode:'hover'},onOpen(){}}));
   const panel=win.document.querySelector('.qs-model-speeds');
   assert.equal(panel.querySelectorAll('.qs-model-speed-row').length,2);
   assert.match(panel.textContent,/正文 TPS/);
   assert.match(panel.textContent,/6.1-sol47.9/);
   assert.match(panel.textContent,/6-luna123.4/);
   assert.doesNotMatch(panel.textContent,/old|15m|30m|均速/);
  }finally{win.close();}
 });
});

test('sidebar expires a stale snapshot on its deadline without receiving new data',async()=>{
 await withSsrModules(async load=>{
  const {SidebarRailContent}=await load('/src/quota-sidebar/QuotaSidebarApp.tsx');
  const win=new Window({url:'http://localhost/'});
  const originals=new Map();
  for(const key of ['window','document','navigator','HTMLElement','Element','Node','Event','ResizeObserver','localStorage']){
   originals.set(key,Object.getOwnPropertyDescriptor(globalThis,key));
   Object.defineProperty(globalThis,key,{configurable:true,writable:true,value:win[key]});
  }
  const oldAct=globalThis.IS_REACT_ACT_ENVIRONMENT;
  globalThis.IS_REACT_ACT_ENVIRONMENT=true;
  let root;
  try{
   const {createRoot}=await import('react-dom/client');
   const container=win.document.createElement('div');win.document.body.append(container);
   root=createRoot(container);
   const now=Date.now()/1000;
   await React.act(async()=>root.render(React.createElement(SidebarRailContent,{
    data:{snapshot:{latestModelSpeeds30m:[summary('sol',now-1799.5),summary('luna',now-10)],sevenDayAvailability:'unavailable'},runningThreads:{total:0,status:'ready'}},
    state:{mode:'hover'},onOpen(){}
   })));
   assert.equal(container.querySelectorAll('.qs-model-speed-row').length,2);
   await React.act(async()=>{await new Promise(resolve=>setTimeout(resolve,650));});
   assert.equal(container.querySelectorAll('.qs-model-speed-row').length,1);
   assert.match(container.querySelector('.qs-model-speeds').textContent,/luna/);
  }finally{
   if(root)await React.act(async()=>root.unmount());
   for(const [key,descriptor]of originals){if(descriptor)Object.defineProperty(globalThis,key,descriptor);else delete globalThis[key];}
   globalThis.IS_REACT_ACT_ENVIRONMENT=oldAct;win.close();
  }
 });
});


test('sidebar detail shows ten records directly without dashboard cards, selectors or local history dialog',async()=>{
 await withSsrModules(async load=>{
  const {ObservedSpeedDetails}=await load('/src/components/liveRate/ObservedSpeedDetails.tsx');
  const win=new Window();
  try{
   win.document.body.innerHTML=renderToStaticMarkup(React.createElement(ObservedSpeedDetails,{surface:'sidebar',data:{speedSamples:Array.from({length:12},(_,i)=>row(String(i),'sol',100-i)),latestModelSpeeds30m:[summary('sol',100,50),summary('luna',90,120)],modelSpeeds15m:[summary('sol',100,40)],modelSpeeds30m:[summary('sol',100,45),summary('luna',90,110)]},sourceToken:{canonicalHomeKey:'test',physicalHomeKey:'test',transitionGeneration:1}}));
   assert.equal(win.document.querySelectorAll('.body-speed-recent-list > li').length,10);
   assert.equal(win.document.querySelectorAll('.body-speed-model,.observed-speed-window,dialog').length,0);
   assert.match(win.document.body.textContent,/最近10条/);
   assert.match(win.document.body.textContent,/打开详细信息/);
   assert.match(win.document.body.textContent,/各模型最新速度/);
   assert.deepEqual([...win.document.querySelectorAll('.body-speed-sidebar-model-row')].map(r=>[...r.children].map(c=>c.textContent)),[['sol','50.0','40.0','45.0'],['luna','120.0','—','110.0']]);
   assert.doesNotMatch(win.document.body.textContent,/展开历史|查看详情/);
  }finally{win.close();}
 });
});
