import assert from 'node:assert/strict';
import test from 'node:test';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { Window } from 'happy-dom';
import { withSsrModules } from '../test/ssrHarness.mjs';
import { DEFAULT_MODULE_VISIBILITY, SIDEBAR_MODULES, sidebarModuleForPage, sanitizeModuleVisibility } from './moduleVisibility.ts';

test('all five pages map to independent preferences; legacy settings default visible', () => {
 assert.deepEqual(sanitizeModuleVisibility(null), DEFAULT_MODULE_VISIBILITY);
 assert.equal(sanitizeModuleVisibility({ speeds:false }).speeds, false);
 assert.equal(sanitizeModuleVisibility({ tasks:'false' }).tasks, true);
 assert.deepEqual([sidebarModuleForPage('quota'),sidebarModuleForPage('quota','speeds'),sidebarModuleForPage('running'),sidebarModuleForPage('radar'),sidebarModuleForPage('credits')],SIDEBAR_MODULES);
});
test('hidden modules disappear while menu recovery and manual detection remain accessible', async () => {
 await withSsrModules(async load => {
  const { SidebarRailContent } = await load('/src/quota-sidebar/QuotaSidebarApp.tsx');
  const { initialSidebarState } = await load('/src/quota-sidebar/model.ts');
  const { emptyAccountQuotaBundle } = await load('/src/api/fallback/quotaFallback.ts');
  const data={quota:emptyAccountQuotaBundle(),snapshot:{todayModelBreakdowns:[],latestModelSpeeds30m:[],quotaDataStale:false},runningThreads:{status:'ready',total:0,mainThreads:0,subagents:0}};
  const dom=new Window();
  const render=visibility=>{dom.document.body.innerHTML=renderToStaticMarkup(React.createElement(SidebarRailContent,{data,state:{...initialSidebarState,mode:'hover'},visibility,onOpen:()=>{}}));};
  try {
   render(DEFAULT_MODULE_VISIBILITY);
   assert.ok(dom.document.querySelector('.qs-model-speeds'));
   assert.ok(dom.document.querySelector('.qs-running-trigger'));
   assert.ok(dom.document.querySelector('.qs-window-status'));
   render({...DEFAULT_MODULE_VISIBILITY,speeds:false});
   assert.equal(dom.document.querySelector('.qs-model-speeds'),null);
   assert.equal(dom.document.querySelector('.qs-rate-trigger'),null);
   assert.ok(dom.document.querySelector('.qs-running-trigger'));
   render(Object.fromEntries(SIDEBAR_MODULES.map(k=>[k,false])));
   for(const selector of ['.qs-model-speeds','.qs-running-trigger','.qs-window-status','.qs-model-trigger','.qs-reset-count','.qs-quota-trigger']) assert.equal(dom.document.querySelector(selector),null,selector);
   assert.equal(dom.document.querySelector('.qs-modeltrace-trigger').textContent,'模型检测');
   assert.equal(dom.document.querySelector('.qs-menu-trigger').textContent,'菜单 ›');
   assert.equal(dom.document.querySelectorAll('.qs-rail-actions button').length,3);
  } finally {dom.close();}
 });
});
