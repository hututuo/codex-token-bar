import assert from "node:assert/strict";
import test from "node:test";
import {readFile} from "node:fs/promises";
import React from "react";
import {renderToStaticMarkup} from "react-dom/server";
import {Window} from "happy-dom";
import {withSsrModules} from "../test/ssrHarness.mjs";

const fixture = JSON.parse(await readFile(new URL("../../../Tests/SharedFixtures/quota-quarter-ring.json", import.meta.url), "utf8"));
const items = amounts => fixture.windows.map((window,index) => ({...window,client:"antigravity",remaining:amounts[index],
  resetsAt:null,source:"模拟额度 · 不写入账本",status:amounts[index] === null ? "未接入" : "",state:amounts[index] === null ? "notConnected" : "available"}));

test("four Antigravity windows share one stable quartered ring without resurrecting hidden windows", async () => withSsrModules(async load => {
  const {quotaRingGroups,quotaQuarterLayout} = await load("/src/multiClient/integratedClientModel.ts");
  const original = items(fixture.cases[0].remaining), groups = quotaRingGroups([...original].reverse());
  assert.equal(groups.length,1);
  assert.deepEqual(groups[0].quarters.map(item=>item.id),[...quotaQuarterLayout.ids]);
  assert.deepEqual(groups[0].quarters,original);
  for (const hidden of original) {
    const visible = original.filter(item=>item.id!==hidden.id),fallback=quotaRingGroups(visible);
    assert.ok(fallback.every(group=>!group.quarters));
    assert.deepEqual(fallback.flatMap(group=>[group.left,...(group.right?[group.right]:[])]),visible);
  }
  assert.ok(quotaRingGroups(original,true).every(group=>!group.quarters));
}));

test("quartered quota shared cases keep all values colors clean masks and unknown versus zero", async () => withSsrModules(async load => {
  const {QuarteredQuotaRing} = await load("/src/multiClient/QuarteredQuotaRing.tsx");
  const w = new Window();
  try {
    for (const sample of fixture.cases) {
      const windows = items(sample.remaining), colors = {[windows[0].id]:"#123456"};
      w.document.body.innerHTML=renderToStaticMarkup(React.createElement(QuarteredQuotaRing,{items:windows,colors}));
      assert.equal(w.document.querySelectorAll('[data-mode="quartered"]').length,1);
      const sources=[...w.document.querySelectorAll('[data-sidebar-stroke-source]')];assert.equal(sources.length,4);
      assert.deepEqual(sources.map(source=>JSON.parse(source.dataset.strokeSpec)[0].id),windows.map(item=>item.id));
      const masks=[...w.document.querySelectorAll('mask')];assert.equal(new Set(masks.map(mask=>mask.id)).size,4);
      for(const mask of masks)assert.equal(mask.querySelector('circle').getAttribute('stroke-linecap'),'butt');
      const fills=[...w.document.querySelectorAll('circle[mask]')];assert.equal(fills[0].getAttribute('stroke'),'#123456');
      for(let index=0;index<4;index++) {
        assert.equal(fills[index].getAttribute('opacity'),(sample.remaining[index]??0)>0?'1':'0');
        const visible=w.document.querySelector(`.integrated-quarter-values [data-quota-id="${windows[index].id}"]`).textContent;
        assert.equal(visible,sample.remaining[index]===null?'待':String(sample.remaining[index]));
        assert.ok(w.document.querySelector('[role="img"]').getAttribute('aria-label').includes(windows[index].window));
      }
      assert.equal(w.document.querySelectorAll('[data-quota-marker-end]').length,1);
      assert.equal(w.document.querySelector('[data-quota-marker-end]').dataset.quotaMarkerEnd.split(' ').length,4);
    }
  } finally {w.close();}
}));

test("quarter morphs preserve independent quota fractions and never turn their paths over", async () => withSsrModules(async load => {
  const {sidebarStrokes,quarterPoints} = await load("/src/quota-sidebar/sidebarStrokeGeometry.ts");
  const source={x:20,y:40,width:54,height:54};
  for(let quarter=0;quarter<4;quarter++) {
    const target={x:6,y:140+quarter*60,width:4,height:46},fraction=(quarter+1)/4;
    const strokes=sidebarStrokes({id:`quarter-${quarter}`,quarter,fraction,color:'#0f0'},source,target);
    assert.equal(strokes.length,2);
    const fill=strokes.find(stroke=>stroke.id.endsWith(':fill'));
    assert.equal(fill.sourceRange[1]-fill.sourceRange[0],fraction);
    assert.deepEqual(fill.sourceClip,fill.sourcePath);assert.equal(fill.clipLineCap,'butt');
    assert.equal(fill.targetClip[0].y,target.y+target.height);assert.equal(fill.targetClip.at(-1).y,target.y);
    for(const progress of [0,.25,.5,.75,1]) {
      const points=quarterPoints(source,target,quarter,progress);assert.equal(points.length,33);
      assert.ok(points.every((point,index)=>Number.isFinite(point.x)&&Number.isFinite(point.y)&&(index===0||points[index-1].y>=point.y-.0001)));
    }
    for(const fraction of [0,null])assert.equal(sidebarStrokes({id:'empty',quarter,fraction,color:'#0f0'},source,target).length,1);
  }
}));

test("all four quarter masks and participants restore after a quick browser reversal", async () => withSsrModules(async load => {
  const {animateSidebarStrokes}=await load("/src/quota-sidebar/sidebarStrokeMorph.ts");
  const {QuarteredQuotaRing}=await load("/src/multiClient/QuarteredQuotaRing.tsx");
  const w=new Window();
  try {
    Object.defineProperty(w,'CSS',{configurable:true,value:{supports:()=>true}});
    const root=w.document.createElement('div');w.document.body.append(root);
    const windows=items([100,75,50,25]);
    root.innerHTML=renderToStaticMarkup(React.createElement(QuarteredQuotaRing,{items:windows}))
      +windows.map(item=>`<span data-sidebar-stroke-target="${item.id}"></span>`).join('');
    root.getBoundingClientRect=()=>({x:0,y:0});
    root.querySelector('svg').getBoundingClientRect=()=>({x:17,y:37,width:60,height:60});
    [...root.querySelectorAll('[data-sidebar-stroke-target]')].forEach((target,index)=>{
      target.getBoundingClientRect=()=>({x:6,y:140+index*60,width:4,height:46});
    });
    const pending=[];
    w.SVGElement.prototype.animate=function(){return {finished:new Promise(resolve=>pending.push(resolve)),cancel(){}};};
    const cancel=animateSidebarStrokes(root,false);
    assert.equal(root.querySelectorAll('.qs-stroke-morph mask').length,8);
    const snapshot=cancel();assert.equal(snapshot.size,8);
    for(const style of snapshot.values())style.width='3.25px';
    const finish=animateSidebarStrokes(root,true,snapshot);
    assert.equal(root.querySelectorAll('.qs-stroke-morph mask').length,8);
    pending.forEach(resolve=>resolve());for(let n=0;n<5;n++)await Promise.resolve();
    assert.equal(root.querySelector('.qs-stroke-morph'),null);assert.equal(finish().size,0);
    for(const node of root.querySelectorAll('[data-sidebar-stroke-source],[data-sidebar-stroke-target]'))assert.equal(node.style.visibility,'');
    assert.ok([...root.querySelectorAll('.integrated-quarter-values span')].every(node=>node.style.visibility===''));
  } finally {w.close();}
}));
