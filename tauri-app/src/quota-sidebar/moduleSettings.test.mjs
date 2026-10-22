import test from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { Window } from 'happy-dom';
import { withSsrModules } from '../test/ssrHarness.mjs';
import { DEFAULT_MODULE_ORDER, DEFAULT_MODULE_VISIBILITY } from './moduleVisibility.ts';

test('settings controls reorder hidden items, restore only order, and expose all six toggles',async()=>{
 const dom=new Window(),keys=['window','document','navigator','HTMLElement','IS_REACT_ACT_ENVIRONMENT'];
 const previous=keys.map(key=>[key,Object.getOwnPropertyDescriptor(globalThis,key)]);
 for(const key of keys)Object.defineProperty(globalThis,key,{configurable:true,writable:true,value:key==='IS_REACT_ACT_ENVIRONMENT'?true:dom[key]});
 let root;let order=[...DEFAULT_MODULE_ORDER],visibility={...DEFAULT_MODULE_VISIBILITY};
 try{
  const{createRoot}=await import('react-dom/client');root=createRoot(dom.document.body);
  await withSsrModules(async load=>{
   const{SidebarModuleSettings}=await load('/src/quota-sidebar/SidebarModuleSettings.tsx');
   const render=()=>root.render(React.createElement(SidebarModuleSettings,{order,visibility,onOrder:next=>{order=next;render();},onToggle:(module,value)=>{visibility={...visibility,[module]:value};render();}}));
   await React.act(async()=>render());
   assert.equal(dom.document.querySelectorAll('input[type=checkbox]').length,6);
   assert.equal(dom.document.querySelector('[aria-label="上移模型检测"]').disabled,true);
   await React.act(async()=>dom.document.querySelector('[data-module=modeltrace] input').click());
   assert.equal(visibility.modeltrace,false);
   await React.act(async()=>dom.document.querySelector('[aria-label="下移模型检测"]').click());
   assert.deepEqual(order.slice(0,2),['speeds','modeltrace']);
   assert.equal(dom.document.querySelectorAll('li')[1].dataset.module,'modeltrace');
   const reset=[...dom.document.querySelectorAll('button')].find(x=>x.textContent==='恢复默认顺序');
   await React.act(async()=>reset.click());
   assert.deepEqual(order,DEFAULT_MODULE_ORDER);assert.equal(visibility.modeltrace,false);
   assert.equal(dom.document.querySelector('dialog'),null);
  });
 }finally{
  if(root)await React.act(async()=>root.unmount());
  for(const[key,desc]of previous)desc?Object.defineProperty(globalThis,key,desc):delete globalThis[key];dom.close();
 }
});
