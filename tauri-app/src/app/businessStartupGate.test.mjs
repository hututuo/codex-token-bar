import assert from "node:assert/strict";
import test from "node:test";
import React, {act} from "react";
import {createRoot} from "react-dom/client";
import {Window} from "happy-dom";
import {withSsrModules} from "../test/ssrHarness.mjs";

const surfaces = ["main", "floating", "status", "quota-sidebar", "quota-sidebar-detail", "floating-guide-card", "floating-guide-cursor"];

test("a window opened after startup is ready mounts without waiting for a new broadcast", async () => {
 for (const surface of surfaces) {
  await withGate(surface, () => ({phase:"ready",message:null}), async ({host,calls,owners}) => {
   assert.match(host.textContent,/owner-ready/);
   assert.equal(owners(),1,surface);
   assert.deepEqual(calls,["read_business_startup_state"]);
  });
 }
});

test("failed startup in child windows opens the main window without retrying the ledger", async () => {
 for (const surface of surfaces.filter(surface => surface !== "main")) {
  await withGate(surface, () => ({phase:"error",message:"fixture bootstrap failure"}), async ({host,calls,owners,click}) => {
   assert.match(host.textContent,/账本准备未完成/);
   await click("打开主窗口重试");
   assert.deepEqual(calls,["read_business_startup_state","show_dashboard_window"],surface);
   assert.equal(owners(),0);
  });
 }
});

test("verified published recovery mounts every surface and only the main window offers a retry",async()=>{
 for(const surface of surfaces) {
  await withGate(surface,()=>({phase:"ready_with_pending_recovery",message:"fixture pending source"}),async({host,calls,owners,click})=>{
   assert.match(host.textContent,/owner-ready/);
   assert.equal(owners(),1,surface);
   if(surface === "main") {
    assert.match(host.textContent,/旧账可读/);
    await click("重试恢复");
    assert.deepEqual(calls,["read_business_startup_state","retry_business_startup"]);
    assert.match(host.textContent,/owner-ready/);
    assert.equal(owners(),1,"A local recovery retry cannot reconstruct business owners");
   } else assert.doesNotMatch(host.textContent,/重试恢复/);
  });
 }
});

test("a failed recovery status read retains the already admitted published surface",async()=>{
 await withGate("main",command=>{
  if(command === "retry_business_startup") throw new Error("fixture transport unavailable");
  return {phase:"ready_with_pending_recovery",message:"pending"};
 },async({host,owners,click})=>{
  await click("重试恢复");
  assert.match(host.textContent,/owner-ready/);
  assert.match(host.textContent,/fixture transport unavailable/);
  assert.equal(owners(),1);
 });
});

test("only the main window retries an actual failed bootstrap", async () => {
 await withGate("main", command => command === "retry_business_startup"
  ? {phase:"ready",message:null}
  : {phase:"error",message:"fixture bootstrap failure"}, async ({host,calls,owners,click}) => {
  await click("重试");
  assert.deepEqual(calls,["read_business_startup_state","retry_business_startup"]);
  assert.equal(owners(),1);
  assert.match(host.textContent,/owner-ready/);
 });
});

test("a startup status query failure retries the read instead of restarting the ledger", async () => {
 for (const surface of surfaces) {
  let reads=0;
  await withGate(surface, command => {
   assert.equal(command,"read_business_startup_state");
   if (++reads === 1) throw new Error("fixture status transport unavailable");
   return {phase:"ready",message:null};
  }, async ({host,calls,owners,click}) => {
   assert.match(host.textContent,/无法读取账本准备状态/);
   assert.doesNotMatch(host.textContent,/账本准备未完成|暂停业务写入/);
   assert.equal(owners(),0);
   await click("重新读取");
   assert.deepEqual(calls,["read_business_startup_state","read_business_startup_state"],surface);
   assert.equal(owners(),1);
  });
 }
});

test("a late status rejection cannot replace a newer ready broadcast", async () => {
 let rejectRead;
 await withGate("quota-sidebar-detail", () => new Promise((_resolve,reject) => {rejectRead=reject;}), async ({host,owners,send}) => {
  assert.equal(owners(),0);
  await send({phase:"ready",message:null});
  assert.equal(owners(),1);
  await act(async()=>rejectRead(new Error("stale fixture transport failure")));
  assert.match(host.textContent,/owner-ready/);
  assert.doesNotMatch(host.textContent,/stale fixture|账本准备/);
 });
});

async function withGate(surface, response, callback) {
 const w=new Window({url:`http://localhost/?surface=${surface}`});
 const prior={window:globalThis.window,document:globalThis.document,IS_REACT_ACT_ENVIRONMENT:globalThis.IS_REACT_ACT_ENVIRONMENT};
 globalThis.window=w;globalThis.document=w.document;globalThis.IS_REACT_ACT_ENVIRONMENT=true;
 const callbacks=new Map();let callbackId=0,listener;const calls=[];let ownerCount=0,root;
 w.__TAURI_EVENT_PLUGIN_INTERNALS__={unregisterListener(){}};
 w.__TAURI_INTERNALS__={metadata:{currentWindow:{label:surface},currentWebview:{label:surface}},transformCallback(callback){callbacks.set(++callbackId,callback);return callbackId;},invoke:async(command,args)=>{
  if(command==='plugin:event|listen'){assert.equal(args.event,"business-startup-state-changed");listener=callbacks.get(args.handler);return 1;}
  if(command==='plugin:event|unlisten')return;
  if(command==='record_diagnostic_progress') {
    assert.deepEqual(Object.keys(args).sort(),["completed","failed","finished","total"]);
    assert.equal(typeof args.completed,"number");return;
  }
  calls.push(command);
  if(command==='show_dashboard_window')return;
  if(command==='retry_business_startup' && surface !== 'main')throw new Error(`retry_business_startup is not available from the ${surface} window`);
  return await response(command);
 }};
 try {
  await withSsrModules(async load=>{
   const {BusinessStartupGate}=await load("/src/app/BusinessStartupGate.tsx");
   const host=w.document.createElement("div");w.document.body.append(host);root=createRoot(host);
   function Owner(){ownerCount++;return React.createElement("div",null,"owner-ready");}
   await act(async()=>root.render(React.createElement(BusinessStartupGate,null,React.createElement(Owner))));
   await callback({host,calls,owners:()=>ownerCount,click:async label=>{
    const button=[...host.querySelectorAll('button')].find(button=>button.textContent===label);
    assert.ok(button,`Missing ${label} action from ${surface}: ${host.textContent}`);
    await act(async()=>button.click());
   },send:async payload=>{assert.ok(listener);await act(async()=>listener({event:"business-startup-state-changed",id:1,payload}));}});
  });
 } finally {
  if(root)await act(async()=>root.unmount());
  Object.assign(globalThis,prior);await w.happyDOM.abort();
 }
}

test("startup renders a visible gate before mounting dashboard owners",async()=>{
 const w=new Window();
 const prior={window:globalThis.window,document:globalThis.document,IS_REACT_ACT_ENVIRONMENT:globalThis.IS_REACT_ACT_ENVIRONMENT};
 globalThis.window=w;globalThis.document=w.document;globalThis.IS_REACT_ACT_ENVIRONMENT=true;
 let resolveState;let reads=0;let owners=0;
 w.__TAURI_EVENT_PLUGIN_INTERNALS__={unregisterListener(){}};
 w.__TAURI_INTERNALS__={transformCallback(){return 1;},invoke:async command=>{
  if(command==='plugin:event|listen')return 1;
  if(command==='plugin:event|unlisten')return;
  assert.equal(command,"read_business_startup_state"); reads+=1;
  return await new Promise(resolve=>{resolveState=resolve;});
 }};
 let root;
 try {
  await withSsrModules(async load=>{
   const {BusinessStartupGate}=await load("/src/app/BusinessStartupGate.tsx");
   const host=w.document.createElement("div");w.document.body.append(host);root=createRoot(host);
   function Owner(){owners+=1;return React.createElement("div",null,"dashboard-ready");}
   await act(async()=>root.render(React.createElement(BusinessStartupGate,null,React.createElement(Owner))));
   assert.equal(owners,0);assert.equal(reads,1);assert.match(host.textContent,/准备本地账本/);
   await act(async()=>resolveState({phase:"ready",message:null}));
   assert.equal(owners,1);assert.match(host.textContent,/dashboard-ready/);assert.doesNotMatch(host.textContent,/准备本地账本/);
  });
 } finally {
  if(root)await act(async()=>root.unmount());
  Object.assign(globalThis,prior);await w.happyDOM.abort();
 }
});
