import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { Window } from "happy-dom";
import { withSsrModules } from "../test/ssrHarness.mjs";
const member = (threadId, title, model, reasoningEffort) => ({ threadId, title, model, reasoningEffort });
const now = Date.parse('2026-11-06T03:00:00Z');
const agent = (client, id, parentId = null, extra = {}) => ({client,id,parentId,title:`${client}:${id}`,
  model:'gpt-6-astra',phase:'generating',displayStopped:false,lastActivity:new Date(now).toISOString(),...extra});
const codexSummary = (extra = {}) => ({total:2,mainThreads:1,subagents:1,status:'ready',detail:'',updatedAt:now/1000,livenessLeaseHours:1,
  mainModels:[{model:'gpt-6-astra',reasoningEffort:'high',count:1}],subagentModels:[{model:'gpt-6-luna',reasoningEffort:'max',count:1}],
  groups:[{mainThread:member('parent','Codex 主任务','gpt-6-astra','high'),subagents:[member('child','Codex 子代理','gpt-6-luna','max')]}],unassignedSubagents:[],...extra});
const localRuntime = (extra = {}) => ({enabled:true,capturedAt:new Date(now).toISOString(),configuredClients:['claudeCode','claudeDesktop','antigravity'],
  sourceAvailable:{claudeCode:true,claudeDesktop:true,antigravity:true},configurationIssue:null,
  mainAgents:[agent('claudeCode','parent',null,{model:'claude-opus-4-6'}),agent('antigravity','parent',null,{model:'gemini-4-argon'})],
  subagents:[agent('claudeCode','child','parent',{model:'claude-opus-4-6',phase:'tools'}),agent('antigravity','child','parent',{model:'gemini-4-argon'})],...extra});

test('all clients use one set of task cards and totals; matching IDs cannot cross parent ownership', async () => {
  await withSsrModules(async load => {
    const {combinedRunningTasks}=await load('/src/quota-sidebar/runningTaskPresentation.ts');
    const {RunningTaskDetails}=await load('/src/quota-sidebar/RunningTaskDetails.tsx');
    const {sidebarTaskMeter}=await load('/src/quota-sidebar/SidebarTaskMeter.tsx');
    const {modelUsageColor}=await load('/src/components/modelUsagePresentation.ts');
    const runtime=localRuntime();
    runtime.subagents.push(agent('claudeDesktop','orphan','parent',{title:'Desktop 无匹配父任务'}));
    const running=combinedRunningTasks(codexSummary(),runtime,['codex','claudeCode','claudeDesktop','antigravity'],now);
    assert.equal(running.total,7);assert.equal(running.mainThreads,3);assert.equal(running.subagents,4);
    assert.equal(new Set(running.groups.map(group=>group.mainThread.threadId)).size,3);
    assert.deepEqual(running.groups.map(group=>group.subagents.map(child=>child.client)),[['codex'],['claudeCode'],['antigravity']]);
    assert.equal(running.unassignedSubagents[0].client,'claudeDesktop');
    const window=new Window();
    try {
      window.document.body.innerHTML=renderToStaticMarkup(React.createElement(RunningTaskDetails,{running}));
      assert.equal(window.document.querySelectorAll('.qs-task-totals').length,1);
      assert.deepEqual([...window.document.querySelectorAll('.qs-task-totals strong')].map(n=>n.textContent),['3','4']);
      assert.equal(window.document.querySelectorAll('.qs-task-group').length,3);
      assert.equal(window.document.querySelectorAll('.qs-task-group .qs-child-task').length,3);
      const gravity=window.document.querySelector('[data-task-source="antigravity"]');
      assert.match(gravity.textContent,/未提供|未知/,'Unreported reasoning effort is not invented');
      assert.match(gravity.querySelector('.qs-main-task').textContent,/生成中/);
      assert.ok(gravity.querySelector('.qs-task-metadata strong').getAttribute('style').includes(modelUsageColor('gemini-4-argon')));
      assert.match(window.document.querySelector('.qs-unassigned-tasks').textContent,/Desktop 无匹配父任务/);
      const meter=sidebarTaskMeter(running.mainThreads,running.subagents,running.status,[...running.mainModels,...running.subagentModels]);
      assert.equal(meter.cells.filter(Boolean).length,running.total);
      assert.match(meter.label,/主 3 · 子 4/);
    } finally {window.close();}
    const only=combinedRunningTasks(codexSummary(),runtime,['antigravity'],now);
    assert.equal(only.total,2);assert.deepEqual(only.groups.map(group=>group.mainThread.client),['antigravity']);
    assert.equal(only.unassignedSubagents.length,0);
  });
});

test('task projection excludes each unavailable, disabled, stopped and expired source without hiding known tasks',async()=>{
  await withSsrModules(async load=>{
    const {combinedRunningTasks}=await load('/src/quota-sidebar/runningTaskPresentation.ts');
    const runtime=localRuntime({configuredClients:['claudeCode','antigravity'],sourceAvailable:{claudeCode:true,antigravity:false}});
    runtime.mainAgents.push(agent('claudeCode','stopped',null,{displayStopped:true}),
      agent('claudeCode','old',null,{lastActivity:new Date(now-300001).toISOString()}),
      agent('claudeCode','idle',null,{phase:'idle'}),agent('claudeCode','future',null,{lastActivity:new Date(now+5001).toISOString()}),
      agent('claudeDesktop','disabled'));
    const current=combinedRunningTasks(codexSummary({status:'stale',mainThreads:100,subagents:200}),runtime,['codex','claudeCode','claudeDesktop','antigravity'],now);
    assert.equal(current.status,'ready');assert.equal(current.total,2);assert.equal(current.groups.length,1);
    assert.equal(current.groups[0].mainThread.client,'claudeCode');
    assert.equal(current.sourceIssues.length,2);assert.match(current.sourceIssues.join(' '),/Codex.*Antigravity/);
    assert.doesNotMatch(JSON.stringify(current.groups),/stopped|disabled|future|idle|:old/);
    const unavailable=combinedRunningTasks(codexSummary(),{...runtime,capturedAt:new Date(now-10001).toISOString()},['claudeCode'],now);
    assert.equal(unavailable.status,'unavailable');assert.equal(unavailable.total,null);assert.equal(unavailable.groups.length,0);
    const retained=combinedRunningTasks(codexSummary({status:'stale'}),{...runtime,enabled:false},['codex','claudeCode'],now);
    assert.equal(retained.status,'stale');assert.equal(retained.total,2);assert.equal(retained.groups[0].mainThread.client,'codex');
    const empty=combinedRunningTasks(codexSummary(),localRuntime({mainAgents:[],subagents:[]}),['antigravity'],now);
    assert.equal(empty.status,'ready');assert.equal(empty.total,0);
  });
});

test('partial and missing task data never render an overall idle state or a fabricated zero',async()=>{
  await withSsrModules(async load=>{
    const {combinedRunningTasks}=await load('/src/quota-sidebar/runningTaskPresentation.ts');
    const {RunningTaskDetails}=await load('/src/quota-sidebar/RunningTaskDetails.tsx');
    const render=runtime=>renderToStaticMarkup(React.createElement(RunningTaskDetails,{running:combinedRunningTasks(codexSummary(),runtime,['claudeCode','antigravity'],now)}));
    const partial=render(localRuntime({mainAgents:[],subagents:[],sourceAvailable:{claudeCode:true,antigravity:false}}));
    assert.match(partial,/其余来源待核验/);assert.doesNotMatch(partial,/当前没有运行中的会话/);
    const missing=render(localRuntime({capturedAt:null}));
    assert.match(missing,/<strong>未知<\/strong>/);assert.doesNotMatch(missing,/<strong>0<\/strong>|qs-task-group/);
  });
});

test("task cards preserve each main task and its own children with explicit separate model/effort rows", async () => {
  await withSsrModules(async load => {
    const { RunningDetails } = await load("/src/quota-sidebar/QuotaSidebarApp.tsx");
    const data = { runningThreads: { total: 5, mainThreads: 2, subagents: 3, status: "ready", detail: "",
      groups: [
        { mainThread: member("main-a", "完整主任务 A 标题", "gpt-6-astra", "high"), subagents: [member("child-a", "A 的分析子任务", "gpt-5.6-luna", "max")] },
        { mainThread: member("main-b", "主任务 B", "gpt-5.6-sol", "medium"), subagents: [member("child-b", "B 的实施子任务", null, null)] },
      ], unassignedSubagents: [member("orphan", "未关联子任务", "gpt-5.6-luna", "xhigh")] } };
    const window = new Window();
    try {
      window.document.body.innerHTML = renderToStaticMarkup(React.createElement(RunningDetails, { data }));
      const groups = [...window.document.querySelectorAll(".qs-task-group")];
      assert.equal(groups.length, 2);
      assert.match(groups[0].textContent, /主任务.*完整主任务 A 标题.*子代理.*A 的分析子任务/);
      assert.ok(!groups[0].textContent.includes("B 的实施"));
      assert.ok(!groups[1].textContent.includes("A 的分析"));
      assert.equal(groups[0].querySelector(".qs-task-title").title, "完整主任务 A 标题");
      assert.deepEqual([...groups[0].querySelectorAll(".qs-main-task .qs-task-metadata span")].map(node => node.textContent), ["模型", "推理强度"]);
      assert.deepEqual([...groups[0].querySelectorAll(".qs-child-task .qs-task-metadata strong")].map(node => node.textContent), ["gpt-5.6-luna", "max"]);
      assert.match(groups[1].querySelector(".qs-child-task").textContent, /模型未知.*推理强度.*未知/);
      const unassigned = window.document.querySelector(".qs-unassigned-tasks");
      assert.ok(unassigned.textContent.includes("未关联主任务")); assert.ok(unassigned.textContent.includes("未关联子任务"));
      assert.ok(groups.every(group => !group.textContent.includes("未关联子任务")));
    } finally { window.close(); }
  });
});
