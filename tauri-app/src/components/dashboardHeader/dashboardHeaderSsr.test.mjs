import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { withSsrModules } from "../../test/ssrHarness.mjs";

function renderComponent(Component, props) {
  return renderToStaticMarkup(React.createElement(Component, props));
}

test("DashboardHeader keeps the account identity above the compact product card", async () => {
  await withSsrModules(async (load) => {
    const { DashboardHeader } = await load("/src/components/DashboardHeader.tsx");
    const html = renderComponent(DashboardHeader, headerProps());

    assert.match(html, /class="dashboard-header"/);
    assert.match(html, /class="brand-mark">CX/);
    assert.match(html, /class="account-row"/);
    assert.match(html, /class="account-name">Test User/);
    assert.match(html, /class="dash-head"/);
    assert.match(html, /class="dash-head__top dash-head__top--actions-only"/);
    assert.match(html, /class="dash-head__strip"/);
    assert.match(html, /class="dash-head__platform"/);
    assert.match(html, />Codex Token Bar</);
    assert.match(html, /class="plan-badge">Plus/);
    assert.match(html, /class="platform-runtime">Tauri/);
    assert.match(html, /总 5 · 主 2 · 子 3/);
    assert.match(html, /class="platform-badge">跨平台版/);
    assert.ok(html.indexOf('class="plan-badge"') < html.indexOf('class="platform-badge"'));
    assert.match(html, /class="dash-head__actions"/);
    assert.match(html, /立即刷新/);
    assert.match(html, />更改目录<\/button>/);
    assert.match(html, />会话消失修复<\/button>/);
    assert.match(html, />会话管理<\/button>/);
    assert.match(html, /aria-label="会话增强"/);
    assert.match(html, /aria-label="自动续跑"/);
    assert.match(html, />设置<\/button>/);
    assert.match(html, /aria-label="更多操作"/);
    assert.doesNotMatch(html, /dash-head__mark|dash-head__identity|dash-head__name/);
    assert.ok(html.indexOf('class="account-row"') < html.indexOf('class="dash-head"'));
    assert.ok(html.indexOf('class="dash-head__strip"') < html.indexOf('class="dash-head__top dash-head__top--actions-only"'));
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

test("DashboardHeader renders phase labels, counts, reassurance, and explicit terminal states", async () => {
  await withSsrModules(async (load) => {
    const { DashboardHeader } = await load("/src/components/DashboardHeader.tsx");
    const upgrading = renderComponent(DashboardHeader, headerProps({
      usageSummaryFresh: true,
      preciseProgress: {
        phase: "migrating",
        message: "正在升级索引字段",
        completed: 2,
        total: 4,
        fraction: 0.5,
        startedAt: "2026-07-06T02:30:00.000Z",
        updatedAt: "2026-07-06T02:30:10.000Z",
      },
    }));
    assert.match(upgrading, /索引升级/);
    assert.match(upgrading, /2\/4/);
    assert.match(upgrading, /首次升级可能需要几分钟，可能短暂占用 CPU 和磁盘，原始数据不会丢失/);
    assert.match(upgrading, /role="progressbar"/);

    const model = renderComponent(DashboardHeader, headerProps({
      preciseProgress: {
        phase: "scanning",
        message: "补齐 reasoning 字段",
        completed: 3,
        total: 8,
        fraction: 0.375,
        startedAt: "2026-07-06T02:30:00.000Z",
        updatedAt: "2026-07-06T02:30:10.000Z",
      },
    }));
    assert.match(model, /历史模型补全/);
    assert.match(model, /3\/8/);

    const complete = renderComponent(DashboardHeader, headerProps({
      preciseProgress: {
        phase: "complete",
        message: "精确统计已更新",
        completed: 1,
        total: 1,
        fraction: 1,
        startedAt: "2026-07-06T02:30:00.000Z",
        updatedAt: "2026-07-06T02:30:10.000Z",
      },
    }));
    assert.match(complete, /已就绪/);
    assert.doesNotMatch(complete, /首次升级可能需要几分钟/);
    assert.doesNotMatch(complete, /role="progressbar"/);

    const failed = renderComponent(DashboardHeader, headerProps({
      preciseProgress: {
        phase: "failed",
        message: "保留上次可信数据",
        completed: 1,
        total: 4,
        fraction: 0.25,
        startedAt: "2026-07-06T02:30:00.000Z",
        updatedAt: "2026-07-06T02:30:10.000Z",
      },
    }));
    assert.match(failed, /失败/);
    assert.match(failed, /1\/4/);
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
