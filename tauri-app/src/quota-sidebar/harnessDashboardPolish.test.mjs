import test from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import {renderToStaticMarkup} from 'react-dom/server';
import {Window} from 'happy-dom';
import {withSsrModules} from '../test/ssrHarness.mjs';

test('Claude latest family rows have colors and retain every distinct accounting ID',async()=>withSsrModules(async load=>{
 const {claudeModelIdentity,claudeModelGroups}=await load('/src/components/claudeModelPresentation.ts');
 const {modelUsageColor}=await load('/src/components/modelUsagePresentation.ts');
 assert.deepEqual(claudeModelIdentity('claude-opus-5-5-20261001').version,[5,5]);
 assert.deepEqual(claudeModelIdentity('claude-3-5-haiku-20241022').version,[3,5]);
 assert.deepEqual(claudeModelIdentity('claude-opus-20261001').version,[]);
 assert.equal(claudeModelIdentity('claudeCode|fable5.1').label,'Fable 5.1');
 const keys=['claudeCode|opus-4-6','claudeCode|opus-5-5','claudeCode|sonnet-5-5','claudeCode|fable5.1','claudeCode|custom'];
 const groups=claudeModelGroups(keys.map(key=>({key})),'claudeCode');
 assert.deepEqual(groups[0].items.map(x=>x.key),[keys[3],keys[1],keys[2]]);
 assert.deepEqual(groups.flatMap(x=>x.items).map(x=>x.key).sort(),[...keys].sort());
 assert.equal(new Set(['opus-5-5','sonnet-5-5','haiku-4-5','fable5.1'].map(modelUsageColor)).size,4);
}));

test('floating labels omit GPT and Auto Review without mutating ledger presentation rows',async()=>withSsrModules(async load=>{
 const {compactFloatingModelItems}=await load('/src/floating/floatingModelUsage.ts');
 const rows=[{key:'gpt-6-luna',label:'GPT-6 Luna',tokens:100},{key:'codex-auto-review@luna',label:'Auto Review',tokens:10}];
 const compact=compactFloatingModelItems(rows);assert.equal(compact.length,1);assert.equal(compact[0].label,'6 Luna');
 assert.equal(rows.length,2);assert.equal(rows[0].label,'GPT-6 Luna');
}));

test('quota dots are centered opaque client colors and speed has no client dot',async()=>withSsrModules(async load=>{
 const {SidebarCompactBars}=await load('/src/quota-sidebar/SidebarCompactBars.tsx');
 const {PairedQuotaRing}=await load('/src/multiClient/ClientQuotaViews.tsx');
 const quotas=['5h','7d'].map(window=>({id:'claudeCode:'+window,client:'claudeCode',window,remaining:100,status:'',source:'local'}));
 const html=renderToStaticMarkup(React.createElement(SidebarCompactBars,{items:['speed','quota:claudeCode'],quotas,selection:{colors:{}},ratePercent:50,taskStatus:'ready',taskLabel:'',preview:true}));
 const w=new Window();w.document.body.innerHTML=html;
 const dots=w.document.querySelectorAll('[data-quota-marker-start]');assert.equal(dots.length,2);
 assert.equal(w.document.querySelector('.qs-rate-bar .integrated-client-cap'),null);
 assert.ok([...dots].every(x=>!x.getAttribute('style').includes('color-mix')));
 const ring=renderToStaticMarkup(React.createElement(PairedQuotaRing,{left:quotas[0],right:quotas[1]}));
 w.document.body.innerHTML=ring;assert.equal(w.document.querySelector('[data-quota-marker-end]').dataset.quotaMarkerEnd,'claudeCode:5h claudeCode:7d');
 w.close();
}));

test('marker animation restores all original dots after finish and reversal',async()=>{
 const w=new Window(),saved={document:globalThis.document};globalThis.document=w.document;
 try{await withSsrModules(async load=>{
  const {animateQuotaMarkers}=await load('/src/quota-sidebar/useQuotaMarkerMorph.ts');
  const root=w.document.createElement('div');w.document.body.append(root);
  root.innerHTML='<i data-quota-marker-start="codex:7d" style="background:#123456"></i><i data-quota-marker-end="codex:7d"></i>';
  const start=root.children[0],end=root.children[1];let finished;
  w.HTMLElement.prototype.animate=function(){return {finished:new Promise(resolve=>finished=resolve),cancel(){}};};
  const cancel=animateQuotaMarkers(root,true);
  assert.equal(start.style.visibility,'hidden');assert.equal(end.style.visibility,'hidden');
  assert.equal(root.querySelectorAll('.qs-quota-marker-morph i').length,1);
  const position=cancel();assert.equal(position.size,1);assert.equal(root.querySelector('.qs-quota-marker-morph'),null);assert.equal(start.style.visibility,'');
  const cancelFinished=animateQuotaMarkers(root,false);finished();await Promise.resolve();await Promise.resolve();await Promise.resolve();
  assert.equal(end.style.visibility,'');assert.equal(cancelFinished().size,0,'finished animations must not seed zero positions into the next transition');
 });}finally{Object.assign(globalThis,saved);w.close();}
});

test('homepage scope changes cannot change independently stored sidebar scope',async()=>{
 const w=new Window({url:'http://localhost/'}),keys=['window','document','localStorage','Event','IS_REACT_ACT_ENVIRONMENT'];
 const saved=keys.map(k=>[k,Object.getOwnPropertyDescriptor(globalThis,k)]);
 keys.forEach(k=>Object.defineProperty(globalThis,k,{configurable:true,writable:true,value:k==='IS_REACT_ACT_ENVIRONMENT'?true:w[k]}));
 let root;
 try{await withSsrModules(async load=>{
  const {ClientScopeBoundary,useClientScope,sidebarScopeKey}=await load('/src/multiClient/useClientScope.ts');
  const {scopeKey}=await load('/src/multiClient/integratedClientModel.ts');
  w.localStorage.setItem(scopeKey,'claudeCode');
  function Scope({name}){const {raw,setScope}=useClientScope();return React.createElement('button',{id:name,onClick:()=>setScope('codex')},raw);}
  const {createRoot}=await import('react-dom/client');root=createRoot(w.document.body);
  await React.act(async()=>root.render(React.createElement(React.Fragment,null,React.createElement(Scope,{name:'home'}),React.createElement(ClientScopeBoundary,{surface:'sidebar'},React.createElement(Scope,{name:'sidebar'})))));
  assert.equal(w.document.querySelector('#home').textContent,'claudeCode');assert.equal(w.document.querySelector('#sidebar').textContent,'all');
  await React.act(async()=>w.document.querySelector('#home').click());
  assert.equal(w.document.querySelector('#home').textContent,'codex');assert.equal(w.document.querySelector('#sidebar').textContent,'all');
  assert.equal(w.localStorage.getItem(sidebarScopeKey),null);
 });}finally{if(root)await React.act(async()=>root.unmount());saved.forEach(([k,v])=>v?Object.defineProperty(globalThis,k,v):delete globalThis[k]);w.close();}
});
