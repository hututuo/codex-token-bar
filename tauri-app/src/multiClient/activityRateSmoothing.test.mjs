import test from 'node:test';
import assert from 'node:assert/strict';
import {ActivityModelRateSmoother,activityRateStep,activityRateTail,claudeBarAgentActive} from './activityRateSmoothing.ts';
test('normal completion can taper for five seconds; cancellation never receives that grace',()=>{
  const agent={phase:'idle',lastActivity:new Date(100000).toISOString()};
  assert.equal(claudeBarAgentActive(agent,104),true);
  assert.equal(claudeBarAgentActive(agent,105),false);
  assert.equal(claudeBarAgentActive({...agent,displayStopped:true},100),false);
  assert.equal(claudeBarAgentActive({...agent,lastActivity:'bad'},100),false);
});
test('Codex rise/fall response is time based and softens a completed-response spike',()=>{
  const s=new ActivityModelRateSmoother();
  assert.ok(Math.abs(s.update(new Map([['opus',100]]),100,true).get('opus')-28)<1e-10);
  const falling=s.update(new Map(),101,true).get('opus');
  assert.ok(falling>0&&falling<28.1);
  assert.ok(Math.abs(activityRateStep(activityRateStep(0,100,.5),100,.5)-activityRateStep(0,100))<1e-10);
  assert.ok(Math.abs(activityRateStep(activityRateStep(100,0,.5),0,.5)-activityRateStep(100,0))<1e-10);
  assert.equal(activityRateTail(3),1);assert.equal(activityRateTail(4),.5);assert.equal(activityRateTail(5),0);
});
test('a stop, missing reader, restart or stale gap cannot keep an old plateau alive',()=>{
  const s=new ActivityModelRateSmoother(),raw=new Map([['sonnet',100]]);
  s.update(raw,100,true);
  assert.equal(s.update(raw,101,false).size,0);
  assert.ok(Math.abs(s.update(raw,102,true).get('sonnet')-28)<1e-10);
  assert.ok(Math.abs(s.update(raw,110,true).get('sonnet')-28)<1e-10);
  assert.equal(s.update(new Map(),115,true).size,0);
  assert.equal(s.update(raw,NaN,true).size,0);
});
test('poll duplicates and older receipts do not advance the filter or mix models',()=>{
  const s=new ActivityModelRateSmoother(),raw=new Map([['opus',100],['sonnet',50],['invalid',NaN]]);
  const initial=s.update(raw,100,true);
  assert.deepEqual(s.update(new Map([['opus',999]]),100,true),initial);
  assert.deepEqual(s.update(raw,99,true),initial);
  const changed=s.update(new Map([['sonnet',50]]),102,true);
  assert.ok(changed.get('opus')<initial.get('opus'));
  assert.ok(changed.get('sonnet')>initial.get('sonnet'));
  assert.ok(!changed.has('invalid'));
  assert.ok(!s.update(new Map([['sonnet',50]]),105,true).has('opus'));
});
