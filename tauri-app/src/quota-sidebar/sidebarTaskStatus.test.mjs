import assert from 'node:assert/strict';
import test from 'node:test';
import {withSsrModules} from '../test/ssrHarness.mjs';
test('task freshness only waits for configured collectors and preserves real failures',async()=>withSsrModules(async load=>{
 const {sidebarCombinedTaskStatus:status}=await load('/src/quota-sidebar/sidebarLayoutPresentation.ts');
 assert.equal(status('ready',true,false,false),'ready','A detected historical but disabled Claude client cannot stale fresh Codex tasks');
 assert.equal(status('ready',true,true,false),'stale','An enabled missing reader must remain visibly incomplete');
 assert.equal(status('ready',true,true,true),'ready');
 assert.equal(status('stale',true,true,true),'stale','A fresh Claude capture cannot conceal stale Codex data');
 assert.equal(status('ready',false,true,true),'ready');
 assert.equal(status('ready',false,true,false),'unavailable');
 assert.equal(status('ready',false,false,false),'unavailable','No selected task collector is not a fresh zero');
}));
