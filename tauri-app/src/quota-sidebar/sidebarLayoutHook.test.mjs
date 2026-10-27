import test from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { Window } from 'happy-dom';
import { withSsrModules } from '../test/ssrHarness.mjs';
import { normalizeSidebarLayout, moveSidebarItem } from './sidebarLayoutModel.ts';

const deferred=()=>{let resolve;const promise=new Promise(done=>resolve=done);return{promise,resolve};};
async function mounted(invoke,run){
 const dom=new Window({url:'http://localhost/'}),keys=['window','document','navigator','HTMLElement','Element','IS_REACT_ACT_ENVIRONMENT'];
 const previous=keys.map(key=>[key,Object.getOwnPropertyDescriptor(globalThis,key)]);
 for(const key of keys)Object.defineProperty(globalThis,key,{configurable:true,writable:true,value:key==='IS_REACT_ACT_ENVIRONMENT'?true:dom[key]});
 let handler,state,root;
 dom.__TAURI_INTERNALS__={transformCallback:callback=>{handler=callback;return 1;},invoke:async(command,args)=>command.startsWith('plugin:event|')?1:invoke(command,args)};
 dom.__TAURI_EVENT_PLUGIN_INTERNALS__={unregisterListener:()=>{}};
 try{
  const{createRoot}=await import('react-dom/client');root=createRoot(dom.document.body);
  await withSsrModules(async load=>{
   const{useSidebarLayout}=await load('/src/quota-sidebar/useSidebarLayout.ts');
   function Probe(){state=useSidebarLayout();return null;}
   await React.act(async()=>root.render(React.createElement(Probe)));
   await run({get:()=>state,event:()=>handler({event:'sidebar-layout-changed',payload:normalizeSidebarLayout(null)}),act:React.act});
  });
 }finally{
  if(root)await React.act(async()=>root.unmount());
  for(const[key,desc]of previous)desc?Object.defineProperty(globalThis,key,desc):delete globalThis[key];dom.close();
 }
}

test('layout migration initializes only, read failure stays disabled and retry recovers',async()=>{
 let disk=null,fail=false,initializations=0;
 await mounted(async(command,args)=>{
  if(command==='read_sidebar_layout'){if(fail)throw Error('unavailable');return disk;}
  if(command==='read_sidebar_module_order')return ['speeds','overview'];
  if(command==='read_sidebar_module_visibility')return [];
  if(command==='save_sidebar_layout'){assert.equal(args.initializeOnly,true);initializations++;return disk??=args.layout;}
  throw Error(command);
 },async({get,event,act})=>{
  assert.equal(get().ready,true);assert.equal(initializations,1);
  fail=true;await act(async()=>event());
  assert.equal(get().ready,false);assert.match(get().error,/读取失败/);
  fail=false;await act(async()=>get().retry());
  assert.equal(get().ready,true);assert.equal(get().error,null);assert.equal(initializations,1);
 });
});

test('late save replies and superseded reads cannot replace a newer disk layout',async()=>{
 let disk=normalizeSidebarLayout(null),heldSave=null,reads=[];
 await mounted(async(command,args)=>{
  if(command==='read_sidebar_layout')return reads.length?reads.shift().promise:disk;
  if(command==='save_sidebar_layout'){disk=args.layout;heldSave=deferred();return heldSave.promise;}
  throw Error(command);
 },async({get,event,act})=>{
  const moved=moveSidebarItem(disk,'speed','models',true),newer=moveSidebarItem(moved,'quota:claudeCode','modeltrace',false);
  let saving;
  await act(async()=>{saving=get().save(moved);});
  disk=newer;
  await act(async()=>event()); // deferred while saving
  const readA=deferred(),readB=deferred();reads=[readA,readB];
  await act(async()=>{heldSave.resolve(moved);});
  assert.equal(get().ready,false);
  await act(async()=>event());
  await act(async()=>readB.resolve(newer));
  await act(async()=>{readA.resolve(moved);await saving;});
  assert.deepEqual(get().layout.order,newer.order);
  assert.equal(get().ready,true);assert.equal(get().pending,false);
 });
});
