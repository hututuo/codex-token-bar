import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { Window } from "happy-dom";
import { withSsrModules } from "../../test/ssrHarness.mjs";

test("overview title, client scope, and report status share the top row", async () => withSsrModules(async (load) => {
  const { DashboardHeader } = await load("/src/components/DashboardHeader.tsx");
  const props = {
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
  };
  const html = renderToStaticMarkup(React.createElement(DashboardHeader, props));

  const window = new Window();
  window.document.body.innerHTML = html;
  const { document } = window;
  const top = document.querySelector(".dashboard-header-top");
  const scopeSlot = document.querySelector(".dashboard-scope-slot");
  const title = document.querySelector("h1.dashboard-overview-title");
  const scopeControl = document.querySelector('[aria-label="统计客户端范围"]');
  const reportingStatus = document.querySelector(".speed-report-header-status");
  const dashHead = document.querySelector(".dash-head");
  const globals = document.querySelector('[aria-label="全局工具"]');
  const codex = document.querySelector('[aria-label="Codex 专属工具"]');
  assert.ok(top && scopeSlot && title && scopeControl && reportingStatus);
  assert.equal(title.textContent, "用量概览");
  assert.deepEqual(Array.from(scopeSlot.children).map(element => element.tagName), ["H1", "NAV"]);
  assert.equal(globals.parentElement, top);
  assert.ok(globals.contains(reportingStatus));
  assert.match(globals.textContent, /立即刷新.*设置.*完整日志.*更多/);
  assert.doesNotMatch(globals.textContent, /会话管理|会话增强|自动续跑|更改目录/);
  assert.ok(dashHead === codex);
  assert.match(codex.textContent, /Codex.*专属工具/);
  assert.match(codex.textContent, /会话管理.*会话增强.*自动续跑/);
  assert.equal(top.contains(codex), false);
  assert.equal(document.querySelector('.dash-head__strip'), null);
  assert.equal(document.querySelector('.dash-head__top--actions-only'), null);

  assert.doesNotMatch(html, /Local User|Private Alias|dashboard-profile|account-row|account-name|brand-mark|avatar/i);
  assert.equal(document.querySelector(".floating-title-spacer"), null);
  const claudeOnly = renderToStaticMarkup(React.createElement(DashboardHeader, {...props, includesCodex:false}));
  assert.doesNotMatch(claudeOnly, /Codex 专属工具|会话管理|会话增强|自动续跑|更改 Codex 数据目录/);
  assert.match(claudeOnly, /全局工具|立即刷新/);
  window.close();
}));
