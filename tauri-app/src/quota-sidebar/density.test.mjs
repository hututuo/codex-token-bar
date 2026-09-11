import test from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import {renderToStaticMarkup} from 'react-dom/server';
import {Window} from 'happy-dom';
import {withSsrModules} from '../test/ssrHarness.mjs';

test('detail composition counts cached input once and keeps every model accessible', async()=>{
 await withSsrModules(async load=>{
  const {QuotaDetails}=await load('/src/quota-sidebar/QuotaSidebarApp.tsx');
  const {emptyAccountQuotaBundle}=await load('/src/api/fallback/quotaFallback.ts');
  const rows=['gpt-6-astra','gpt-5.6-sol','gpt-5.6-terra','gpt-5.6-luna','gpt-5.5'].map(model=>({model,breakdown:{inputTokens:80,cachedInputTokens:60,outputTokens:20,totalTokens:100,calls:1}}));
  const data={quota:emptyAccountQuotaBundle(),snapshot:{todayModelBreakdowns:rows,unreadSummary:{source:'local',label:'无未读'}},runningThreads:{status:'ready',total:0}};
  const window=new Window();
  try{
   window.document.body.innerHTML=renderToStaticMarkup(React.createElement(QuotaDetails,{data}));
   const parts=[...window.document.querySelectorAll('.qs-composition-chart i')].map(el=>Number(el.style.flexGrow));
   assert.deepEqual(parts,[100,300,100]);
   assert.equal(parts.reduce((a,b)=>a+b,0),500);
   assert.equal(window.document.querySelectorAll('.qs-model-row').length,5);
   assert.equal(window.document.querySelectorAll('.qs-usage .qs-metrics>div').length,6);
  }finally{window.close();}
 });
});
