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
        assert.equal(summary.querySelectorAll('.qs-ring').length,mode==='rest'?0:2);
      }
    } finally {dom.close();}
  });
});
