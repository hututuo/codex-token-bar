import assert from 'node:assert/strict';
import test from 'node:test';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { Window } from 'happy-dom';
import { withSsrModules } from '../test/ssrHarness.mjs';
import { DEFAULT_MODULE_VISIBILITY, SIDEBAR_MODULES, sidebarModuleForPage, sanitizeModuleVisibility, DEFAULT_MODULE_ORDER, sanitizeModuleOrder, moveSidebarModule } from './moduleVisibility.ts';

test('all six pages map to independent preferences; legacy settings default visible', () => {
 assert.deepEqual(sanitizeModuleVisibility(null), DEFAULT_MODULE_VISIBILITY);
 assert.equal(sanitizeModuleVisibility({ speeds:false }).speeds, false);
 assert.equal(sanitizeModuleVisibility({ tasks:'false' }).tasks, true);
 assert.deepEqual([sidebarModuleForPage('quota'),sidebarModuleForPage('quota','speeds'),sidebarModuleForPage('running'),sidebarModuleForPage('radar'),sidebarModuleForPage('credits'),sidebarModuleForPage('modeltrace')],SIDEBAR_MODULES);
});
test('all modules can be hidden while the permanent settings entry remains reachable', async () => {
 await withSsrModules(async load => {
  const { SidebarRailContent } = await load('/src/quota-sidebar/QuotaSidebarApp.tsx');
  const { initialSidebarState } = await load('/src/quota-sidebar/model.ts');
  const { emptyAccountQuotaBundle } = await load('/src/api/fallback/quotaFallback.ts');
  const data={quota:emptyAccountQuotaBundle(),snapshot:{todayModelBreakdowns:[],latestModelSpeeds30m:[],quotaDataStale:false},runningThreads:{status:'ready',total:0,mainThreads:0,subagents:0}};
  const dom=new Window();
  const render=(visibility,order)=>{dom.document.body.innerHTML=renderToStaticMarkup(React.createElement(SidebarRailContent,{data,state:{...initialSidebarState,mode:'hover'},visibility,order,onOpen:()=>{}}));};
  try {
   render(DEFAULT_MODULE_VISIBILITY);
   assert.ok(dom.document.querySelector(".qs-summary").firstElementChild.matches(".qs-modeltrace-trigger"));
   assert.ok(dom.document.querySelector(".qs-summary").lastElementChild.matches(".qs-settings-trigger"));
   assert.ok(dom.document.querySelector('.qs-model-speeds'));
   assert.ok(dom.document.querySelector('.qs-running-trigger'));
   assert.ok(dom.document.querySelector('.qs-window-status'));
   render(DEFAULT_MODULE_VISIBILITY,["radar","tasks","credits","overview","speeds","modeltrace"]);
   const nodes=[...dom.document.querySelector(".qs-summary").children];
   assert.ok(nodes.indexOf(dom.document.querySelector(".qs-window-status")) < nodes.indexOf(dom.document.querySelector(".qs-modeltrace-trigger")));
   render({...DEFAULT_MODULE_VISIBILITY,speeds:false});
   assert.equal(dom.document.querySelector('.qs-model-speeds'),null);
   assert.equal(dom.document.querySelector('.qs-rate-trigger'),null);
   assert.ok(dom.document.querySelector('.qs-running-trigger'));
   render(sanitizeModuleVisibility(Object.fromEntries(SIDEBAR_MODULES.map(k=>[k,false]))));
   for(const selector of ['.qs-model-speeds','.qs-running-trigger','.qs-window-status','.qs-model-trigger','.qs-reset-count','.qs-quota-trigger']) assert.equal(dom.document.querySelector(selector),null,selector);
   assert.equal(dom.document.querySelector('.qs-modeltrace-trigger'),null);
   assert.equal(dom.document.querySelector('.qs-settings-trigger').textContent,'侧栏设置');
   assert.equal(dom.document.querySelector('.qs-menu-trigger'),null);

   assert.equal(dom.document.querySelectorAll('.qs-rail-actions button').length,3);
  } finally {dom.close();}
 });
});

test('module order normalizes legacy values and moves without changing visibility',()=>{
 assert.deepEqual(sanitizeModuleOrder(null),DEFAULT_MODULE_ORDER);
 assert.deepEqual(sanitizeModuleOrder(['radar','settings','missing','radar','tasks']),['radar','tasks','modeltrace','speeds','overview','credits']);
 assert.deepEqual(moveSidebarModule(DEFAULT_MODULE_ORDER,'modeltrace',1),['speeds','modeltrace','overview','tasks','radar','credits']);
 assert.deepEqual(moveSidebarModule(DEFAULT_MODULE_ORDER,'modeltrace',-1),DEFAULT_MODULE_ORDER);
 assert.equal(sidebarModuleForPage('settings'),null);
});
