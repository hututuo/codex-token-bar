import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { Window } from "happy-dom";
import { withSsrModules } from "../../test/ssrHarness.mjs";

test("overview title, client scope, and report status share the top row", async () => withSsrModules(async (load) => {
  const { DashboardHeader } = await load("/src/components/DashboardHeader.tsx");
  const html = renderToStaticMarkup(React.createElement(DashboardHeader, {
    scopeControl: React.createElement("nav", { "aria-label": "统计客户端范围" }, "Codex / Claude CLI / 汇总"),
    reportingStatus: React.createElement("button", { className: "speed-report-header-status" }, "正在上报"),
    account: { displayName: "Local User", planLabel: "PRO" },
    customAccountDisplayName: "Private Alias",
    generatedAt: "2026-10-28T09:00:00Z",
    codexHome: { exists: true, source: "auto", path: "/local" },
    autostartStatus: { available: true, enabled: false, message: "" },
    appUpdateState: { kind: "idle", message: "" },
    threadDeleteBridgeStatus: { connected: false, debugPort: null, message: "" },
    autoResumeEnabled: false,
    onCodexHomeChange: async () => {},
    onCodexHomeReset: async () => {},
    onCustomAccountDisplayNameChange: async () => {},
    onCheckForUpdate: async () => {},
    onExportCsv() {},
    onExportPng() {},
    onOpenProviderRepair() {},
    onOpenSessionManagement() {},
    onOpenSettings() {},
    onRefresh: async () => {},
    onToggleAutostart() {},
    refreshing: false,
  }));

  const window = new Window();
  window.document.body.innerHTML = html;
  const { document } = window;
  const top = document.querySelector(".dashboard-header-top");
  const scopeSlot = document.querySelector(".dashboard-scope-slot");
  const title = document.querySelector("h1.dashboard-overview-title");
  const scopeControl = document.querySelector('[aria-label="统计客户端范围"]');
  const reportingStatus = document.querySelector(".speed-report-header-status");
  const dashHead = document.querySelector(".dash-head");
  const actionStrip = document.querySelector(".dash-head__strip");
  const actions = document.querySelector(".dash-head__actions");

  assert.ok(top);
  assert.ok(scopeSlot);
  assert.ok(title);
  assert.ok(scopeControl);
  assert.ok(reportingStatus);
  assert.equal(title.textContent, "用量概览");
  assert.deepEqual(Array.from(scopeSlot.children).map((element) => element.tagName), ["H1", "NAV"]);
  assert.deepEqual(Array.from(top.children).map((element) => element.className), [
    "dashboard-scope-slot",
    "speed-report-header-status",
  ]);
  assert.equal(reportingStatus.parentElement, top);

  assert.ok(dashHead);
  assert.ok(actionStrip);
  assert.ok(actions);
  assert.ok(dashHead.contains(actionStrip));
  assert.ok(dashHead.contains(actions));
  assert.equal(top.contains(actionStrip), false);
  assert.equal(top.contains(actions), false);

  assert.doesNotMatch(html, /Local User|Private Alias|dashboard-profile|account-row|account-name|brand-mark|avatar/i);
  assert.equal(document.querySelector(".floating-title-spacer"), null);
  window.close();
}));
