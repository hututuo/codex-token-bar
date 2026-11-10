import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';
import React,{act} from 'react';
import {createRoot} from 'react-dom/client';
import {renderToStaticMarkup} from 'react-dom/server';
import {Window} from 'happy-dom';
import {withSsrModules} from '../test/ssrHarness.mjs';

const fixture=JSON.parse(await readFile(new URL('../../../Tests/SharedFixtures/client-model-four-slots.json',import.meta.url),'utf8'));
const item=row=>({...row,label:row.key.split('|').at(-1),share:row.tokens>0?.01:0,costUSD:row.tokens>0?.25:0,referenceCostUSD:null,usesIndependentQuota:false,color:'#123456'});

test('shared four-slot cases preserve periods, source rows, money and legacy cutoffs',async()=>withSsrModules(async load=>{
  const {orderedCostGroups}=await load('/src/domain/modelCostOrder.ts');
  const {floatingModelUsageKnownCostUSD}=await load('/src/floating/floatingModelUsage.ts');
  for(const sample of fixture.cases){
    const rows=sample.rows.map(item);
    for(const input of [rows,[...rows].reverse()]){
      const groups=orderedCostGroups(input);
      assert.deepEqual(groups.map(g=>({id:g.id,keys:g.items.map(x=>x.key)})),sample.groups,sample.name);
      assert.equal(groups.flatMap(g=>g.items).reduce((sum,row)=>sum+row.tokens,0),rows.reduce((sum,row)=>sum+row.tokens,0));
      assert.equal(floatingModelUsageKnownCostUSD(groups.flatMap(g=>g.items)),floatingModelUsageKnownCostUSD(rows));
      assert.ok(groups.filter(g=>!g.isSecondary).every(g=>g.visibleLimit===4&&g.items.length>=4));
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

test('Claude display merge preserves partial prices, source attribution and fast variants',async()=>withSsrModules(async load=>{
  const {orderedCostGroups}=await load('/src/domain/modelCostOrder.ts');
  const {floatingModelUsageKnownCostUSD}=await load('/src/floating/floatingModelUsage.ts');
  const desktop={...item({key:'claudeDesktop|claude-opus-5-5',tokens:60}),share:.6,sourceModels:['claude-opus-5-5']};
  const cli={...item({key:'claudeCode|claude-opus-5-5',tokens:40}),share:.4,costUSD:null,knownPartialCostUSD:.5,sourceModels:['anthropic.claude-opus-5-5']};
  const fast=item({key:'claudeCode|claude-opus-5-5-fast',tokens:100}),ag=item({key:'antigravity|claude-opus-5-5',tokens:100});
  const groups=orderedCostGroups([desktop,cli,fast,ag]),claude=groups.find(g=>g.id==='client:claude');
  const merged=claude.items.find(row=>row.key==='claude|claude-opus-5-5');
  assert.equal(merged.tokens,100);assert.equal(merged.share,1);
  assert.equal(merged.costUSD,null);assert.equal(merged.knownPartialCostUSD,.75);
  assert.deepEqual(merged.sourceClients,['claudeCode','claudeDesktop']);
  assert.deepEqual(merged.sourceModels,['anthropic.claude-opus-5-5','claude-opus-5-5']);
  assert.equal(claude.items[1],merged);
  assert.ok(claude.items.includes(fast));
  assert.deepEqual(groups.at(-1).items.filter(row=>!row.isCatalogPlaceholder),[ag]);
  assert.equal(floatingModelUsageKnownCostUSD(groups.flatMap(g=>g.items)),1.25);
  const single=orderedCostGroups([cli])[0];
  assert.deepEqual(single.items.filter(row=>!row.isCatalogPlaceholder),[cli]);
  assert.ok(single.items.filter(row=>row.isCatalogPlaceholder).every(row=>row.sourceClients.join()==='claudeCode'));
  const unknown={...item({key:'claudeCode|claude-fable-5-2',tokens:50}),costUSD:null};
  assert.equal(floatingModelUsageKnownCostUSD(orderedCostGroups([unknown]).flatMap(g=>g.items)),null);
}));

test('three client headings show twelve cards including zero Haiku and merged Claude provenance',async()=>withSsrModules(async load=>{
  const {orderedCostGroups}=await load('/src/domain/modelCostOrder.ts');
  const {ClientModelCostGroup}=await load('/src/components/statsStrip/ClientModelCostGroup.tsx');
  const rows=['codex|gpt-6-astra','claudeDesktop|claude-opus-5-5','claudeCode|claude-opus-5-5','claudeCode|claude-fable-5-1',
    'antigravity|gemini-4-argon','antigravity|claude-opus-5-5','antigravity|claude-sonnet-5-5'].map(key=>item({key,tokens:100}));
  const groups=orderedCostGroups(rows),window=new Window();
  try {
    const host=window.document.createElement('div');
    host.innerHTML=renderToStaticMarkup(React.createElement(React.Fragment,null,...groups.map(group=>React.createElement(ClientModelCostGroup,{key:group.id,group,onEditColor:()=>{}}))));
    assert.deepEqual([...host.querySelectorAll('.stats-model-cost-group-label > span')].map(x=>x.textContent),['Codex','Claude','Antigravity']);
    assert.equal(host.querySelectorAll('.stats-model-cost-primary-card').length,12);
    const ag=host.querySelector('[data-cost-group="client:antigravity"]'),haiku=[...ag.querySelectorAll('.stats-model-cost-primary-card')].at(-1);
    assert.equal(haiku.querySelector('.model-cost-name').textContent,'Haiku5.5');
    assert.equal(haiku.querySelector('.model-cost-tokens').textContent,'0');
    assert.equal(haiku.querySelector('b').textContent,'$0.00');
    assert.match(haiku.getAttribute('aria-label'),/本周期暂无本地用量记录/);
    const merged=[...host.querySelector('[data-cost-group="client:claude"]').querySelectorAll('.stats-model-cost-primary-card')][1];
    assert.match(merged.getAttribute('aria-label'),/Claude CLI、Claude Desktop/);
    assert.match(merged.getAttribute('title'),/Claude CLI、Claude Desktop/);
    assert.equal(host.querySelector('.stats-model-cost-expand').textContent,'另1项');
  } finally { await window.happyDOM.abort(); }
}));

test('fifth Claude item folds under one heading without a default singleton row or dropped total',async()=>{
  const window=new Window(),prior={window:globalThis.window,document:globalThis.document,IS_REACT_ACT_ENVIRONMENT:globalThis.IS_REACT_ACT_ENVIRONMENT};
  globalThis.window=window;globalThis.document=window.document;globalThis.IS_REACT_ACT_ENVIRONMENT=true;
  let root;
  try{await withSsrModules(async load=>{
    const {orderedCostGroups}=await load('/src/domain/modelCostOrder.ts');
    const {ClientModelCostGroup}=await load('/src/components/statsStrip/ClientModelCostGroup.tsx');
    const rows=fixture.cases.find(c=>c.name==='fifth-claude-model-folds-under-the-same-heading').rows.map(item),group=orderedCostGroups(rows)[0];
    const host=window.document.createElement('div');window.document.body.append(host);root=createRoot(host);
    await act(async()=>root.render(React.createElement(ClientModelCostGroup,{group,onEditColor:()=>{}})));
    assert.equal(host.querySelectorAll('.stats-model-cost-primary-card').length,4);
    assert.equal(host.querySelectorAll('.stats-model-cost-group-label > span').length,1);
    assert.equal(host.querySelector('.stats-model-cost-group-label > span').textContent,'Claude');
    assert.equal(host.querySelector('.stats-model-cost-primary-grid').style.gridTemplateColumns,'repeat(4, minmax(0, 1fr))');
    assert.equal(host.querySelector('.stats-model-cost-expand').textContent,'另1项');
    assert.equal(group.items.reduce((sum,row)=>sum+row.costUSD,0),1.25);
    await act(async()=>host.querySelector('.stats-model-cost-expand').click());
    assert.equal(host.querySelectorAll('.stats-model-cost-primary-card').length,5);
    assert.equal(host.querySelector('.stats-model-cost-expand').getAttribute('aria-expanded'),'true');
    await act(async()=>host.querySelector('.stats-model-cost-expand').click());
    assert.equal(host.querySelectorAll('.stats-model-cost-primary-card').length,4);
    assert.equal(group.items.length,5);
    assert.equal(host.querySelectorAll('.stats-model-cost-placeholder').length,0);
  });}finally{if(root)await act(async()=>root.unmount());Object.assign(globalThis,prior);await window.happyDOM.abort();}
});
