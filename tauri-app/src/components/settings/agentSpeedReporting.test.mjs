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
