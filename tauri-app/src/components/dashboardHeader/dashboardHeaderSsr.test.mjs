import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { withSsrModules } from "../../test/ssrHarness.mjs";

function renderComponent(Component, props) {
  return renderToStaticMarkup(React.createElement(Component, props));
}

test("DashboardHeader renders one product card with compact primary actions and status strip", async () => {
  await withSsrModules(async (load) => {
    const { DashboardHeader } = await load("/src/components/DashboardHeader.tsx");
    const html = renderComponent(DashboardHeader, headerProps());

    assert.match(html, /class="dashboard-header dash-head"/);
    assert.match(html, /class="dash-head__top"/);
    assert.match(html, /class="dash-head__strip"/);
    assert.match(html, /class="dash-head__mark">CX/);
    assert.match(html, />Codex Token Bar</);
    assert.match(html, /总 5 · 主 2 · 子 3/);
    assert.match(html, /class="platform-badge">跨平台版/);
    assert.match(html, /class="dash-head__actions"/);
    assert.match(html, /立即刷新/);
    assert.match(html, />设置<\/button>/);
    assert.match(html, /aria-label="更多操作"/);
    assert.doesNotMatch(html, /role="menu"|启用侧栏删除|启用会话删除/);
  });
});

test("DashboardHeader marks update states on the More entry without expanding the menu in SSR", async () => {
  await withSsrModules(async (load) => {
    const { DashboardHeader } = await load("/src/components/DashboardHeader.tsx");
    const available = renderComponent(DashboardHeader, headerProps({
      appUpdateState: { kind: "available", message: "发现新版本 v0.7.4" },
    }));
    const failed = renderComponent(DashboardHeader, headerProps({
      appUpdateState: { kind: "error", message: "暂时无法检查更新，请稍后重试" },
    }));

    assert.match(available, /aria-label="更新需要处理"/);
    assert.match(failed, /aria-label="更新需要处理"/);
    assert.doesNotMatch(available, /安装更新<\/button>/);
    assert.doesNotMatch(failed, /重试更新检查<\/button>/);
  });
});

test("DashboardHeader running thread states never turn loading into fake zero", async () => {
  await withSsrModules(async (load) => {
    const { runningThreadHeaderText } = await load("/src/components/DashboardHeader.tsx");
    const pending = {
      total: null,
      mainThreads: null,
      subagents: null,
      status: "scanning",
      updatedAt: null,
      detail: "loading",
      livenessLeaseHours: 24,
    };

    assert.equal(runningThreadHeaderText(pending), "正在读取…");
    assert.equal(runningThreadHeaderText({ ...pending, status: "unavailable" }), "暂不可用");
    assert.equal(runningThreadHeaderText({
      ...pending,
      total: 4,
      mainThreads: 1,
      subagents: 3,
      status: "stale",
    }), "上次 · 总 4 · 主 1 · 子 3");
  });
});

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
    onOpenSessionManagement: () => {},
    onOpenSettings: () => {},
    onRefresh: async () => {},
    onToggleAutostart: () => {},
    refreshing: false,
    threadDeleteBridgeStatus: {
      connected: false,
      debugPort: null,
      message: "等待 Codex 调试连接（需以调试模式启动 Codex）",
    },
    runningThreads: {
      total: 5,
      mainThreads: 2,
      subagents: 3,
      status: "ready",
      updatedAt: 1,
      detail: "test",
      livenessLeaseHours: 24,
    },
    ...overrides,
  };
}
