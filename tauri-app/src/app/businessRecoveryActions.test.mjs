import assert from "node:assert/strict";
import test from "node:test";
import React, {act} from "react";
import {createRoot} from "react-dom/client";
import {Window} from "happy-dom";
import {withSsrModules} from "../test/ssrHarness.mjs";

async function harness(run,{label="main",check,listenFailure=false}={}) {
  const w=new Window({url:"http://localhost/"}), descriptors=new Map(), calls=[];
  for(const [key,value] of Object.entries({window:w,document:w.document,navigator:w.navigator,
    IS_REACT_ACT_ENVIRONMENT:true})) {
    descriptors.set(key,Object.getOwnPropertyDescriptor(globalThis,key));
    Object.defineProperty(globalThis,key,{value,writable:true,configurable:true});
  }
  w.confirm=()=>true;
  let owners=0;
  w.__TAURI_EVENT_PLUGIN_INTERNALS__={unregisterListener(){}};
  w.__TAURI_INTERNALS__={metadata:{currentWindow:{label},currentWebview:{label}},transformCallback(){return 1;},invoke:async(command,args)=>{
    calls.push([command,args]);
    if(command==="plugin:event|listen") { if(listenFailure)throw Error("event unavailable");return 1; }
    if(command==="plugin:event|unlisten"||command==="record_startup_event")return;
    if(command==="read_business_startup_state")return {phase:"error",message:"schema needs repair"};
    if(command==="read_business_migration_diagnostics")return {attemptId:"attempt",path:"/isolated/log",persistenceError:null,totalEvents:1234,preview:['{"stage":"proof","status":"failed"}']};
    if(command==="check_app_update")return check?await check():{status:"available",message:"repair available",version:"0.9.12",body:"",date:null,revision:2};
    if(command==="install_app_update")return "started";
    if(command==="export_business_migration_diagnostics")return {path:"/isolated/TokenBar_migration.zip",revealError:null};
    if(command==="retry_business_startup")return {phase:"ready",message:null};
    throw Error(`Unexpected ${command}`);
  }};
  const host=w.document.createElement("div");w.document.body.append(host);const root=createRoot(host);
  try {await withSsrModules(async load=>{
    const {BusinessStartupGate}=await load("/src/app/BusinessStartupGate.tsx");
    function Owner(){owners++;return React.createElement("div",null,"ready-owner");}
    await act(async()=>root.render(React.createElement(BusinessStartupGate,null,React.createElement(Owner))));
    await run({host,calls,get owners(){return owners;},async click(text){
      const button=[...host.querySelectorAll("button")].find(b=>b.textContent.includes(text));
      assert.ok(button,`missing ${text}`);await act(async()=>button.click());
    }});
  });} finally {
    await act(async()=>root.unmount());await w.happyDOM.abort();
    for(const [key,descriptor] of descriptors) {if(descriptor)Object.defineProperty(globalThis,key,descriptor);else delete globalThis[key];}
  }
}

test("failed startup can export and invoke native update while all business owners remain blocked",async()=>{
  await harness(async h=>{
    assert.equal(h.owners,0);assert.match(h.host.textContent,/schema needs repair/);
    assert.match(h.host.textContent,/1 \/ 1234/);
    await h.click("导出完整迁移日志");assert.match(h.host.textContent,/TokenBar_migration.zip/);
    await h.click("检查软件更新");await h.click("下载并安装");
    assert.ok(h.calls.some(([cmd])=>cmd==="install_app_update"));assert.equal(h.owners,0);
    const retry=[...h.host.querySelectorAll("button")].find(b=>b.textContent.includes("重试"));
    assert.equal(retry.disabled,true,"do not begin database writes after installer takeover");
  },{listenFailure:true});
});

test("failed update check remains an error, then explicit retry alone activates business owners",async()=>{
  await harness(async h=>{
    await h.click("检查软件更新");assert.match(h.host.textContent,/update network error/);
    assert.doesNotMatch(h.host.textContent,/已是最新版/);
    assert.ok(![...h.host.querySelectorAll("button")].some(b=>b.textContent.includes("下载并安装")));
    await h.click("重试账本准备");assert.equal(h.owners,1);
  },{check:async()=>({status:"error",message:"update network error",version:null,revision:4})});
});

test("secondary surfaces do not issue main-window repair or diagnostic commands",async()=>{
  await harness(async h=>{
    assert.match(h.host.textContent,/主窗口/);
    assert.equal(h.host.querySelectorAll("button").length,0);
    assert.ok(!h.calls.some(([cmd])=>cmd==="read_business_migration_diagnostics"));assert.equal(h.owners,0);
  },{label:"quota-sidebar"});
});
