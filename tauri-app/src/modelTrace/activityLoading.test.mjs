import assert from 'node:assert/strict';
import test from 'node:test';
import React from 'react';
import {Window} from 'happy-dom';
import {mockIPC, clearMocks} from '@tauri-apps/api/mocks';
import {withSsrModules} from '../test/ssrHarness.mjs';

test('activity keeps its calendar and footer while snapshot/history load or fail', async () => {
 const window=new Window();
 const keys=['window','document','navigator','Element','HTMLElement','IS_REACT_ACT_ENVIRONMENT'];
 const previous=keys.map(key=>[key,Object.getOwnPropertyDescriptor(globalThis,key)]);
 for(const key of keys)Object.defineProperty(globalThis,key,{value:key==='IS_REACT_ACT_ENVIRONMENT'?true:window[key]??window,configurable:true,writable:true});
 let resolveSnapshot;
 const snapshotRequest=new Promise(resolve=>{resolveSnapshot=resolve;});
 const historyRequests=[];
 let failSnapshot=false;
 mockIPC(command=>{
  if(command==='read_modeltrace_snapshot')return failSnapshot?Promise.reject(new Error('快照读取失败')):snapshotRequest;
  if(command==='read_modeltrace_history')return new Promise((resolve,reject)=>historyRequests.push({resolve,reject}));
  return null;
 },{shouldMockEvents:true});
 try{await withSsrModules(async load=>{
  const {TokenActivitySection}=await load('/src/components/TokenActivitySection.tsx');
  const {createRoot}=await import('react-dom/client');
  const root=createRoot(window.document.body);
  const query=selector=>window.document.querySelector(selector);
  const switchMode=async name=>React.act(async()=>Array.from(window.document.querySelectorAll('.segmented--activity button')).find(button=>button.textContent===name).click());
  const checkStructure=()=>{
   assert.equal(window.document.querySelectorAll('.heatmap-cell').length,365);
   assert.ok(query('.heatmap-months'));
   assert.ok(query('.modeltrace-history-summary'));
   assert.ok(query('.modeltrace-records'));
  };
  try{
   await React.act(async()=>root.render(React.createElement(TokenActivitySection,{days:[]})));
   await switchMode('模型检测');
   checkStructure();
   assert.equal(query('.modeltrace-activity').getAttribute('aria-busy'),'true');
   assert.equal(query('[role=status]').textContent,'正在读取检测历史…');
   assert.equal(query('.modeltrace-record-count').textContent,'—');
   const stamp=Math.floor(Date.now()/1000);
   const run={id:'run',model:'gpt-5.6-sol',startedAt:stamp,completedAt:stamp,status:'candidate_matches',validSamples:3,attempts:3,attribution:null};
   await React.act(async()=>resolveSnapshot({scopeKey:'fixture',models:['gpt-5.6-sol'],plan:null,latest:run}));
   checkStructure();
   assert.equal(historyRequests.length,1);
   const grid=query('.heatmap-grid');
   await React.act(async()=>historyRequests.shift().resolve({scopeKey:'fixture',runs:[run],hasMore:false}));
   checkStructure();
   assert.equal(query('.heatmap-grid'),grid);
   assert.equal(query('.modeltrace-activity').getAttribute('aria-busy'),'false');
   assert.equal(query('.modeltrace-record-count').textContent,'1');
   assert.match(query('.modeltrace-history-summary').textContent,/1\/1 = 100.0%/);
   await switchMode('每日');
   await switchMode('模型检测');
   checkStructure();
   await React.act(async()=>historyRequests.shift().reject(new Error('历史读取失败')));
   checkStructure();
   assert.match(query('[role=alert]').textContent,/历史读取失败/);
   assert.equal(query('.modeltrace-record-count').textContent,'—');
   await switchMode('每日');
   failSnapshot=true;
   await switchMode('模型检测');
   checkStructure();
   assert.match(query('[role=alert]').textContent,/快照读取失败/);
   assert.equal(query('.modeltrace-activity').getAttribute('aria-busy'),'false');
  }finally{await React.act(async()=>root.unmount());}
 });}finally{
  clearMocks();
  for(const[key,descriptor]of previous)descriptor?Object.defineProperty(globalThis,key,descriptor):delete globalThis[key];
  window.close();
 }
});

test('history retries transient failures and discards retries from a previous scope', async () => {
 const window = new Window();
 const keys = ['window','document','navigator','Element','HTMLElement','IS_REACT_ACT_ENVIRONMENT'];
 const previous = keys.map(key => [key,Object.getOwnPropertyDescriptor(globalThis,key)]);
 for (const key of keys) Object.defineProperty(globalThis,key,{value:key==='IS_REACT_ACT_ENVIRONMENT'?true:window[key]??window,configurable:true,writable:true});
 const setTimeoutOriginal = globalThis.setTimeout;
 const clearTimeoutOriginal = globalThis.clearTimeout;
 const retries = new Map();
 globalThis.setTimeout = (callback, delay, ...args) => {
  if (delay !== 5000) return setTimeoutOriginal(callback, delay, ...args);
  const id = Symbol('history-retry'); retries.set(id, callback); return id;
 };
 globalThis.clearTimeout = id => {if (!retries.delete(id)) clearTimeoutOriginal(id);};
 const requests = [];
 let scope = 'account-a';
 mockIPC(command => {
  if (command === 'read_modeltrace_snapshot') return {scopeKey:scope, models:[], latest:null, plan:null};
  if (command === 'read_modeltrace_history') return new Promise((resolve,reject) => requests.push({resolve,reject}));
  return null;
 }, {shouldMockEvents:true});
 try {await withSsrModules(async load => {
  const {ModelTraceActivity} = await load('/src/modelTrace/ModelTraceActivity.tsx');
  const {createRoot} = await import('react-dom/client');
  const root = createRoot(window.document.body);
  const fireRetry = async () => {
   assert.equal(retries.size, 1);
   const [id, callback] = retries.entries().next().value;
   retries.delete(id);
   await React.act(async () => callback());
  };
  try {
   await React.act(async () => root.render(React.createElement(ModelTraceActivity)));
   assert.equal(requests.length, 1);
   const grid = window.document.querySelector('.heatmap-grid');
   await React.act(async () => requests.shift().reject(new Error('temporary database lock')));
   assert.match(window.document.querySelector('[role=alert]').textContent, /database lock/);
   await fireRetry();
   assert.equal(requests.length, 1);
   await React.act(async () => requests.shift().resolve({scopeKey:'account-a', runs:[], hasMore:false}));
   assert.equal(window.document.querySelector('[role=alert]'), null);
   assert.equal(window.document.querySelector('.heatmap-grid'), grid);
   assert.equal(retries.size, 0);
   // Start another request, fail it, and unmount with the retry still pending.
   await React.act(async () => root.render(null));
   await React.act(async () => root.render(React.createElement(ModelTraceActivity)));
   await React.act(async () => requests.shift().reject(new Error('retry pending')));
   assert.equal(retries.size, 1);
   await React.act(async () => root.render(null));
   assert.equal(retries.size, 0);
   // An in-flight response from the old component cannot populate a new account.
   await React.act(async () => root.render(React.createElement(ModelTraceActivity)));
   const stale = requests.shift();
   await React.act(async () => root.render(null));
   scope = 'account-b';
   await React.act(async () => root.render(React.createElement(ModelTraceActivity)));
   await React.act(async () => stale.reject(new Error('old account failure')));
   assert.equal(retries.size, 0);
   await React.act(async () => requests.shift().resolve({scopeKey:'account-b', runs:[], hasMore:false}));
   assert.equal(window.document.querySelector('[role=alert]'), null);
  } finally {await React.act(async () => root.unmount());}
 });} finally {
  globalThis.setTimeout = setTimeoutOriginal;
  globalThis.clearTimeout = clearTimeoutOriginal;
  clearMocks();
  for (const [key,descriptor] of previous) descriptor?Object.defineProperty(globalThis,key,descriptor):delete globalThis[key];
  window.close();
 }
});
