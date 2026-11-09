import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import {Window} from "happy-dom";
import {withSsrModules} from "../test/ssrHarness.mjs";

test("real runtime hook rejects replies from a changed source and releases the last polling subscriber",async()=>{
 const dom=new Window({url:"http://localhost/"});
 const keys=["window","document","navigator","HTMLElement","IS_REACT_ACT_ENVIRONMENT"];
 const previous=keys.map(key=>[key,Object.getOwnPropertyDescriptor(globalThis,key)]);
 for(const key of keys)Object.defineProperty(globalThis,key,{configurable:true,writable:true,value:key==="IS_REACT_ACT_ENVIRONMENT"?true:dom[key]});
 const oldSet=globalThis.setTimeout,oldClear=globalThis.clearTimeout,timers=new Map();let serial=0;
 globalThis.setTimeout=(fn,ms)=>{const id=++serial;timers.set(id,{fn,ms});return id;};globalThis.clearTimeout=id=>timers.delete(id);
 let path="A",pending=[],model="";const preference=()=>({client:"claudeCode",enabled:true,path});
 dom.__TAURI_EVENT_PLUGIN_INTERNALS__={unregisterListener(){}};
 dom.__TAURI_INTERNALS__={invoke:async command=>{
  if(command==="refresh_multi_client_usage")return {preferences:[preference()],summaries:[],diagnostics:[],updatedAt:new Date().toISOString()};
  if(command==="read_claude_local_runtime_snapshot")return new Promise(resolve=>pending.push(resolve));
  if(command==="read_activity_speed_mode")return "bar";
  if(command.includes("listen"))return 1;
  return null;
 },transformCallback:()=>1,unregisterCallback(){}};
 let root;
 try{
  const {createRoot}=await import("react-dom/client");root=createRoot(dom.document.body);
  await withSsrModules(async load=>{
   const {useClaudeLocalRuntime}=await load("/src/multiClient/ClaudeLocalRuntime.tsx");
   function Probe(){const value=useClaudeLocalRuntime(["claudeCode"]);model=value.mainAgents.map(row=>row.model).join();return React.createElement("span",null,model);}
   // Refresh the exact module instance imported by the runtime via its shared
   // scheduled reader; changing the response updates the configuration key.
   const fire=async ms=>{for(const [id,timer]of [...timers])if(timer.ms===ms){timers.delete(id);timer.fn();}await Promise.resolve();};
   await React.act(async()=>root.render(React.createElement(Probe)));
   await React.act(async()=>fire(2000));
   assert.ok(pending.length>0);
   const payload=name=>({enabled:true,capturedAt:new Date().toISOString(),sourceAvailable:{claudeCode:true},modelRates:[],liveOutputTps:0,liveTotalTps:0,estimatedShare:0,subagents:[],latestResponse:null,configurationIssue:null,
    mainAgents:[{id:"task",client:"claudeCode",parentId:null,phase:"generating",model:name,lastActivity:new Date().toISOString(),liveOutputTps:1,liveTotalTps:1,recentSpeed:null}]});
   // Settle startup requests before testing an in-flight source switch.
   await React.act(async()=>{for(const resolve of pending.splice(0))resolve(payload("A"));});
   await React.act(async()=>fire(2000));
   const old=pending.shift();assert.ok(old);
   path="B";await React.act(async()=>fire(60000));
   await React.act(async()=>old(payload("OLD_A")));
   assert.doesNotMatch(dom.document.body.textContent,/OLD_A/);
   await React.act(async()=>fire(2000));
   await React.act(async()=>{for(const resolve of pending.splice(0))resolve(payload("NEW_B"));});
   assert.match(dom.document.body.textContent,/NEW_B/);
   await React.act(async()=>root.unmount());root=null;
   assert.equal([...timers.values()].filter(timer=>timer.ms===2000).length,0);
  });
 }finally{
  if(root)await React.act(async()=>root.unmount());
  globalThis.setTimeout=oldSet;globalThis.clearTimeout=oldClear;
  for(const[key,descriptor]of previous)descriptor?Object.defineProperty(globalThis,key,descriptor):delete globalThis[key];dom.close();
 }
});
