import assert from 'node:assert/strict';
import test from 'node:test';
import React from 'react';
import {renderToStaticMarkup} from 'react-dom/server';
import {withSsrModules} from '../../test/ssrHarness.mjs';
import {Window} from 'happy-dom';

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

test('invitation clearly explains the two-step consent and keeps its name/hint slots mounted on toggle',async()=>{
 const w=new Window();const keys=['window','document','navigator','HTMLElement','IS_REACT_ACT_ENVIRONMENT'];
 const saved=keys.map(k=>[k,Object.getOwnPropertyDescriptor(globalThis,k)]);
 for(const k of keys)Object.defineProperty(globalThis,k,{configurable:true,writable:true,value:k==='IS_REACT_ACT_ENVIRONMENT'?true:w[k]});
 let root,joined=0;
 try{
  w.HTMLMediaElement.prototype.play=()=>Promise.resolve();w.HTMLMediaElement.prototype.pause=()=>{};
  const {createRoot}=await import('react-dom/client');root=createRoot(w.document.body);
  await withSsrModules(async load=>{
   const {AgentSpeedInvitationCard}=await load('/src/components/settings/AgentSpeedReporting.tsx');
   await React.act(async()=>root.render(React.createElement(AgentSpeedInvitationCard,{username:'TokenBar-test',onJoin:()=>joined++,onDismiss(){},onOpenSettings(){}})));
   const checkbox=w.document.querySelector('[role=switch]'),button=w.document.querySelector('.speed-report-primary'),name=w.document.querySelector('.speed-report-public-name'),hint=w.document.querySelector('.speed-report-join-hint');
   assert.ok(button.disabled);assert.equal(checkbox.getAttribute('aria-describedby'),hint.id);assert.match(hint.textContent,/先打开上方开关/);
   await React.act(async()=>button.click());assert.equal(joined,0);
   await React.act(async()=>checkbox.click());assert.equal(button.disabled,false);assert.match(hint.textContent,/已选择参加/);
   assert.equal(w.document.querySelector('.speed-report-public-name'),name);
   await React.act(async()=>button.click());assert.equal(joined,1);
   await React.act(async()=>checkbox.click());assert.equal(button.disabled,true);assert.equal(w.document.querySelector('.speed-report-public-name'),name);assert.equal(w.document.querySelector('.speed-report-join-hint'),hint);
  });
 }finally{if(root)await React.act(async()=>root.unmount());for(const[k,v]of saved)v?Object.defineProperty(globalThis,k,v):delete globalThis[k];w.close();}
});
