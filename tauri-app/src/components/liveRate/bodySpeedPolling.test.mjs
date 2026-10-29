import test from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { Window } from 'happy-dom';
import { withSsrModules } from '../../test/ssrHarness.mjs';

test('trend polling pauses while hidden, resumes once, and equal source broadcasts preserve the chart', async () => {
 const dom = new Window();
 const globals = ['window','document','navigator','HTMLElement','IS_REACT_ACT_ENVIRONMENT'];
 const previous = globals.map(key => [key,Object.getOwnPropertyDescriptor(globalThis,key)]);
 for (const key of globals) Object.defineProperty(globalThis,key,{configurable:true,writable:true,value:key==='IS_REACT_ACT_ENVIRONMENT'?true:dom[key]});
 const timers = new Map(); let sequence = 0, reads = 0;
 dom.setTimeout = (fn,ms) => { const id=++sequence;timers.set(id,{fn,ms,once:true});return id; };
 dom.setInterval = (fn,ms) => { const id=++sequence;timers.set(id,{fn,ms,once:false});return id; };
 dom.clearTimeout = dom.clearInterval = id => timers.delete(id);
 const now = Date.now()/1000;
 dom.__TAURI_INTERNALS__ = {invoke:async command => {assert.equal(command,'read_body_speed_trend');reads++;return [{bucketStart:now-1800,bucketEnd:now,lowerQuartile:40,median:50,upperQuartile:60,bucketCount:4,model:'gpt-6-luna',tokensPerSecond:50,outputTokens:100,durationSeconds:2,sampleCount:8}];}};
 let root;
 const fire = async ms => {for(const [id,t] of [...timers]) if(t.ms===ms){if(t.once)timers.delete(id);await t.fn();}};
 try {
  const {createRoot}=await import('react-dom/client');root=createRoot(dom.document.body);
  await withSsrModules(async load => {
   const {BodySpeedTrend}=await load('/src/components/liveRate/BodySpeedTrend.tsx');
   const token={canonicalHomeKey:'fixture',physicalHomeKey:'fixture',transitionGeneration:1};
   await React.act(async()=>root.render(React.createElement(BodySpeedTrend,{sourceToken:token,revision:'1'})));
   await React.act(async()=>fire(150));assert.equal(reads,1);
   const line=dom.document.querySelector('.bst-band');assert.ok(line);
   for(let i=0;i<10;i++)await React.act(async()=>root.render(React.createElement(BodySpeedTrend,{sourceToken:{...token},revision:'1'})));
   assert.equal(reads,1);assert.equal(dom.document.querySelector('.bst-band'),line);
   await React.act(async()=>{Object.defineProperty(dom.document,'hidden',{value:true,configurable:true});dom.document.dispatchEvent(new dom.Event('visibilitychange'));});
   assert.equal([...timers.values()].filter(t=>t.ms===60000).length,0);
   await React.act(async()=>fire(60000));assert.equal(reads,1);
   await React.act(async()=>{Object.defineProperty(dom.document,'hidden',{value:false,configurable:true});dom.document.dispatchEvent(new dom.Event('visibilitychange'));});
   await React.act(async()=>fire(150));assert.equal(reads,2);
  });
 } finally {
  if(root)await React.act(async()=>root.unmount());
  for(const [key,desc]of previous)desc?Object.defineProperty(globalThis,key,desc):delete globalThis[key];
  dom.close();
 }
});
