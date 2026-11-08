import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { withSsrModules } from "../test/ssrHarness.mjs";
import { readFileSync } from "node:fs";
import { Window } from "happy-dom";

test("compact quota dots fit the real CSS track and task cells retain a capsule outline", async () => {
  await withSsrModules(async load => {
    const { SidebarCompactBars } = await load("/src/quota-sidebar/SidebarCompactBars.tsx");
    const { sidebarTaskMeter } = await load("/src/quota-sidebar/SidebarTaskMeter.tsx");
    const window = new Window();
    try {
      window.document.documentElement.className = "quota-sidebar-document";
      const style = window.document.createElement("style");
      style.textContent = readFileSync(new URL("../multiClient/integratedClients.css", import.meta.url), "utf8")
        + readFileSync(new URL("./QuotaSidebar.css", import.meta.url), "utf8");
      window.document.head.append(style);
      window.document.body.innerHTML = renderToStaticMarkup(React.createElement(SidebarCompactBars, {
        items:["quota:codex", "tasks"], quotas:[{id:"codex:7d",client:"codex",window:"7d",remaining:null,status:"unknown"}],
        selection:{colors:{}}, ratePercent:null, taskMeter:sidebarTaskMeter(4,0,"ready",[]), preview:true,
      }));
      const css = node => window.getComputedStyle(node);
      const dot = css(window.document.querySelector(".integrated-client-cap"));
      const track = css(window.document.querySelector(".integrated-quota-track .qs-bar"));
      const inset = parseFloat(css(window.document.querySelector(".integrated-quota-value-track")).paddingTop);
      const radius = parseFloat(dot.width) / 2, trackRadius = parseFloat(track.width) / 2;
      assert.equal(dot.width, dot.height);
      assert.equal(parseFloat(dot.left) + radius, trackRadius);
      assert.equal(parseFloat(dot.top) + radius, inset + trackRadius);
      assert.equal(trackRadius - radius, 0.5, "The dot fits entirely inside the top track circle with an inset");
      const meter = window.document.querySelector(".qs-task-state-bar");
      assert.equal(css(meter).overflow, "hidden");
      assert.ok(parseFloat(css(meter).borderRadius) >= parseFloat(css(meter).width) / 2);
      const cells = [...meter.children];
      assert.equal(cells.length, 10);
      assert.ok(cells.every(cell=>parseFloat(css(cell).borderRadius)===0), "Internal separators stay flat");
      assert.equal(cells[0].style.bottom, "0px");
      assert.equal(cells[0].style.height, "calc(10% - 0.3px)");
      assert.equal(cells[9].style.bottom, "calc(90% + 0.3px)");
      assert.equal(cells[9].style.height, "calc(10% - 0.3px)");
    } finally { window.close(); }
  });
});

test("tasks occupy one compact track in the shared item order", async () => {
  await withSsrModules(async load => {
    const { compactSidebarIDs } = await load("/src/quota-sidebar/sidebarLayoutPresentation.ts");
    const quotas = [
      { id: "codex:7d", client: "codex", window: "7d", remaining: 70 },
      { id: "codex:5h", client: "codex", window: "5h", remaining: 55 },
    ];
    assert.deepEqual(compactSidebarIDs(["speed", "tasks", "quota:codex", "models"], quotas), [
      "speed", "tasks", "codex:5h", "codex:7d", "models",
    ]);
  });
});

test("task rail lights one of ten cells per observed agent using model colors", async () => {
  await withSsrModules(async load => {
    const { defaultQuotaSelection } = await load("/src/multiClient/integratedClientModel.ts");
    const { sidebarTaskStateLabel } = await load("/src/quota-sidebar/sidebarLayoutPresentation.ts");
    const { SidebarCompactBars } = await load("/src/quota-sidebar/SidebarCompactBars.tsx");
    const { sidebarTaskMeter } = await load("/src/quota-sidebar/SidebarTaskMeter.tsx");
    const {modelUsageColor}=await load('/src/components/modelUsagePresentation.ts');
    assert.equal(sidebarTaskStateLabel(3, "ready"), "运行任务：3 个，数据最新");
    assert.equal(sidebarTaskStateLabel(3, "stale"), "运行任务：最近数据显示 3 个，数据已过期");
    assert.equal(sidebarTaskStateLabel(null, "unavailable"), "运行任务：数量未知，状态未知");
    const meter=sidebarTaskMeter(1,2,'ready',[{model:'gpt-6-astra',count:1},{model:'gpt-6-luna',count:2}]);
    const html = renderToStaticMarkup(React.createElement(SidebarCompactBars, {
      items: ["tasks"], quotas: [], selection: defaultQuotaSelection, ratePercent: null,
      taskMeter:meter,
    }));
    assert.match(html, /class="qs-bar qs-task-state-bar"/);
    assert.match(html, /data-sidebar-item="tasks"[^>]*data-task-state="ready"/);
    assert.match(html, /role="img"[^>]*aria-label="运行任务：3 个（主 1 · 子 2）；每格 1 个/);
    assert.match(html, /height:46px/);
    assert.equal((html.match(/data-task-cell=/g)??[]).length,10);
    assert.equal((html.match(/data-occupied="true"/g)??[]).length,3);
    assert.match(html,/bottom:0;height:calc\(10% - 0.3px\)/);
    assert.match(html,/bottom:calc\(90% \+ 0.3px\);height:calc\(10% - 0.3px\)/);
    assert.deepEqual(meter.colors.slice(0,3),[modelUsageColor('gpt-6-astra'),modelUsageColor('gpt-6-luna'),modelUsageColor('gpt-6-luna')]);
  });
});

test('task cells preserve unknown counts, saturate at ten, and exclude stale sources from a current total',async()=>withSsrModules(async load=>{
 const {sidebarTaskMeter:meter,sidebarTaskMeterForSources:combine}=await load('/src/quota-sidebar/SidebarTaskMeter.tsx');
 assert.deepEqual(meter(0,0,'ready',[]).cells,Array(10).fill(null));
 assert.deepEqual(meter(1,2,'ready',[{model:'gpt-6-luna',count:1}]).cells.slice(0,4),['gpt-6-luna','unknown','unknown',null]);
 const overflow=meter(2,12,'ready',[{model:'gpt-6-luna',count:14}]);
 assert.equal(overflow.cells.filter(Boolean).length,10);assert.match(overflow.label,/14 个.*超过 10/);
 assert.deepEqual(meter(3,4,'unavailable',[{model:'gpt-6-luna',count:7}]).cells,Array(10).fill(null));
 assert.equal(meter(3,0,'stale',[{model:'gpt-6-luna',count:3}]).colors[0],'rgba(122,135,150,0.55)');
 const codex={status:'stale',mainThreads:1,subagents:2,mainModels:[{model:'gpt-6-astra',count:1}],subagentModels:[{model:'gpt-6-luna',count:2}]};
 const current=combine(codex,true,true,[{model:'claude-sonnet-4-6'}],[]);
 assert.equal(current.main,1);assert.equal(current.subagents,0);assert.equal(current.meter.cells.filter(Boolean).length,1);
 assert.equal(current.meter.cells[0],'claude-sonnet-4-6');
 const rows=[{model:'gpt-6-astra',count:1},{model:'gpt-6-luna',count:3}];
 assert.deepEqual(meter(1,3,'ready',rows).cells,meter(1,3,'ready',[...rows].reverse()).cells);
}));

test('ten model cells keep their colors and thin separators through ring-to-rail motion',async()=>withSsrModules(async load=>{
 const {sidebarTaskMeter,taskMeterSegments}=await load('/src/quota-sidebar/SidebarTaskMeter.tsx');
 const {SidebarTaskRing}=await load('/src/quota-sidebar/SidebarActivityStrokes.tsx');
 const {sidebarStrokes}=await load('/src/quota-sidebar/sidebarStrokeGeometry.ts');
 const meter=sidebarTaskMeter(1,2,'ready',[{model:'gpt-6-astra',count:1},{model:'claude-sonnet-4-6',count:2}]);
 const html=renderToStaticMarkup(React.createElement(SidebarTaskRing,{meter},'3'));
 assert.equal((html.match(/<circle/g)??[]).length,10);
 const strokes=sidebarStrokes({id:'tasks',shape:'taskCells',fraction:1,color:'#888',segments:taskMeterSegments(meter)},
  {x:0,y:0,width:46,height:46},{x:1,y:100,width:4,height:46});
 assert.equal(strokes.length,10);
 for(let i=0;i<10;i++){
  assert.equal(strokes[i].color,meter.colors[i]);assert.equal(strokes[i].lineCap,'butt');
  assert.equal(strokes[i].source.length,strokes[i].target.length);
  assert.ok(Math.abs(strokes[i].target[0].y-strokes[i].target.at(-1).y-(i===0||i===9?4.3:4))<1e-8);
  if(i)assert.ok(Math.abs(strokes[i-1].target.at(-1).y-strokes[i].target[0].y-.6)<1e-8);
  if(i===0||i===9){
   assert.equal(strokes[i].sourceClip.length,strokes[i].targetClip.length);
   assert.equal(i===0?strokes[i].targetClip[0].y+2:strokes[i].targetClip.at(-1).y-2,i===0?146:100);
  }else assert.equal(strokes[i].targetClip,undefined);
 }
 assert.equal(strokes[0].target[0].y,146);assert.equal(strokes[9].target.at(-1).y,100);
}));
