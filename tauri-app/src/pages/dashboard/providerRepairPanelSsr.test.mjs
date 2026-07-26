import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { withSsrModules } from "../../test/ssrHarness.mjs";

function renderComponent(Component, props) {
  return renderToStaticMarkup(React.createElement(Component, props));
}

test("ProviderRepairPanel renders safe advanced repair flow when open", async () => {
  await withSsrModules(async (load) => {
    const { ProviderRepairPanel } = await load("/src/pages/dashboard/ProviderRepairPanel.tsx");
    const html = renderComponent(ProviderRepairPanel, panelProps());

    assert.match(html, /role="dialog"/);
    assert.match(html, /aria-label="会话消失修复"/);
    assert.match(html, /先扫描并创建差量恢复点；安全修复与历史迁移严格分开。/);
    assert.match(html, /Codex Desktop 运行时仍可扫描、验证和创建备份；同步与回滚会被后端拒绝。/);
    assert.match(html, /写操作会先保存 SQLite 一致性快照和必要的会话首行，不再复制整份历史文件。/);
    assert.match(html, /会话修复尚未扫描。需要时点击扫描/);
    assert.match(findButton(html, "关闭").attrs, /title="关闭会话消失修复"/);
    assert.match(findButton(html, "3 安全修复").attrs, /disabled=""/);
    assert.doesNotMatch(html, /repair-rollback-button/);
  });
});

test("ProviderRepairPanel does not render a repair card when closed", async () => {
  await withSsrModules(async (load) => {
    const { ProviderRepairPanel } = await load("/src/pages/dashboard/ProviderRepairPanel.tsx");
    const html = renderComponent(ProviderRepairPanel, panelProps({ open: false }));

    assert.equal(html, "");
  });
});

test("ProviderRepairPanel model disables close while a repair operation is busy", async () => {
  await withSsrModules(async (load) => {
    const { buildProviderRepairPanelModel } = await load(
      "/src/pages/dashboard/providerRepairPanelModel.ts",
    );

    assert.deepEqual(buildProviderRepairPanelModel({ closeBlocked: false, open: true, snapshot: snapshotFixture() }), {
      closeDisabled: false,
      closeTitle: "关闭会话消失修复",
      autoScanOnMount: true,
    });
    assert.deepEqual(buildProviderRepairPanelModel({ closeBlocked: true, open: true, snapshot: snapshotFixture() }), {
      closeDisabled: true,
      closeTitle: "正在执行修复操作，请等待当前步骤完成。",
      autoScanOnMount: false,
    });
  });
});

test("ProviderRepairPanel model scans only when opened on an unscanned repair snapshot", async () => {
  await withSsrModules(async (load) => {
    const { buildProviderRepairPanelModel } = await load(
      "/src/pages/dashboard/providerRepairPanelModel.ts",
    );

    assert.equal(
      buildProviderRepairPanelModel({ closeBlocked: false, open: true, snapshot: snapshotFixture() }).autoScanOnMount,
      true,
    );
    assert.equal(
      buildProviderRepairPanelModel({ closeBlocked: false, open: false, snapshot: snapshotFixture() }).autoScanOnMount,
      false,
    );
    assert.equal(
      buildProviderRepairPanelModel({
        closeBlocked: false,
        open: true,
        snapshot: snapshotFixture({
          detectedProvider: "codex",
          sessionFilesFound: 42,
          status: "扫描完成",
          steps: [
            { label: "扫描", status: "已扫描", done: true, healthy: true },
          ],
        }),
      }).autoScanOnMount,
      false,
    );
  });
});

test("Provider repair card remounts on exact dashboard source token without resetting the global safety latch", async () => {
  const [appSource, pageSource, panelSource, cardSource, dashboardDataSource] = await Promise.all([
    readFile(new URL("../../app/DashboardApp.tsx", import.meta.url), "utf8"),
    readFile(new URL("../DashboardPage.tsx", import.meta.url), "utf8"),
    readFile(new URL("./ProviderRepairPanel.tsx", import.meta.url), "utf8"),
    readFile(new URL("../../components/ProviderRepairCard.tsx", import.meta.url), "utf8"),
    readFile(new URL("../../state/useDashboardData.ts", import.meta.url), "utf8"),
  ]);

  assert.match(appSource, /providerSourceKey={providerSourceKey}/);
  assert.match(pageSource, /providerSourceKey={providerSourceKey}/);
  assert.match(panelSource, /key={providerSourceKey}/);
  assert.match(panelSource, /providerSourceKey: string/);
  assert.match(cardSource, /providerRepairSafetyLatch/);
  assert.match(dashboardDataSource, /sourceToken\.physicalHomeKey/);
});

function findButton(html, text) {
  const pattern = new RegExp(`<button(?<attrs>[^>]*)>${text}</button>`);
  const match = html.match(pattern);
  assert.ok(match, `Expected button "${text}" in ${html}`);
  return {
    attrs: match.groups.attrs,
  };
}

function panelProps(overrides = {}) {
  return {
    onClose: () => {},
    onSnapshotChange: () => {},
    open: true,
    providerSourceKey: "1:/source/A",
    snapshot: snapshotFixture(),
    ...overrides,
  };
}

function snapshotFixture(overrides = {}) {
  return {
    detectedProvider: "未扫描",
    providerSource: "手动扫描",
    sqliteHome: "待读取",
    sessionFilesFound: 0,
    inconsistentCount: 0,
    status: "会话修复尚未扫描。需要时点击扫描，应用不会在启动时自动读取修复范围。",
    steps: [
      { label: "扫描", status: "未扫描", done: false, healthy: true },
      { label: "备份", status: "未备份", done: false, healthy: true },
      { label: "修复", status: "未进行修复", done: false, healthy: true },
      { label: "验证", status: "未验证", done: false, healthy: true },
    ],
    ...overrides,
  };
}
