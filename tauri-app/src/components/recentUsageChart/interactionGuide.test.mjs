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
   await React.act(async()=>dom.document.querySelector('[aria-label="关闭图表使用引导"]').click());
   assert.equal(dom.document.querySelector('.recent-chart-guide-shell'),null,'Closing removes the header as well as the animation');
   assert.equal(dom.localStorage.getItem('recentChartInteractionGuideHidden'),'true');
   await React.act(async()=>root.unmount());
   root=createRoot(dom.document.body);
   await React.act(async()=>root.render(React.createElement(RecentChartInteractionGuide)));
   assert.equal(dom.document.querySelector('details'),null,'A closed guide stays absent after remount');
   assert.equal(observers,2,'A closed guide does not start an animation visibility observer');
   const {setChartGuideHidden}=await load('/src/components/recentUsageChart/guidePreferences.ts');
   await React.act(async()=>setChartGuideHidden(false));
   assert.equal(dom.document.querySelector('details').open,true,'Restoring in settings reopens the mounted guide immediately');
   assert.ok(dom.document.querySelector('.rig-demo'));
   assert.equal(observers,3);
   await React.act(async()=>dom.document.querySelector('[aria-label="关闭图表使用引导"]').click());
   assert.equal(dom.document.querySelector('.rig-demo'),null);
   assert.equal(disconnects,3,'Closing an expanded guide disconnects its visibility observer');
  });
 } finally {
  if(root)await React.act(async()=>root.unmount());
  for(const[key,desc]of previous)desc?Object.defineProperty(globalThis,key,desc):delete globalThis[key];dom.close();
 }
});
