import assert from 'node:assert/strict';
import test from 'node:test';
import React from 'react';
import {renderToStaticMarkup} from 'react-dom/server';
import {withSsrModules} from '../../test/ssrHarness.mjs';
import {Window} from 'happy-dom';
import {act} from 'react';
import {createRoot} from 'react-dom/client';

test('dashboard shows enabled reporting failures and hides disabled reporting',async()=>{
 await withSsrModules(async load=>{
  const {AgentSpeedReportingNotice}=await load('/src/components/settings/AgentSpeedReporting.tsx');
  const status={enabled:false,phase:'off',message:'未开启',lastReportAt:null};
  const render=s=>renderToStaticMarkup(React.createElement(AgentSpeedReportingNotice,{status:s,onRetry(){},onOpenSettings(){}}));
  assert.equal(render(status),'');
  const failure=render({...status,enabled:true,phase:'error',message:'连接失败或超时，请检查代理'});
  assert.match(failure,/role="alert"/);assert.match(failure,/连接失败或超时/);assert.match(failure,/重试连接/);assert.match(failure,/设置/);
  const running=render({...status,enabled:true,phase:'running',message:'已连接',lastReportAt:'2026-10-28T01:00:00Z'});
  assert.match(running,/最近上报/);assert.doesNotMatch(running,/重试连接/);
 });
});

test('dashboard and settings share one status read subscription',async()=>{
 const w=new Window();const prior={window:globalThis.window,document:globalThis.document,IS_REACT_ACT_ENVIRONMENT:globalThis.IS_REACT_ACT_ENVIRONMENT};
 globalThis.window=w;globalThis.document=w.document;globalThis.IS_REACT_ACT_ENVIRONMENT=true;
 let reads=0;let resolveStatus;let root;
 w.__TAURI_INTERNALS__={invoke:async command=>{
  assert.equal(command,'read_agent_speed_reporting_status');reads+=1;
  return await new Promise(resolve=>{resolveStatus=resolve;});
 }};
 try {
  await withSsrModules(async load=>{
   const {AgentSpeedReportingDashboardStatus,AgentSpeedReportingSettings}=await load('/src/components/settings/AgentSpeedReporting.tsx');
   const host=w.document.createElement('div');w.document.body.append(host);root=createRoot(host);
   await act(async()=>root.render(React.createElement(React.Fragment,null,React.createElement(AgentSpeedReportingDashboardStatus,{onOpenSettings(){}}),React.createElement(AgentSpeedReportingSettings))));
   assert.equal(reads,1);
   await act(async()=>resolveStatus({enabled:true,username:'test-name',phase:'error',message:'连接失败或超时',lastReportAt:null,profileUrl:null,sources:[],liveOutputTps:0,estimatedShare:0,invitationHandled:true}));
   assert.match(host.querySelector('[role=alert]').textContent,/连接失败或超时/);assert.equal(reads,1);
  });
 } finally {if(root)await act(async()=>root.unmount());Object.assign(globalThis,prior);await w.happyDOM.abort();}
});

test('invitation offers an unchecked opt-in and local, silent, looping recording', async () => {
 await withSsrModules(async load => {
  const {AgentSpeedInvitationCard} = await load('/src/components/settings/AgentSpeedReporting.tsx');
  const html = renderToStaticMarkup(React.createElement(AgentSpeedInvitationCard,{username:'TokenBar-test',onJoin(){},onDismiss(){},onOpenSettings(){}}));
  const w = new Window(); w.document.body.innerHTML=html;
  const video=w.document.querySelector('video');
  assert.equal(video.getAttribute('src'),'/speed-leaderboard/leaderboard.mp4');
  assert.equal(video.hasAttribute('loop'),true);
  assert.equal(video.hasAttribute('muted'),true);
  assert.equal(w.document.querySelector('[role=switch]').checked,false);
  assert.equal([...w.document.querySelectorAll('button')].find(b=>b.textContent==='同意参加，下一步').disabled,true);
  assert.match(html,/不上传对话内容、文件路径或账号凭据/);
  assert.match(html,/公开昵称、设备标识/);
  assert.match(html,/非当前实时数据/);
  w.happyDOM.abort();
 });
});

test('profile URL accepts only the reporting website, and supported source list includes all 13 harnesses',async()=>{
 await withSsrModules(async load=>{
  const {safeSpeedProfile,supportedHarnesses}=await load('/src/components/settings/AgentSpeedReporting.tsx');
  assert.equal(safeSpeedProfile('https://deng.codexradar.com/profile/a'),'https://deng.codexradar.com/profile/a');
  for(const url of ['javascript:alert(1)','http://deng.codexradar.com','https://deng.codexradar.com.evil.test','https://user@deng.codexradar.com']) assert.equal(safeSpeedProfile(url),null);
  assert.equal(supportedHarnesses.split('、').length,13);
 });
});

test('consent keeps layout stable and opens nickname page before final opt-in',async()=>{
 const w=new Window();const keys=['window','document','navigator','HTMLElement','IS_REACT_ACT_ENVIRONMENT'];
 const saved=keys.map(k=>[k,Object.getOwnPropertyDescriptor(globalThis,k)]);
 for(const k of keys)Object.defineProperty(globalThis,k,{configurable:true,writable:true,value:k==='IS_REACT_ACT_ENVIRONMENT'?true:w[k]});
 let root,joined=[];
 try{
  w.HTMLMediaElement.prototype.play=()=>Promise.resolve();w.HTMLMediaElement.prototype.pause=()=>{};
  const {createRoot}=await import('react-dom/client');root=createRoot(w.document.body);
  await withSsrModules(async load=>{
   const {AgentSpeedInvitationCard}=await load('/src/components/settings/AgentSpeedReporting.tsx');
   await React.act(async()=>root.render(React.createElement(AgentSpeedInvitationCard,{username:'测试昵称',onJoin:name=>joined.push(name),onDismiss(){},onOpenSettings(){}})));
   const checkbox=w.document.querySelector('[role=switch]'),button=w.document.querySelector('.speed-report-primary'),name=w.document.querySelector('.speed-report-public-name'),hint=w.document.querySelector('.speed-report-join-hint');
   assert.ok(button.disabled);assert.equal(checkbox.getAttribute('aria-describedby'),hint.id);assert.match(hint.textContent,/先打开上方开关/);
   await React.act(async()=>button.click());assert.equal(joined.length,0);
   await React.act(async()=>checkbox.click());assert.equal(button.disabled,false);assert.match(hint.textContent,/下一步填写/);
   assert.equal(w.document.querySelector('.speed-report-public-name'),name);
   await React.act(async()=>checkbox.click());assert.equal(button.disabled,true);assert.equal(w.document.querySelector('.speed-report-public-name'),name);assert.equal(w.document.querySelector('.speed-report-join-hint'),hint);
   await React.act(async()=>checkbox.click());await React.act(async()=>button.click());assert.equal(joined.length,0);
   assert.equal(w.document.querySelector('video'),null);assert.equal(w.document.querySelector('input[placeholder="请输入您的昵称"]').value,'测试昵称');
   await React.act(async()=>w.document.querySelector('.speed-report-primary').click());assert.deepEqual(joined,['测试昵称']);
  });
 }finally{if(root)await React.act(async()=>root.unmount());for(const[k,v]of saved)v?Object.defineProperty(globalThis,k,v):delete globalThis[k];w.close();}
});

test('movie autoplays, resumes after hiding, and preserves manual pause and reduced motion',async()=>{
 const w=new Window();const keys=['window','document','navigator','HTMLElement','IS_REACT_ACT_ENVIRONMENT'];
 const saved=keys.map(k=>[k,Object.getOwnPropertyDescriptor(globalThis,k)]);
 for(const k of keys)Object.defineProperty(globalThis,k,{configurable:true,writable:true,value:k==='IS_REACT_ACT_ENVIRONMENT'?true:w[k]});
 let root,plays=0,hidden=false;
 const motion=new w.EventTarget();motion.matches=false;w.matchMedia=()=>motion;
 Object.defineProperty(w.document,'hidden',{configurable:true,get:()=>hidden});
 w.HTMLMediaElement.prototype.play=function(){plays++;this.dispatchEvent(new w.Event('play'));return Promise.resolve();};
 w.HTMLMediaElement.prototype.pause=function(){this.dispatchEvent(new w.Event('pause'));};
 const visibility=async value=>{hidden=value;await React.act(async()=>w.document.dispatchEvent(new w.Event('visibilitychange')));};
 try{
  const {createRoot}=await import('react-dom/client');root=createRoot(w.document.body);
  await withSsrModules(async load=>{
   const {SpeedLeaderboardMovie}=await load('/src/components/settings/AgentSpeedReporting.tsx');
   await React.act(async()=>root.render(React.createElement(SpeedLeaderboardMovie)));
   assert.equal(plays,1);assert.equal(w.document.querySelector('video').loop,true);
   await visibility(true);assert.match(w.document.querySelector('button').getAttribute('aria-label'),/播放/);
   await visibility(false);assert.equal(plays,2);
   await React.act(async()=>w.document.querySelector('button').click());
   await visibility(true);await visibility(false);assert.equal(plays,2,'manual pause must survive visibility changes');
   await React.act(async()=>w.document.querySelector('button').click());assert.equal(plays,3);
   await React.act(async()=>root.unmount());root=null;
   await visibility(true);await visibility(false);assert.equal(plays,3,'unmounted movie removes its listeners');
   motion.matches=true;root=createRoot(w.document.body);
   await React.act(async()=>root.render(React.createElement(SpeedLeaderboardMovie)));assert.equal(plays,3);
   motion.matches=false;await React.act(async()=>motion.dispatchEvent(new w.Event('change')));assert.equal(plays,4);
  });
 }finally{if(root)await React.act(async()=>root.unmount());for(const[k,v]of saved)v?Object.defineProperty(globalThis,k,v):delete globalThis[k];w.close();}
});

test('compact header status is green only after a confirmed report and retains visible errors',async()=>withSsrModules(async load=>{
 const {AgentSpeedReportingNotice}=await load('/src/components/settings/AgentSpeedReporting.tsx');
 const base={enabled:true,phase:'running',message:'已上报',lastReportAt:'2026-10-28T09:17:23Z'};
 const render=(status,extra={})=>renderToStaticMarkup(React.createElement(AgentSpeedReportingNotice,{status,compact:true,onRetry(){},onOpenSettings(){},...extra}));
 assert.match(render(base),/data-state="reporting"/);assert.match(render(base),/正在上报/);
 for(const lastReportAt of [null,undefined,'not-a-time']){const html=render({...base,lastReportAt});assert.match(html,/data-state="connecting"/);assert.doesNotMatch(html,/正在上报/);}
 assert.match(render({...base,phase:'error'}),/上报异常/);
 assert.equal(render({...base,enabled:false}),'');
 assert.equal(render(base,{errorsOnly:true}),'');
 const failure=render({...base,phase:'error',message:'连接超时，请检查网络'},{compact:false,errorsOnly:true});
 assert.match(failure,/role="alert"/);assert.match(failure,/连接超时/);assert.match(failure,/重试连接/);
}));
