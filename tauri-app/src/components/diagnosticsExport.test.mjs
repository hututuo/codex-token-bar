import assert from "node:assert/strict";
import test from "node:test";
import React,{act} from "react";
import {createRoot} from "react-dom/client";
import {Window} from "happy-dom";
import {withSsrModules} from "../test/ssrHarness.mjs";

test("diagnostic export works without a ready business owner and failure does not leak native errors",async()=>{
 const w=new Window(),prior={window:globalThis.window,document:globalThis.document,IS_REACT_ACT_ENVIRONMENT:globalThis.IS_REACT_ACT_ENVIRONMENT};
 Object.assign(globalThis,{window:w,document:w.document,IS_REACT_ACT_ENVIRONMENT:true});
 let calls=[];let fail=false;
 w.__TAURI_INTERNALS__={invoke:async(command,args)=>{calls.push({command,args});if(fail)throw new Error("Bearer SECRET /Users/private/chat");return "Downloads/TokenBar-Diagnostics.zip";}};
 try{await withSsrModules(async load=>{
  const {DiagnosticsExportButton}=await load("/src/components/DiagnosticsExportButton.tsx");
  const host=w.document.createElement("div"),root=createRoot(host);w.document.body.append(host);
  try{
   await act(async()=>root.render(React.createElement(DiagnosticsExportButton)));
   assert.equal(calls.length,0);
   await act(async()=>host.querySelector("button").click());
   assert.deepEqual(calls.map(c=>c.command),["export_diagnostics"]);
   assert.match(host.textContent,/诊断包已保存/);
   fail=true;await act(async()=>host.querySelector("button").click());
   assert.match(host.textContent,/独立诊断工具/);assert.doesNotMatch(host.textContent,/SECRET|private|Bearer/);
   assert.equal(host.querySelector("button").disabled,false);
  }finally{await act(async()=>root.unmount());}
 });}finally{Object.assign(globalThis,prior);await w.happyDOM.abort();}
});

test("UI progress diagnostics transmit counts only and ignore transport failures",async()=>{
 const w=new Window(),old=globalThis.window;globalThis.window=w;const calls=[];
 w.__TAURI_INTERNALS__={invoke:async(command,args)=>{calls.push({command,args});throw new Error("offline");}};
 try{await withSsrModules(async load=>{
  const {recordDiagnosticProgress}=await load("/src/diagnostics/supportDiagnostics.ts");
  recordDiagnosticProgress({completed:12,total:40,phase:"scanning",message:"SECRET",path:"/Users/private"});
  await Promise.resolve();
  assert.deepEqual(calls,[{command:"record_diagnostic_progress",args:{completed:12,total:40,finished:false,failed:false}}]);
 });}finally{globalThis.window=old;await w.happyDOM.abort();}
});
