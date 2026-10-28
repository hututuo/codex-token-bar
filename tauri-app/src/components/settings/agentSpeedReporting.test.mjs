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

test('invitation offers an unchecked opt-in and local, silent, non-looping recording', async () => {
 await withSsrModules(async load => {
  const {AgentSpeedInvitationCard} = await load('/src/components/settings/AgentSpeedReporting.tsx');
  const html = renderToStaticMarkup(React.createElement(AgentSpeedInvitationCard,{username:'TokenBar-test',onJoin(){},onDismiss(){},onOpenSettings(){}}));
  const w = new Window(); w.document.body.innerHTML=html;
  const video=w.document.querySelector('video');
  assert.equal(video.getAttribute('src'),'/speed-leaderboard/leaderboard.mp4');
  assert.equal(video.hasAttribute('loop'),false);
  assert.equal(video.hasAttribute('muted'),true);
  assert.equal(w.document.querySelector('[role=switch]').checked,false);
  assert.equal([...w.document.querySelectorAll('button')].find(b=>b.textContent==='开启并参加').disabled,true);
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
