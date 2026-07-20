import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { withSsrModules } from "../../test/ssrHarness.mjs";

function renderComponent(Component, props) {
  return renderToStaticMarkup(React.createElement(Component, props));
}

test("DashboardHeader renders restrained provider repair entry", async () => {
  await withSsrModules(async (load) => {
    const { DashboardHeader } = await load("/src/components/DashboardHeader.tsx");
    const html = renderComponent(DashboardHeader, headerProps());

    const button = findButton(html, "会话消失修复");
    assert.match(button.attrs, /class="toolbar-button/);
    assert.match(button.attrs, /title="找回消失的历史会话"/);
    assert.match(html, /class="header-context"/);
    assert.equal((html.match(/class="header-info-cell/g) ?? []).length, 3);
    assert.equal((html.match(/class="header-info-kicker"/g) ?? []).length, 3);
    assert.equal((html.match(/class="header-info-main"/g) ?? []).length, 3);
    assert.equal((html.match(/class="header-action-divider"/g) ?? []).length, 2);
    assert.match(html, /class="header-info-kicker">Codex Token Bar/);
    assert.match(html, /class="header-info-kicker">数据源/);
    assert.match(html, /class="header-info-kicker">统计状态/);
    assert.match(html, /class="platform-badge">跨平台版/);
    assert.match(html, /class="header-data-mode">本地统计/);
    assert.match(html, /class="header-primary-actions" aria-label="常用操作"/);
    assert.match(html, /class="header-action-group header-action-group--primary"/);
    assert.match(html, /class="header-action-group header-action-group--maintenance"/);
    assert.match(html, /class="header-action-group header-action-group--export"/);
    assert.match(html, /立即刷新/);
    assert.match(html, /检查更新/);
    assert.match(html, /开机自启：关/);
    assert.match(html, /更改目录/);
    assert.match(html, />会话增强<\/button>/);
    assert.match(html, />自动续跑<\/button>/);
    assert.match(html, />设置<\/button>/);
    assert.match(html, /导出 CSV/);
    assert.match(html, /导出 PNG/);
    assert.doesNotMatch(html, /更多操作|启用侧栏删除|启用会话删除/);
  });
});

test("DashboardHeader exposes complete update states on the primary action", async () => {
  await withSsrModules(async (load) => {
    const { DashboardHeader } = await load("/src/components/DashboardHeader.tsx");
    const available = renderComponent(DashboardHeader, headerProps({
      appUpdateState: { kind: "available", message: "发现新版本 v0.7.4" },
    }));
    const failed = renderComponent(DashboardHeader, headerProps({
      appUpdateState: { kind: "error", message: "暂时无法检查更新，请稍后重试" },
    }));

    assert.match(available, /class="toolbar-button update-action update-action--available"[^>]*title="发现新版本 v0.7.4"[^>]*>安装更新<\/button>/);
    assert.match(failed, /class="toolbar-button update-action update-action--error"[^>]*title="暂时无法检查更新，请稍后重试"[^>]*>重试更新检查<\/button>/);
    assert.match(failed, /aria-live="polite"/);
  });
});

function findButton(html, text) {
  const pattern = new RegExp(`<button(?<attrs>[^>]*)>${text}</button>`);
  const match = html.match(pattern);
  assert.ok(match, `Expected button "${text}" in ${html}`);
  return {
    attrs: match.groups.attrs,
  };
}

function headerProps(overrides = {}) {
  return {
    account: {
      displayName: "Test User",
      planLabel: "Plus",
    },
    autoResumeEnabled: false,
    appUpdateState: {
      kind: "idle",
      message: "",
    },
    autostartStatus: {
      available: true,
      enabled: false,
      status: "disabled",
      message: "ready",
    },
    codexHome: {
      exists: true,
      path: "/Users/test/.codex",
      source: "auto",
    },
    customAccountDisplayName: "",
    generatedAt: "2026-07-06T03:20:00.000Z",
    onCheckForUpdate: async () => {},
    onCodexHomeChange: async () => {},
    onCodexHomeReset: async () => {},
    onCustomAccountDisplayNameChange: async () => {},
    onExportCsv: () => {},
    onExportPng: () => {},
    onOpenProviderRepair: () => {},
    onOpenSettings: () => {},
    onRefresh: async () => {},
    onToggleAutostart: () => {},
    refreshing: false,
    threadDeleteBridgeStatus: {
      connected: false,
      debugPort: null,
      message: "等待 Codex 调试连接（需以调试模式启动 Codex）",
    },
    ...overrides,
  };
}
