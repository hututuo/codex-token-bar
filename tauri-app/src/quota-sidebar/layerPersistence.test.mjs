import test from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import {renderToStaticMarkup} from 'react-dom/server';
import {Window} from 'happy-dom';
import {withSsrModules} from '../test/ssrHarness.mjs';

test('both positioning layers persist; an initially hidden summary has no mounted controls', async () => {
  await withSsrModules(async load => {
    const {SidebarRailContent}=await load('/src/quota-sidebar/QuotaSidebarApp.tsx');
    const data={snapshot:{fiveHourAvailability:'absent',fiveHourRemainingPercent:null,sevenDayAvailability:'measured',sevenDayRemainingPercent:.42},runningThreads:{total:4,status:'ready'}};
    const dom=new Window();
    try {
      for(const mode of ['rest','hover','detail','rest']) {
        dom.document.body.innerHTML=renderToStaticMarkup(React.createElement(SidebarRailContent,{data,state:{mode},onOpen(){}}));
        const bars=dom.document.querySelector('.qs-bars'), summary=dom.document.querySelector('.qs-summary');
        assert.ok(bars && summary);
        assert.equal(bars.dataset.visible,String(mode==='rest'));
        assert.equal(summary.dataset.visible,String(mode!=='rest'));
        assert.equal(summary.hasAttribute('inert'),mode==='rest');
        assert.equal(summary.getAttribute('aria-hidden'),String(mode==='rest'));
        assert.equal(summary.querySelectorAll('.qs-ring').length,mode==='rest'?0:1);
        assert.equal(summary.querySelectorAll('.integrated-paired-ring').length,mode==='rest'?0:1);
      }
    } finally {dom.close();}
  });
});

test('only sidebar settings expose compact and expanded content at once',async()=>{
 await withSsrModules(async load=>{
  const{SidebarRailContent}=await load('/src/quota-sidebar/QuotaSidebarApp.tsx');
  const data={snapshot:{fiveHourAvailability:'absent',fiveHourRemainingPercent:null,sevenDayAvailability:'measured',sevenDayRemainingPercent:.72},runningThreads:{total:3,status:'ready'}};
  const dom=new Window();
  try{
   for(const tab of ['settings','quota']){
    dom.document.body.innerHTML=renderToStaticMarkup(React.createElement(SidebarRailContent,{data,state:{mode:'detail',tab},onOpen(){}}));
    assert.equal(dom.document.querySelector('.qs-bars').dataset.visible,String(tab==='settings'));
    assert.equal(dom.document.querySelector('.qs-summary').dataset.visible,'true');
   }
  }finally{dom.close();}
 });
});
