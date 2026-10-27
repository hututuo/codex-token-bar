import test from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { Window } from 'happy-dom';
import { withSsrModules } from '../../test/ssrHarness.mjs';

test('guide acknowledgement survives remount and manual replay without retaining hidden animation', async () => {
 const dom=new Window();
 const keys=['window','document','navigator','HTMLElement','IS_REACT_ACT_ENVIRONMENT','IntersectionObserver'];
 const previous=keys.map(key=>[key,Object.getOwnPropertyDescriptor(globalThis,key)]);
 let observers=0,disconnects=0;
 class Observer {constructor(callback){this.callback=callback;observers++;}observe(target){this.callback([{isIntersecting:true,target}]);}disconnect(){disconnects++;}}
 for(const key of keys) Object.defineProperty(globalThis,key,{configurable:true,writable:true,value:key==='IS_REACT_ACT_ENVIRONMENT'?true:key==='IntersectionObserver'?Observer:dom[key]});
 let root;
 try {
  const {createRoot}=await import('react-dom/client');root=createRoot(dom.document.body);
  await withSsrModules(async load=>{
   const {RecentChartInteractionGuide}=await load('/src/components/recentUsageChart/InteractionGuide.tsx');
   await React.act(async()=>root.render(React.createElement(RecentChartInteractionGuide)));
   let details=dom.document.querySelector('details');
   assert.equal(details.open,true); assert.equal(details.dataset.active,'true');
   assert.ok(details.querySelector('.rig-demo')); assert.match(details.textContent,/演示数据/);
   await React.act(async()=>{details.open=false;details.dispatchEvent(new dom.Event('toggle'));});
   assert.equal(details.querySelector('.rig-demo'),null);assert.equal(disconnects,1);
   assert.equal(dom.localStorage.getItem('recentChartInteractionGuideDismissed'),'true');
   await React.act(async()=>root.unmount());
   root=createRoot(dom.document.body);
   await React.act(async()=>root.render(React.createElement(RecentChartInteractionGuide)));
   details=dom.document.querySelector('details');
   assert.equal(details.open,false);assert.equal(details.querySelector('.rig-demo'),null);
   assert.equal(observers,1, 'A returning visitor must not start the guide observer/animation');
   await React.act(async()=>{details.open=true;details.dispatchEvent(new dom.Event('toggle'));});
   assert.ok(details.querySelector('.rig-demo'));assert.equal(observers,2);
   await React.act(async()=>root.unmount());
   root=createRoot(dom.document.body);
   await React.act(async()=>root.render(React.createElement(RecentChartInteractionGuide)));
   assert.equal(dom.document.querySelector('details').open,false, 'Manual replay must not reset acknowledgement');
   assert.equal(dom.document.querySelector('.rig-demo'),null);
  });
 } finally {
  if(root)await React.act(async()=>root.unmount());
  for(const[key,desc]of previous)desc?Object.defineProperty(globalThis,key,desc):delete globalThis[key];dom.close();
 }
});
