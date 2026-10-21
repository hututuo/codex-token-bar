import assert from 'node:assert/strict';
import test from 'node:test';
import { withSsrModules } from '../../test/ssrHarness.mjs';
const drain=async()=>{for(let i=0;i<8;i++)await Promise.resolve();};

test('history host subscribes before consuming a first-load intent and does not poll',async()=>{
 await withSsrModules(async load=>{
  const {attachBodySpeedDetailsRequests}=await load('/src/components/liveRate/bodySpeedDetailsBridge.ts');
  const order=[];let opened=0,stopped=0;
  const detach=attachBodySpeedDetailsRequests({subscribe:async()=>{order.push('listen');return()=>stopped++;},take:async()=>{order.push('take');return true;},open:()=>opened++,fail:assert.fail});
  await drain();assert.deepEqual(order,['listen','take']);assert.equal(opened,1);
  await drain();assert.equal(opened,1);detach();assert.equal(stopped,1);
 });
});
test('an event overlapping the initial consumption triggers another take and is not lost',async()=>{
 await withSsrModules(async load=>{
  const {attachBodySpeedDetailsRequests}=await load('/src/components/liveRate/bodySpeedDetailsBridge.ts');
  let handler,resolveFirst,takes=0,opened=0;
  const first=new Promise(resolve=>resolveFirst=resolve);
  const detach=attachBodySpeedDetailsRequests({subscribe:async h=>{handler=h;return()=>{};},take:async()=>++takes===1?first:true,open:()=>opened++,fail:assert.fail});
  await drain();handler();resolveFirst(false);await drain();
  assert.equal(takes,2);assert.equal(opened,1);detach();
 });
});
test('late consumption cannot open a disposed or replaced home surface',async()=>{
 await withSsrModules(async load=>{
  const {attachBodySpeedDetailsRequests}=await load('/src/components/liveRate/bodySpeedDetailsBridge.ts');
  let resolve,opened=0,stopped=0;
  const first=new Promise(r=>resolve=r);
  const detach=attachBodySpeedDetailsRequests({subscribe:async()=>()=>stopped++,take:()=>first,open:()=>opened++,fail:assert.fail});
  await drain();detach();resolve(true);await drain();
  assert.equal(opened,0);assert.equal(stopped,1);
 });
});
