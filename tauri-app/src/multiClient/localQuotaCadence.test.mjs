import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import {createRoot} from "react-dom/client";
import {Window} from "happy-dom";
import {withSsrModules} from "../test/ssrHarness.mjs";

test("shared local quotas follow the main cadence, keep usage independent, and reject stale timing and snapshot replies",async()=>{
  const dom=new Window({url:"http://localhost/"});
  const keys=["window","document","navigator","HTMLElement","IS_REACT_ACT_ENVIRONMENT"];
  const prior=keys.map(key=>[key,Object.getOwnPropertyDescriptor(globalThis,key)]);
  for(const key of keys)Object.defineProperty(globalThis,key,{configurable:true,writable:true,value:key==="IS_REACT_ACT_ENVIRONMENT"?true:dom[key]});
  const oldSet=globalThis.setTimeout,oldClear=globalThis.clearTimeout,timers=new Map();let serial=0;
  globalThis.setTimeout=(fn,ms)=>{const id=++serial;timers.set(id,{fn,ms});return id;};
  globalThis.clearTimeout=id=>timers.delete(id);
  let resolveSettings,resolveUsage,holdUsage=false,usageReads=0,quotaReads=0,settingsListener,unlistens=0,root,platform,oldListen;
  const calls=[];
  const quota=value=>[{client:"claudeDesktop",state:"available",source:"local-desktop-http-cache",windows:[{label:"5h",usedPercent:value,resetsAt:null}]}];
  const snapshot=()=>({preferences:[],summaries:[],diagnostics:[],updatedAt:null,quotas:quota(5)});
  const settings=new Promise(resolve=>{resolveSettings=resolve;});
  dom.__TAURI_INTERNALS__={invoke:async(command,args)=>{
    calls.push({command,args});
    if(command==="read_app_settings")return settings;
    if(command==="refresh_multi_client_usage"){
      usageReads++;
      return holdUsage?new Promise(resolve=>{resolveUsage=resolve;}):snapshot();
    }
    assert.equal(command,"read_local_client_quotas");quotaReads++;
    return quota(40+quotaReads);
  }};
  const fire=async ms=>{
    for(const[id,timer]of [...timers])if(timer.ms===ms){timers.delete(id);void timer.fn();}
    await Promise.resolve();
  };
  try{
    await withSsrModules(async load=>{
      ({desktopPlatform:platform}=await load("/src/platform/desktop.ts"));
      oldListen=platform.onAppSettingsChanged;
      platform.onAppSettingsChanged=async listener=>{settingsListener=listener;return()=>{unlistens++;};};
      const {useMultiClientUsage,refreshLocalClientQuotas}=await load("/src/multiClient/MultiClientUsage.tsx");
      function Probe(){const{snapshot}=useMultiClientUsage();return React.createElement("span",null,JSON.stringify(snapshot.quotas??[]));}
      root=createRoot(dom.document.body);
      await React.act(async()=>root.render(React.createElement(React.Fragment,null,React.createElement(Probe),React.createElement(Probe))));
      assert.equal(usageReads,1,"subscribers share one usage poll");
      assert.equal([...timers.values()].filter(t=>t.ms===60_000).length,2,"usage and quota have distinct clocks");

      await React.act(async()=>settingsListener({quotaRefreshIntervalMs:30_000}));
      await React.act(async()=>resolveSettings({quotaRefreshIntervalMs:600_000}));
      assert.equal([...timers.values()].filter(t=>t.ms===30_000).length,1);
      assert.equal([...timers.values()].filter(t=>t.ms===600_000).length,0,"late startup settings cannot replace a newer selection");
      await React.act(async()=>fire(30_000));
      assert.equal(quotaReads,1);assert.equal(usageReads,1,"quota timing must not rescan transcripts");
      assert.match(dom.document.body.textContent,/"usedPercent":41/);

      await React.act(async()=>settingsListener({quotaRefreshIntervalMs:600_000}));
      assert.equal([...timers.values()].filter(t=>t.ms===30_000).length,0);
      holdUsage=true;
      await React.act(async()=>fire(60_000));
      assert.equal(usageReads,2);
      await React.act(async()=>fire(600_000));
      assert.equal(quotaReads,2,"a pending usage scan cannot block an independent quota read");
      assert.match(dom.document.body.textContent,/"usedPercent":42/);
      await React.act(async()=>resolveUsage(snapshot()));
      assert.match(dom.document.body.textContent,/"usedPercent":42/,"late usage results cannot restore an older quota");

      await React.act(async()=>refreshLocalClientQuotas(true));
      assert.equal(quotaReads,3);assert.equal(calls.at(-1).args.forceRefresh,true);
      assert.equal(usageReads,2,"manual quota rereading is also independent of ingestion");
      const timerId=[...timers].find(([,t])=>t.ms===600_000)?.[0];
      await React.act(async()=>settingsListener({quotaRefreshIntervalMs:600_000,filterQuotaHistoryAnomalies:false}));
      assert.ok(timers.has(timerId),"unrelated settings must not restart the quota clock");
      await React.act(async()=>root.unmount());root=null;
      assert.equal([...timers.values()].filter(t=>[30_000,60_000,600_000].includes(t.ms)).length,0);
      assert.equal(unlistens,1);
    });
  }finally{
    if(root)await React.act(async()=>root.unmount());
    if(platform&&oldListen)platform.onAppSettingsChanged=oldListen;
    globalThis.setTimeout=oldSet;globalThis.clearTimeout=oldClear;
    for(const[key,descriptor]of prior)descriptor?Object.defineProperty(globalThis,key,descriptor):delete globalThis[key];
    dom.close();
  }
});
