import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { withSsrModules } from "../test/ssrHarness.mjs";

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

test("task label reports count and freshness without representing progress", async () => {
  await withSsrModules(async load => {
    const { defaultQuotaSelection } = await load("/src/multiClient/integratedClientModel.ts");
    const { sidebarTaskStateLabel } = await load("/src/quota-sidebar/sidebarLayoutPresentation.ts");
    const { SidebarCompactBars } = await load("/src/quota-sidebar/SidebarCompactBars.tsx");
    assert.equal(sidebarTaskStateLabel(3, "ready"), "运行任务：3 个，数据最新");
    assert.equal(sidebarTaskStateLabel(3, "stale"), "运行任务：最近数据显示 3 个，数据已过期");
    assert.equal(sidebarTaskStateLabel(null, "unavailable"), "运行任务：数量未知，状态未知");
    const html = renderToStaticMarkup(React.createElement(SidebarCompactBars, {
      items: ["tasks"], quotas: [], selection: defaultQuotaSelection, ratePercent: null,
      taskStatus: "ready", taskLabel: sidebarTaskStateLabel(3, "ready"),
    }));
    assert.match(html, /class="qs-bar qs-task-state-bar"/);
    assert.match(html, /data-sidebar-item="tasks" data-task-state="ready"/);
    assert.match(html, /role="img"[^>]*aria-label="运行任务：3 个，数据最新"/);
    assert.match(html, /height:46px/);
    assert.match(html, /background:rgba\(239,192,119,.5\)/);
    assert.doesNotMatch(html, /<i aria-hidden/);
    assert.doesNotMatch(html, /height:[0-9.]+%/);
  });
});
