import test from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { Window } from 'happy-dom';
import { withSsrModules } from '../test/ssrHarness.mjs';
import { normalizeSidebarLayout, DEFAULT_SIDEBAR_LAYOUT, isSidebarItemVisible } from './sidebarLayoutModel.ts';

test('unified settings sort on drop, keep visibility, and mount compact preview only when opened',async()=>{
 const dom=new Window(),keys=['window','document','navigator','HTMLElement','Element','IS_REACT_ACT_ENVIRONMENT'];
 const previous=keys.map(key=>[key,Object.getOwnPropertyDescriptor(globalThis,key)]);
 for(const key of keys)Object.defineProperty(globalThis,key,{configurable:true,writable:true,value:key==='IS_REACT_ACT_ENVIRONMENT'?true:dom[key]});
 let root;let layout=normalizeSidebarLayout(null),selection;let writes=0;
 const catalog=[{id:'codex:7d',client:'codex',window:'7d',remaining:72},{id:'claudeCode:5h',client:'claudeCode',window:'5h',remaining:62},{id:'claudeCode:7d',client:'claudeCode',window:'7d',remaining:84}];
 try{
  const{createRoot}=await import('react-dom/client');root=createRoot(dom.document.body);
  await withSsrModules(async load=>{
   const{defaultQuotaSelection}=await load('/src/multiClient/integratedClientModel.ts');selection={...defaultQuotaSelection};
   const{SidebarModuleSettings}=await load('/src/quota-sidebar/SidebarModuleSettings.tsx');
   const render=()=>root.render(React.createElement(SidebarModuleSettings,{layout,catalog,selection,onLayout:next=>{writes++;layout=next;render();},onSelection:next=>{selection=next;render();},compactPreview:React.createElement('b',{'data-preview':'compact'},'compact')}));
   await React.act(async()=>render());
   assert.equal(dom.document.querySelectorAll('[data-layout-item]').length,10);
   assert.ok(dom.document.querySelector('[aria-label="一级显示运行任务"]'));
   assert.equal(dom.document.querySelectorAll('input[type=checkbox]').length,10*2+catalog.length);
   assert.ok(dom.document.querySelector('[aria-label="一级显示正文 TPS"]'));
   assert.equal(dom.document.querySelector('[data-preview]'),null);
   assert.doesNotMatch(dom.document.body.textContent,/长条|短条|点箭头/);
   const speed=()=>dom.document.querySelector('[aria-label="拖动排序：实时速度"]');
   await React.act(async()=>speed().dispatchEvent(new dom.KeyboardEvent('keydown',{key:' ',bubbles:true})));
   await React.act(async()=>speed().dispatchEvent(new dom.KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true})));
   assert.equal(writes,0,'do not persist during drag/keyboard placement');
   assert.deepEqual(layout.order,DEFAULT_SIDEBAR_LAYOUT.order);
   await React.act(async()=>speed().dispatchEvent(new dom.KeyboardEvent('keydown',{key:' ',bubbles:true})));
   assert.equal(writes,1);
   assert.deepEqual(layout.order.slice(0,3),['modeltrace','tps','speed']);
   await React.act(async()=>dom.document.querySelector('[aria-label="二级显示正文 TPS"]').click());
   assert.equal(isSidebarItemVisible(layout,'tps','expanded'),false);
   assert.ok(!layout.hidden.includes('speed'),'body TPS does not hide live speed');
   await React.act(async()=>dom.document.querySelector('[aria-label="一级显示实时速度"]').click());
   assert.equal(isSidebarItemVisible(layout,'speed','compact'),false);
   assert.equal(isSidebarItemVisible(layout,'speed','expanded'),true);
   await React.act(async()=>dom.document.querySelector('[aria-label="二级显示Codex 额度"]').click());
   assert.equal(isSidebarItemVisible(layout,'quota:codex','compact'),true);
   assert.equal(isSidebarItemVisible(layout,'quota:codex','expanded'),false);
   await React.act(async()=>[...dom.document.querySelectorAll('button')].find(x=>x.textContent==='恢复默认顺序').click());
   assert.deepEqual(layout.order,DEFAULT_SIDEBAR_LAYOUT.order);
   assert.equal(isSidebarItemVisible(layout,'tps','expanded'),false,'reset order preserves hidden choices');
   assert.equal(isSidebarItemVisible(layout,'speed','compact'),false);
   const atWrites=writes;
   await React.act(async()=>speed().dispatchEvent(new dom.KeyboardEvent('keydown',{key:' ',bubbles:true})));
   await React.act(async()=>speed().dispatchEvent(new dom.KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true})));
   await React.act(async()=>speed().dispatchEvent(new dom.KeyboardEvent('keydown',{key:'Escape',bubbles:true})));
   assert.equal(writes,atWrites,'cancel does not save');
   assert.deepEqual(layout.order,DEFAULT_SIDEBAR_LAYOUT.order);
   const detail=dom.document.querySelector('details');
   await React.act(async()=>{detail.open=true;detail.dispatchEvent(new dom.Event('toggle'));});
   assert.ok(dom.document.querySelector('[data-preview]'));
   await React.act(async()=>{detail.open=false;detail.dispatchEvent(new dom.Event('toggle'));});
   assert.equal(dom.document.querySelector('[data-preview]'),null);
  });
 }finally{
  if(root)await React.act(async()=>root.unmount());
  for(const[key,desc]of previous)desc?Object.defineProperty(globalThis,key,desc):delete globalThis[key];dom.close();
 }
});
