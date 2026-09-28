import test from 'node:test';
import assert from 'node:assert/strict';
import {monitorSidebarPresence, monitorSidebarReminder} from './presence.ts';
const flush = async () => { await Promise.resolve(); await Promise.resolve(); };
function rig(inside) {
 let next=null, leaves=0;
 const stop=monitorSidebarPresence(inside,()=>leaves++,callback=>{next=callback;return()=>{next=null;};});
 return {stop,get leaves(){return leaves;},get scheduled(){return next!==null;},async tick(){const cb=next;next=null;cb?.();await flush();}};
}
test('missed native exit still collapses after two outside observations and stops monitoring',async()=>{
 const r=rig(async()=>false);await r.tick();assert.equal(r.leaves,0);await r.tick();assert.equal(r.leaves,1);assert.equal(r.scheduled,false);
});
test('crossing the detail gap or reentering resets the outside observation',async()=>{
 const results=[false,true,false,false],r=rig(async()=>results.shift());
 for(let i=0;i<3;i++){await r.tick();assert.equal(r.leaves,0);}await r.tick();assert.equal(r.leaves,1);
});
test('pin, drag, collapse or disable disposal invalidates an in-flight answer and cancels future checks',async()=>{
 let resolve;const r=rig(()=>new Promise(done=>resolve=done));await r.tick();assert.equal(r.scheduled,false);r.stop();resolve(false);await flush();assert.equal(r.leaves,0);assert.equal(r.scheduled,false);
});
test('slow IPC cannot overlap and failures do not count as outside',async()=>{
 let resolve;const r=rig(()=>new Promise(done=>resolve=done));await r.tick();assert.equal(r.scheduled,false);resolve(true);await flush();assert.equal(r.scheduled,true);r.stop();
 let count=0;const q=rig(async()=>{if(++count===2)throw Error('temporary');return false;});
 for(let i=0;i<3;i++){await q.tick();assert.equal(q.leaves,0);}await q.tick();assert.equal(q.leaves,1);
});

function reminderRig(sample) {
 let next=null, dismissed=0;
 const stop=monitorSidebarReminder(sample,()=>dismissed++,callback=>{next=callback;return()=>{next=null;};});
 return {stop,get dismissed(){return dismissed;},get scheduled(){return next!==null;},async tick(){const cb=next;next=null;cb?.();await flush();}};
}
test('automatic reminder stays visible until a new outside click without requiring pointer entry',async()=>{
 let state={inside:false,clickRevision:10};const r=reminderRig(async()=>state);await flush();
 for(let i=0;i<4;i++){await r.tick();assert.equal(r.dismissed,0);}
 // A completed down/up between polls must still dismiss from its retained count.
 state={inside:false,clickRevision:11};await r.tick();assert.equal(r.dismissed,1);assert.equal(r.scheduled,false);
});
test('reminder closes after entering then leaving, with grace across the window gap',async()=>{
 let state={inside:false,clickRevision:1};const r=reminderRig(async()=>state);await flush();
 state={inside:true,clickRevision:2};await r.tick();assert.equal(r.dismissed,0);
 state={inside:false,clickRevision:2};await r.tick();assert.equal(r.dismissed,0);
 state={inside:true,clickRevision:2};await r.tick();
 state={inside:false,clickRevision:2};await r.tick();assert.equal(r.dismissed,0);await r.tick();assert.equal(r.dismissed,1);
});
test('clicks inside preserve the reminder and a new reminder uses a fresh baseline',async()=>{
 let state={inside:true,clickRevision:20};const r=reminderRig(async()=>state);await flush();
 state={inside:true,clickRevision:21};await r.tick();assert.equal(r.dismissed,0);r.stop();
 const next=reminderRig(async()=>({inside:false,clickRevision:21}));await flush();await next.tick();assert.equal(next.dismissed,0);next.stop();
});
test('pin, drag, disable and unmount cancel an in-flight reminder observation',async()=>{
 let resolve;const r=reminderRig(()=>new Promise(done=>resolve=done));assert.equal(r.scheduled,false);
 r.stop();resolve({inside:false,clickRevision:100});await flush();assert.equal(r.dismissed,0);assert.equal(r.scheduled,false);
});
test('a native entry between polls still permits automatic collapse on exit', async () => {
  let entered = false, next, dismissed = 0;
  const stop = monitorSidebarReminder(
    async () => ({ inside: false, clickRevision: 10 }),
    () => dismissed++,
    cb => { next = cb; return () => { next = undefined; }; },
    () => entered);
  await flush();
  entered = true;
  const cb = next; next = undefined; cb?.(); await flush();
  assert.equal(dismissed, 1);
  assert.equal(next, undefined);
  stop();
});
