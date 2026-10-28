import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { Window } from "happy-dom";
import { withSsrModules } from "../../test/ssrHarness.mjs";

test("quota rows keep each observed plan with its own client and retain Codex tools", async () => withSsrModules(async load => {
  const { QuotaStrip } = await load("/src/components/QuotaStrip.tsx");
  const snapshot = { fiveHour: { availability: "absent" }, sevenDay: { availability: "absent" }, resetCredit: { availableCount: 1, status: "已读取", credits: [] }, paceLabel: "本地快照" };
  const items = ["codex", "claudeCode"].map(client => ({ id: client + ":7d", client, window: "7d", remaining: 75, resetsAt: null, status: "", source: "fixture" }));
  const render = plans => renderToStaticMarkup(React.createElement(QuotaStrip, { snapshot, clientItems: items, clientPlanLabels: plans, includesCodex: true }));
  const w = new Window();
  try {
    w.document.body.innerHTML = render({ codex: "pro 5×", claudeCode: "max 10×" });
    const rows = [...w.document.querySelectorAll(".quota-client-row")];
    assert.equal(rows[0].querySelector(".quota-client-plan").textContent, "PRO 5×");
    assert.equal(rows[1].querySelector(".quota-client-plan").textContent, "MAX 10×");
    assert.ok(rows[0].querySelector('[aria-label="Codex 账户工具"]'));
    assert.equal(rows[1].querySelector('[aria-label="Codex 账户工具"]'), null);
    w.document.body.innerHTML = render({ codex: "prolite" });
    assert.deepEqual([...w.document.querySelectorAll(".quota-client-plan")].map(e => e.textContent), ["PROLITE", "套餐未知"]);
  } finally { w.close(); }
}));
