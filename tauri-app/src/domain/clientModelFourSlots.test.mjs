import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';
import React,{act} from 'react';
import {createRoot} from 'react-dom/client';
import {Window} from 'happy-dom';
import {withSsrModules} from '../test/ssrHarness.mjs';

const fixture=JSON.parse(await readFile(new URL('../../../Tests/SharedFixtures/client-model-four-slots.json',import.meta.url),'utf8'));
const item=row=>({...row,label:row.key.split('|').at(-1),share:.01,costUSD:.25,referenceCostUSD:null,usesIndependentQuota:false,color:'#123456'});

test('shared four-slot cases preserve periods, source rows, money and legacy cutoffs',async()=>withSsrModules(async load=>{
  const {orderedCostGroups}=await load('/src/domain/modelCostOrder.ts');
  for(const sample of fixture.cases){
    const rows=sample.rows.map(item);
    for(const input of [rows,[...rows].reverse()]){
      const groups=orderedCostGroups(input);
      assert.deepEqual(groups.map(g=>({id:g.id,keys:g.items.map(x=>x.key)})),sample.groups,sample.name);
      assert.deepEqual(groups.flatMap(g=>g.items).sort((a,b)=>a.key.localeCompare(b.key)),rows.filter(x=>x.tokens>0).sort((a,b)=>a.key.localeCompare(b.key)));
      assert.ok(groups.filter(g=>!g.isSecondary).every(g=>g.items.length<=4));
      assert.ok(groups.filter(g=>g.isSecondary).every(g=>g.visibleLimit===4));
    }
  }
}));

test('Fable 5.2 uses its own standard and fast reference prices',async()=>withSsrModules(async load=>{
  const {referencePrice}=await load('/src/multiClient/clientReferencePrice.ts');
  assert.equal(referencePrice('claude-fable-5-2'),'$8.00 / $40.00');
  assert.equal(referencePrice('claude-fable-5-2-fast'),'$16.00 / $80.00');
  assert.equal(referencePrice('claude-fable-5-1'),'$10.00 / $50.00');
}));

test('fifth Other item expands without creating a default singleton row or dropping the total',async()=>{
  const window=new Window(),prior={window:globalThis.window,document:globalThis.document,IS_REACT_ACT_ENVIRONMENT:globalThis.IS_REACT_ACT_ENVIRONMENT};
  globalThis.window=window;globalThis.document=window.document;globalThis.IS_REACT_ACT_ENVIRONMENT=true;
  let root;
  try{await withSsrModules(async load=>{
    const {orderedCostGroups}=await load('/src/domain/modelCostOrder.ts');
    const {ClientModelCostGroup}=await load('/src/components/statsStrip/ClientModelCostGroup.tsx');
    const rows=fixture.cases.find(c=>c.name==='other-fold-keeps-all-five-records').rows.map(item),group=orderedCostGroups(rows)[0];
    const host=window.document.createElement('div');window.document.body.append(host);root=createRoot(host);
    await act(async()=>root.render(React.createElement(ClientModelCostGroup,{group,onEditColor:()=>{}})));
    assert.equal(host.querySelectorAll('.stats-model-cost-secondary-chip').length,4);
    assert.equal(host.querySelector('.stats-model-cost-secondary-grid').style.gridTemplateColumns,'repeat(4, minmax(0, 1fr))');
    assert.equal(host.querySelector('.stats-model-cost-expand').textContent,'另1项');
    assert.equal(group.items.reduce((sum,row)=>sum+row.costUSD,0),1.25);
    await act(async()=>host.querySelector('.stats-model-cost-expand').click());
    assert.equal(host.querySelectorAll('.stats-model-cost-secondary-chip').length,5);
    assert.equal(host.querySelector('.stats-model-cost-expand').getAttribute('aria-expanded'),'true');
    await act(async()=>host.querySelector('.stats-model-cost-expand').click());
    assert.equal(host.querySelectorAll('.stats-model-cost-secondary-chip').length,4);
    assert.equal(group.items.length,5);
    assert.equal(host.querySelectorAll('.stats-model-cost-placeholder').length,0);
  });}finally{if(root)await act(async()=>root.unmount());Object.assign(globalThis,prior);await window.happyDOM.abort();}
});
