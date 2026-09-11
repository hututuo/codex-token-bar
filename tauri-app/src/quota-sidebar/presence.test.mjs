import test from 'node:test';
import assert from 'node:assert/strict';
import {monitorSidebarPresence} from './presence.ts';
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
