import test from 'node:test';
import assert from 'node:assert/strict';
import {withSsrModules} from '../test/ssrHarness.mjs';

test('Claude version parser handles 5.5, provider prefixes, and dated IDs',async()=>withSsrModules(async load=>{
 const {claudeModelIdentity}=await load('/src/components/claudeModelPresentation.ts');
 for(const [raw,version] of [
  ['claude-opus-5-5',[5,5]],
  ['anthropic/claude-opus-5.5-20261022',[5,5]],
  ['us.anthropic.claude-sonnet-5-5-20261022-v1:0',[5,5]],
  ['ClaudeCode|haiku5.5',[5,5]],
  ['claude-fable-5-1-20261022',[5,1]],
 ])assert.deepEqual(claudeModelIdentity(raw)?.version,version,raw);
 assert.deepEqual(claudeModelIdentity('claude-opus-20261001')?.version,[]);
}));

test('bundled catalog exposes the current latest Claude model ID per family',async()=>withSsrModules(async load=>{
 const {claudeNewestCatalogModelsByFamily:models}=await load('/src/components/claudeModelPresentation.ts');
 assert.deepEqual(Object.fromEntries(Object.entries(models).map(([family,model])=>[family,model.id])),{
  fable:'claude-fable-5-1',opus:'claude-opus-5-5',sonnet:'claude-sonnet-5-5',haiku:'claude-haiku-5-5',
 });
}));

test('older local Claude rows are not marked latest below the bundled catalog floor',async()=>withSsrModules(async load=>{
 const {claudeModelGroups}=await load('/src/components/claudeModelPresentation.ts');
 const items=['claudeCode|opus-4-8','claudeDesktop|sonnet-5','claudeCode|haiku-4-5','claudeDesktop|fable-5','claudeCode|claude-opus-20261001','claudeDesktop|custom-model'].map(key=>({key}));
 const groups=claudeModelGroups(items,'claude');
 assert.equal(groups.some(group=>group.id==='claude:latest'),false);
 assert.deepEqual(groups.map(group=>group.id),['claude:other']);
 assert.equal(groups[0].items.length,items.length);
 assert.deepEqual(groups.flatMap(group=>group.items).map(item=>item.key).sort(),items.map(item=>item.key).sort());
}));

test('a locally observed version above the catalog floor wins and all source rows remain',async()=>withSsrModules(async load=>{
 const {claudeModelGroups}=await load('/src/components/claudeModelPresentation.ts');
 const items=['claudeCode|opus-5-5','claudeDesktop|opus-6-1','claudeCode|haiku-6','claudeDesktop|fable-5-1','claudeCode|custom-model'].map(key=>({key}));
 const groups=claudeModelGroups(items,'claude');
 assert.deepEqual(groups.find(group=>group.id==='claude:latest')?.items.map(item=>item.key),[
  'claudeDesktop|fable-5-1','claudeDesktop|opus-6-1','claudeCode|haiku-6',
 ]);
 assert.deepEqual(groups.flatMap(group=>group.items).map(item=>item.key).sort(),items.map(item=>item.key).sort());
}));
