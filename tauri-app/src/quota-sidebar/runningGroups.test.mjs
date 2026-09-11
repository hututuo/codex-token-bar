import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { Window } from "happy-dom";
import { withSsrModules } from "../test/ssrHarness.mjs";
const member = (threadId, title, model, reasoningEffort) => ({ threadId, title, model, reasoningEffort });

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
