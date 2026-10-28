import assert from "node:assert/strict";
import test from "node:test";
import React, {act} from "react";
import {createRoot} from "react-dom/client";
import {Window} from "happy-dom";
import {withSsrModules} from "../test/ssrHarness.mjs";

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
