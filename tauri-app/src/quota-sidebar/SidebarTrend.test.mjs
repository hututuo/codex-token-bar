import assert from 'node:assert/strict';
import test from 'node:test';
import React from 'react';
import { Window } from 'happy-dom';
import { withSsrModules } from '../test/ssrHarness.mjs';

test('mini trend keeps quota lows, breaks missing samples, and selects the clicked sample', async () => {
  const window = new Window();
  const keys = ['window','document','navigator','HTMLElement','IS_REACT_ACT_ENVIRONMENT'];
  const previous = keys.map(key => [key,Object.getOwnPropertyDescriptor(globalThis,key)]);
  for (const key of keys) Object.defineProperty(globalThis,key,{value:key==='IS_REACT_ACT_ENVIRONMENT'?true:window[key]??window,configurable:true,writable:true});
  try {
    await withSsrModules(async load => {
      const {SidebarTrend,trendPath} = await load('/src/quota-sidebar/SidebarTrend.tsx');
      const {createRoot} = await import('react-dom/client');
      const points=[{at:0,tokens:100,five:null,seven:.07},{at:300,tokens:200,five:null,seven:null},{at:600,tokens:300,five:null,seven:.17}];
      assert.equal(trendPath(points,'seven',1),'M0.00,78.40 M340.00,70.40 ');
      assert.equal(trendPath(points,'tokens',300),'M0.00,57.33 L170.00,30.67 L340.00,4.00 ');
      const root=createRoot(window.document.body);
      try {
        await React.act(async()=>root.render(React.createElement(SidebarTrend,{points})));
        const svg=window.document.querySelector('svg');
        svg.getBoundingClientRect=()=>({left:0,width:340});
        await React.act(async()=>svg.dispatchEvent(new window.MouseEvent('click',{bubbles:true,clientX:0})));
        assert.match(window.document.body.textContent,/7d 7%/);
        assert.ok(!window.document.body.textContent.includes('5h'));
        assert.ok(window.document.querySelector('[stroke-dasharray]'));
      } finally {await React.act(async()=>root.unmount());}
    });
  } finally {
    for(const [key,value] of previous) value?Object.defineProperty(globalThis,key,value):delete globalThis[key];
    window.close();
  }
});
