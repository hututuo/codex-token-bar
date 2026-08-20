import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { withSsrModules } from "../../test/ssrHarness.mjs";

import {
  committedCustomAccountDisplayName,
  resolveAccountDisplayName,
  shouldCommitDisplayNameOnKey,
} from "./model.ts";

function renderComponent(Component, props) {
  return renderToStaticMarkup(React.createElement(Component, props));
}

test("account display name uses trimmed custom name with account fallback", () => {
  assert.equal(resolveAccountDisplayName("Official User", "  Lab Alias  "), "Lab Alias");
  assert.equal(resolveAccountDisplayName("Official User", "   "), "Official User");
});

test("custom display-name commit trims draft and only skips unchanged custom values", () => {
  assert.equal(committedCustomAccountDisplayName("  New Alias  ", "Old Alias"), "New Alias");
  assert.equal(committedCustomAccountDisplayName("  Old Alias  ", "Old Alias"), null);
  assert.equal(committedCustomAccountDisplayName("Official User", ""), "Official User");
});

test("display-name edit commits only on Enter key", () => {
  assert.equal(shouldCommitDisplayNameOnKey("Enter"), true);
  assert.equal(shouldCommitDisplayNameOnKey("Escape"), false);
  assert.equal(shouldCommitDisplayNameOnKey("Tab"), false);
});

test("DashboardHeader edit mode keeps a narrow blur and Enter wiring guard", async () => {
  const source = await readFile(new URL("../DashboardHeader.tsx", import.meta.url), "utf8");
  const editBlock = source.slice(
    source.indexOf("{editingDisplayName ? ("),
    source.indexOf(") : ("),
  );
  const keyHandler = source.slice(
    source.indexOf("function handleDisplayNameKeyDown"),
    source.indexOf("return (", source.indexOf("function handleDisplayNameKeyDown")),
  );
  const buttonBlock = source.slice(
    source.indexOf('<button className="account-name-button"'),
    source.indexOf("</button>", source.indexOf('<button className="account-name-button"')) + "</button>".length,
  );

  assert.equal(buttonBlock.includes("onClick={beginEditDisplayName}"), true);
  assert.equal(buttonBlock.includes("account-name-pencil"), true);
  assert.equal(editBlock.includes("className=\"account-name-edit\""), true);
  assert.equal(editBlock.includes("onBlur={commitDisplayName}"), true);
  assert.equal(editBlock.includes("onKeyDown={handleDisplayNameKeyDown}"), true);
  assert.equal(keyHandler.includes("shouldCommitDisplayNameOnKey(event.key)"), true);
  assert.equal(keyHandler.includes("event.currentTarget.blur()"), true);
});

test("DashboardHeader renders the resolved account name without the local diagnostics strip", async () => {
  await withSsrModules(async (load) => {
    const { DashboardHeader } = await load("/src/components/DashboardHeader.tsx");
    const html = renderComponent(DashboardHeader, headerProps({
      customAccountDisplayName: "  Lab Alias  ",
    }));

    assert.match(html, /Lab Alias/);
    assert.doesNotMatch(html, /Official User/);
    assert.match(html, /account-name-button/);
    assert.match(html, /brand-mark/);
    assert.doesNotMatch(html, /dash-head__name/);
    assert.doesNotMatch(html, /account-name-edit/);
    assert.doesNotMatch(html, /DiagnosticStrip/);
    assert.doesNotMatch(html, /diagnostic-strip/);
  });
});

test("DashboardHeader falls back to the account display name when custom name is blank", async () => {
  await withSsrModules(async (load) => {
    const { DashboardHeader } = await load("/src/components/DashboardHeader.tsx");
    const html = renderComponent(DashboardHeader, headerProps({
      customAccountDisplayName: "  ",
    }));

    assert.match(html, /Official User/);
    assert.doesNotMatch(html, /Lab Alias/);
  });
});

test("DashboardHeader renders the Chinese updated timestamp and refresh progress", async () => {
  await withSsrModules(async (load) => {
    const { DashboardHeader } = await load("/src/components/DashboardHeader.tsx");
    const idle = renderComponent(DashboardHeader, headerProps());
    const refreshing = renderComponent(DashboardHeader, headerProps({
      refreshing: true,
      usageSummaryFresh: false,
    }));

    assert.match(idle, /更新于 \d{2}:\d{2}:\d{2}/);
    assert.doesNotMatch(idle, /Updated/);
    assert.match(refreshing, /摘要 \d{2}:\d{2}:\d{2} · 同步中/);
    assert.doesNotMatch(refreshing, /更新于 同步中/);
    assert.doesNotMatch(refreshing, /Updated|refresh-label/);
  });
});

test("DashboardHeader cannot look complete before the full model and chart snapshot is current", async () => {
  await withSsrModules(async (load) => {
    const { DashboardHeader } = await load("/src/components/DashboardHeader.tsx");
    const html = renderComponent(DashboardHeader, headerProps({
      aggregateCoveredAt: null,
      preciseDataFresh: false,
      usageSummaryFresh: true,
      preciseProgress: {
        phase: "complete",
        message: "精确统计数值已更新",
        completed: 1,
        total: 1,
        fraction: 1,
        startedAt: "2026-07-06T02:30:00.000Z",
        updatedAt: "2026-07-06T02:30:10.000Z",
      },
    }));

    assert.match(html, /class="dash-head__freshness is-waiting"/);
    assert.match(html, /等待精确统计/);
    assert.match(html, /摘要 \d{2}:\d{2}:\d{2} · 模型与图表同步中/);
    assert.doesNotMatch(html, /摘要 \d{2}:\d{2}:\d{2} · 图表至/);
  });
});

test("DashboardHeader keeps light-summary data while publishing progress remains visible", async () => {
  await withSsrModules(async (load) => {
    const { DashboardHeader } = await load("/src/components/DashboardHeader.tsx");
    const html = renderComponent(DashboardHeader, headerProps({
      refreshing: true,
      usageSummaryFresh: true,
      usageSummaryUpdatedAt: "2026-07-06T02:31:00.000Z",
      aggregateCoveredAt: "2026-07-06T02:20:00.000Z",
      preciseProgress: {
        phase: "publishing",
        message: "正在发布精确统计结果",
        completed: 1,
        total: 2,
        fraction: 0.5,
        startedAt: "2026-07-06T02:30:00.000Z",
        updatedAt: "2026-07-06T02:30:10.000Z",
      },
    }));

    assert.match(html, /class="dash-head__freshness is-publishing"/);
    assert.match(html, /发布精确统计/);
    assert.match(html, /正在发布精确统计结果/);
    assert.match(html, /1\/2/);
    assert.match(html, /首次升级可能需要几分钟，可能短暂占用 CPU 和磁盘，原始数据不会丢失/);
    assert.match(html, /class="precise-progress-bar"/);
    assert.doesNotMatch(html, /摘要 10:31:00 · 图表至 10:20/);
    assert.doesNotMatch(html, /同步中/);
  });
});

function headerProps(overrides = {}) {
  return {
    account: {
      displayName: "Official User",
      planLabel: "Pro",
    },
    autoResumeEnabled: false,
    appUpdateState: {
      kind: "idle",
      message: "",
    },
    autostartStatus: {
      available: true,
      enabled: false,
      message: "ready",
    },
    codexHome: {
      exists: true,
      path: "/Users/test/.codex",
      source: "auto",
    },
    customAccountDisplayName: "",
    generatedAt: "2026-07-06T02:30:00.000Z",
    onCheckForUpdate: async () => {},
    onCodexHomeChange: async () => {},
    onCodexHomeReset: async () => {},
    onCustomAccountDisplayNameChange: async () => {},
    onExportCsv: () => {},
    onExportPng: () => {},
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
