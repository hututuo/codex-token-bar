import assert from 'node:assert/strict';
import test from 'node:test';
import {withSsrModules} from '../test/ssrHarness.mjs';
test('task freshness represents available current observations, independently per client',async()=>withSsrModules(async load=>{
 const {sidebarCombinedTaskStatus:status}=await load('/src/quota-sidebar/sidebarLayoutPresentation.ts');
 assert.equal(status('ready',true,false,false),'ready','A detected historical but disabled Claude client cannot stale fresh Codex tasks');
 assert.equal(status('ready',true,true,false),'ready','Missing Claude cannot hide known current Codex tasks');
 assert.equal(status('ready',true,true,true),'ready');
 assert.equal(status('stale',true,true,true),'ready','Use fresh Claude only; stale Codex counts are excluded separately');
 assert.equal(status('stale',true,true,false),'stale','No current source must not pretend old counts are fresh');
 assert.equal(status('scanning',true,true,false),'scanning');
 assert.equal(status('ready',false,true,true),'ready');
 assert.equal(status('ready',false,true,false),'unavailable');
 assert.equal(status('ready',false,false,false),'unavailable','No selected task collector is not a fresh zero');
}));

test('task counts exclude unavailable and stale readers whenever a current reader exists',async()=>withSsrModules(async load=>{
 const {sidebarCombinedTaskCounts:counts}=await load('/src/quota-sidebar/sidebarLayoutPresentation.ts');
 assert.deepEqual(counts('ready',true,true,false,1,0,40,20),{status:'ready',main:1,subagents:0},'The reported screenshot must show one known task, not a dash');
 assert.deepEqual(counts('ready',true,true,true,1,2,3,4),{status:'ready',main:4,subagents:6});
 assert.deepEqual(counts('stale',true,true,true,100,200,3,4),{status:'ready',main:3,subagents:4},'Do not mix historical Codex tasks with current Claude');
 assert.deepEqual(counts('stale',true,true,false,1,2,30,40),{status:'stale',main:1,subagents:2});
 assert.deepEqual(counts('unavailable',true,true,false,10,20,30,40),{status:'unavailable',main:0,subagents:0});
 assert.deepEqual(counts('ready',false,false,false,10,20,30,40),{status:'unavailable',main:0,subagents:0});
 assert.deepEqual(counts('ready',true,true,false,0,0,30,40),{status:'ready',main:0,subagents:0},'A confirmed zero differs from an unavailable source');
}));
