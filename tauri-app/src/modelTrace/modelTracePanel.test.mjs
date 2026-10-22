import test from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import {Window} from 'happy-dom';
import {withSsrModules} from '../test/ssrHarness.mjs';

test('sidebar detection loads in place without starting a probe; manual actions retain source scope', async()=>{
 const dom=new Window();
 const keys=['window','document','navigator','HTMLElement','IS_REACT_ACT_ENVIRONMENT'];
 const previous=keys.map(key=>[key,Object.getOwnPropertyDescriptor(globalThis,key)]);
 for(const key of keys)Object.defineProperty(globalThis,key,{configurable:true,writable:true,value:key==='IS_REACT_ACT_ENVIRONMENT'?true:dom[key]});
 const calls=[];const source={physicalHomeKey:'fixture-home',sourceGeneration:7};
 const snapshot={scopeKey:'fixture-home',busy:false,models:['gpt-6.1-sol'],runs:[{id:'run1',model:'gpt-6.1-sol',startedAt:1700000000,status:'completed',attempts:3,validSamples:3,message:null,attribution:{prediction:'gpt-6-astra',candidates:[{model:'gpt-6-astra',displayName:'GPT-6 Astra',probability:.92}]}}],settings:{enabled:false,intervalHours:24,nextRunAt:null}};
 dom.__TAURI_EVENT_PLUGIN_INTERNALS__={unregisterListener(){}};
 dom.__TAURI_INTERNALS__={transformCallback:()=>1,invoke:async(command,args)=>{calls.push({command,args});return command==='read_modeltrace_snapshot'?snapshot:null;}};
 let root;
 try{
  const{createRoot}=await import('react-dom/client');root=createRoot(dom.document.body);
  await withSsrModules(async load=>{
   const{ModelTraceContent}=await load('/src/modelTrace/ModelTracePanel.tsx');
   await React.act(async()=>root.render(React.createElement(ModelTraceContent,{sourceToken:source,compact:true})));
   assert.equal(dom.document.querySelector('dialog'),null);
   assert.match(dom.document.body.textContent,/GPT-6 Astra/);
   assert.equal(dom.document.querySelector('[aria-label="选择检测记录"]').value,'run1');
   assert.equal(calls.filter(x=>x.command==='read_modeltrace_snapshot').length,1);
   assert.equal(calls.some(x=>x.command==='start_modeltrace'),false);
   const button=[...dom.document.querySelectorAll('button')].find(x=>x.textContent==='并行检测 3 次');
   await React.act(async()=>button.click());
   const start=calls.find(x=>x.command==='start_modeltrace');
   assert.deepEqual(start.args,{sourceToken:source,model:'gpt-6.1-sol'});
  });
 }finally{
  if(root)await React.act(async()=>root.unmount());
  assert.ok(calls.some(x=>x.command==='plugin:event|unlisten'));
  for(const[key,desc]of previous)desc?Object.defineProperty(globalThis,key,desc):delete globalThis[key];
  dom.close();
 }
});
