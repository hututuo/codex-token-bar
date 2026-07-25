import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { withSsrModules } from "../../test/ssrHarness.mjs";

function renderComponent(Component, props) {
  return renderToStaticMarkup(React.createElement(Component, props));
}

test("ProviderRepairActions allows sync without reusing a selected stale backup", async () => {
  await withSsrModules(async (load) => {
    const { buildProviderRepairActionModel } = await load("/src/components/providerRepair/actionModel.ts");
    const { ProviderRepairActions } = await load("/src/components/providerRepair/ProviderRepairActions.tsx");

    const model = buildProviderRepairActionModel({ busy: false, migrationCandidateCount: 2 });
    assert.equal(model.sync.disabled, false);
    assert.equal(model.sync.reason, null);
    assert.equal(model.backup.disabled, false);

    const html = renderComponent(ProviderRepairActions, actionProps());
    const syncButton = findButton(html, "3 安全修复");
    assert.doesNotMatch(syncButton.attrs, /disabled=""/);
    assert.doesNotMatch(html, /请先创建备份/);
  });
});

test("ProviderRepairActions disables conflicting actions while an operation is in flight", async () => {
  await withSsrModules(async (load) => {
    const { buildProviderRepairActionModel } = await load("/src/components/providerRepair/actionModel.ts");
    const { ProviderRepairActions } = await load("/src/components/providerRepair/ProviderRepairActions.tsx");

    const model = buildProviderRepairActionModel({ busy: true, migrationCandidateCount: 2 });
    assert.deepEqual(Object.values(model).map((action) => action.disabled), [true, true, true, true, true]);
    assert.equal(model.sync.reason, "正在执行修复操作，请等待当前步骤完成。");

    const html = renderComponent(ProviderRepairActions, actionProps({ busy: true }));
    for (const label of ["1 扫描", "2 创建备份", "3 安全修复", "4 迁移历史 (2)", "5 验证"]) {
      assert.match(findButton(html, label).attrs, /disabled=""/);
    }
    assert.doesNotMatch(html, /请先创建备份/);
  });
});

test("ProviderRepairBackups does not expose rollback without a backup", async () => {
  await withSsrModules(async (load) => {
    const { ProviderRepairBackups } = await load("/src/components/providerRepair/ProviderRepairBackups.tsx");
    const html = renderComponent(ProviderRepairBackups, backupsProps({ backups: [] }));

    assert.match(html, /暂无备份/);
    assert.match(html, /创建备份后，会在这里显示可回滚的时间点。/);
    assert.doesNotMatch(html, /repair-rollback-button/);
    assert.doesNotMatch(html, />回滚</);
  });
});

test("ProviderRepairBackups renders rollback only for real backups and disables it while busy", async () => {
  await withSsrModules(async (load) => {
    const { ProviderRepairBackups } = await load("/src/components/providerRepair/ProviderRepairBackups.tsx");
    const html = renderComponent(ProviderRepairBackups, backupsProps({
      activeBackupId: "backup-1",
      backups: [backupFixture()],
      busy: true,
    }));

    assert.match(html, /repair-backup repair-backup--active/);
    assert.match(html, /会话首行 7 · SQLite 一致性快照 ·\s*上下文文件 兼容备份/);
    assert.match(html, /目录 \.\.\.\/test\/\.codex/);
    const rollbackButton = findButton(html, "回滚");
    assert.match(rollbackButton.attrs, /class="repair-rollback-button"/);
    assert.match(rollbackButton.attrs, /disabled=""/);
  });
});

test("ProviderRepairBackups keeps v1 backups visible but disables unsupported rollback", async () => {
  await withSsrModules(async (load) => {
    const { ProviderRepairBackups } = await load("/src/components/providerRepair/ProviderRepairBackups.tsx");
    const html = renderComponent(ProviderRepairBackups, backupsProps({
      backups: [backupFixture({
        id: "legacy-backup-1",
        path: "/tmp/provider-repair/legacy-backup-1",
        restoreStatus: "legacyUnsupported",
        restoreUnsupportedReason: "旧版 v1 清单缺少可验证的成员摘要。",
      })],
    }));

    assert.match(html, /旧版备份，仅供查看/);
    assert.match(html, /\/tmp\/provider-repair\/legacy-backup-1/);
    assert.match(html, /repair-backup-path/);
    assert.match(html, /旧版 v1 清单缺少可验证的成员摘要。/);
    assert.match(html, /请创建新的差量恢复点后再回滚。/);
    const rollbackButton = findButton(html, "不支持回滚");
    assert.match(rollbackButton.attrs, /disabled=""/);
  });
});

test("ProviderRepairCard SSR starts from safe non-destructive actions", async () => {
  await withSsrModules(async (load) => {
    const { ProviderRepairCard } = await load("/src/components/ProviderRepairCard.tsx");
    const html = renderComponent(ProviderRepairCard, {
      id: "provider-repair",
      onSnapshotChange: () => {},
      snapshot: snapshotFixture(),
    });

    assert.match(html, /aria-label="会话消失修复"/);
    assert.match(html, /provider codex · 本地扫描 · 7 个会话文件/);
    assert.doesNotMatch(html, /请先创建备份/);
    assert.doesNotMatch(html, /repair-rollback-button/);
  });
});

function findButton(html, text) {
  const escapedText = text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const pattern = new RegExp(`<button(?<attrs>[^>]*)>${escapedText}</button>`);
  const match = html.match(pattern);
  assert.ok(match, `Expected button "${text}" in ${html}`);
  return {
    attrs: match.groups.attrs,
  };
}

function actionProps(overrides = {}) {
  return {
    busy: false,
    migrationCandidateCount: 2,
    onBackup: () => {},
    onMigrate: () => {},
    onScan: () => {},
    onSync: () => {},
    onVerify: () => {},
    ...overrides,
  };
}

function backupsProps(overrides = {}) {
  return {
    activeBackupId: null,
    backups: [],
    busy: false,
    onRollback: () => {},
    onSelectBackup: () => {},
    ...overrides,
  };
}

function backupFixture(overrides = {}) {
  return {
    id: "backup-1",
    createdAt: "2026-07-06T02:50:00Z",
    path: "/tmp/provider-repair/backup-1",
    codexHome: "/Users/test/.codex",
    codexHomeFingerprint: "fingerprint",
    sqliteHome: "/Users/test/.codex",
    sqliteHomeFingerprint: "fingerprint",
    targetProvider: "codex",
    sessionFiles: 7,
    stateDatabase: true,
    sessionIndex: true,
    restoreStatus: "supported",
    restoreUnsupportedReason: null,
    ...overrides,
  };
}

function snapshotFixture(overrides = {}) {
  return {
    detectedProvider: "codex",
    providerSource: "本地扫描",
    sqliteHome: "/Users/test/.codex",
    sessionFilesFound: 7,
    inconsistentCount: 0,
    migrationCandidateCount: 0,
    invalidSessionFiles: 0,
    ambiguousThreadCount: 0,
    status: "扫描完成，等待用户确认。",
    steps: [
      { label: "扫描", status: "已扫描", done: true, healthy: true },
      { label: "备份", status: "未备份", done: false, healthy: true },
      { label: "修复", status: "未修复", done: false, healthy: true },
      { label: "验证", status: "未验证", done: false, healthy: true },
    ],
    ...overrides,
  };
}
