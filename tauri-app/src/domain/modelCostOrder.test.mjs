import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';
import {withSsrModules} from '../test/ssrHarness.mjs';
test('shared cost order preserves all client rows and fees regardless of input order',async()=>withSsrModules(async load=>{
 const {orderedCostGroups}=await load('/src/domain/modelCostOrder.ts');
 const fixture=JSON.parse(await readFile(new URL('../../../Tests/SharedFixtures/model-cost-order.json',import.meta.url),'utf8'));
 const rows=fixture.input.map(key=>({key,label:key,tokens:100,share:.001,costUSD:.25,usesIndependentQuota:false,referenceCostUSD:null,color:'#123456'}));
 for(const input of [rows,[...rows].reverse(),[...rows.slice(1),rows[0]]]){
  const groups=orderedCostGroups(input);
  assert.deepEqual(groups.map(g=>({id:g.id,keys:g.items.map(x=>x.key)})),fixture.groups);
  assert.deepEqual(groups.flatMap(g=>g.items).sort((a,b)=>a.key.localeCompare(b.key)),[...rows].sort((a,b)=>a.key.localeCompare(b.key)));
 }
 assert.deepEqual(orderedCostGroups([{...rows[0],key:'claudeCode|claude-fable-5-1',tokens:0}]),[]);
 assert.equal(orderedCostGroups([{...rows[0],key:'codex|gpt-6-sol'}])[0].id,'client:codex');
 assert.equal(orderedCostGroups([{...rows[0],key:'claudeCode|claude-fable-5-2'}])[0].id,'client:claudeCode');
 assert.equal(orderedCostGroups([{...rows[0],key:'claudeCode|claude-fable-5'}])[0].id,'client:claudeCode');
}));
