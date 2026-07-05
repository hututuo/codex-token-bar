import assert from "node:assert/strict";
import test from "node:test";
import { withSsrModules } from "../../test/ssrHarness.mjs";

test("provider repair drops stale non-destructive completions after replacement", async () => {
  await withSsrModules(async (load) => {
    const { createProviderRepairOperationController } = await load(
      "/src/components/providerRepair/operationController.ts",
    );
    const controller = createProviderRepairOperationController();
    const state = publishedState();

    const scan = controller.start("scan");
    const verify = controller.start("verify");

    assert.equal(scan.started, true);
    assert.equal(verify.started, true);

    if (controller.finish(verify.operation)) {
      publish(state, {
        activeBackupId: "verify-backup",
        backups: [backupFixture("verify-backup")],
        message: "验证完成",
        snapshot: snapshotFixture("verify"),
      });
    }
    if (controller.finish(scan.operation)) {
      publish(state, {
        activeBackupId: "scan-backup",
        backups: [backupFixture("scan-backup")],
        message: "旧扫描完成",
        snapshot: snapshotFixture("scan"),
      });
    }

    assert.equal(state.snapshot.detectedProvider, "verify");
    assert.equal(state.message, "验证完成");
    assert.equal(state.backups[0].id, "verify-backup");
    assert.equal(state.activeBackupId, "verify-backup");
    assert.equal(controller.activeKind(), null);
  });
});

test("provider repair blocks destructive work while any operation is active", async () => {
  await withSsrModules(async (load) => {
    const { createProviderRepairOperationController } = await load(
      "/src/components/providerRepair/operationController.ts",
    );
    const controller = createProviderRepairOperationController();

    const scan = controller.start("scan");
    const backup = controller.start("backup");
    const sync = controller.start("sync");
    const rollback = controller.start("rollback");

    assert.equal(scan.started, true);
    assert.equal(backup.started, false);
    assert.equal(sync.started, false);
    assert.equal(rollback.started, false);
    assert.equal(backup.message, "正在执行修复操作，请等待当前步骤完成。");
    assert.equal(sync.message, "正在执行修复操作，请等待当前步骤完成。");
    assert.equal(rollback.message, "正在执行修复操作，请等待当前步骤完成。");
    assert.equal(controller.activeKind(), "scan");
  });
});

test("provider repair ignores an old failure after a newer success", async () => {
  await withSsrModules(async (load) => {
    const { createProviderRepairOperationController } = await load(
      "/src/components/providerRepair/operationController.ts",
    );
    const controller = createProviderRepairOperationController();
    const state = publishedState();

    const scan = controller.start("scan");
    const verify = controller.start("verify");

    if (controller.finish(verify.operation)) {
      publish(state, {
        activeBackupId: "verify-backup",
        backups: [backupFixture("verify-backup")],
        message: "验证完成",
        snapshot: snapshotFixture("verify"),
      });
    }
    if (controller.finish(scan.operation)) {
      state.message = "旧扫描失败";
      state.snapshot = snapshotFixture("scan");
      state.backups = [];
      state.activeBackupId = null;
    }

    assert.equal(state.snapshot.detectedProvider, "verify");
    assert.equal(state.message, "验证完成");
    assert.equal(state.backups[0].id, "verify-backup");
    assert.equal(state.activeBackupId, "verify-backup");
  });
});

test("provider repair serializes non-destructive work behind destructive work", async () => {
  await withSsrModules(async (load) => {
    const { createProviderRepairOperationController } = await load(
      "/src/components/providerRepair/operationController.ts",
    );
    const controller = createProviderRepairOperationController();

    const backup = controller.start("backup");
    const verify = controller.start("verify");

    assert.equal(backup.started, true);
    assert.equal(verify.started, false);
    assert.equal(verify.message, "正在执行修复操作，请等待当前步骤完成。");
    assert.equal(controller.activeKind(), "backup");
  });
});

function publishedState() {
  return {
    activeBackupId: null,
    backups: [],
    message: "",
    snapshot: snapshotFixture("initial"),
  };
}

function publish(state, next) {
  state.activeBackupId = next.activeBackupId;
  state.backups = next.backups;
  state.message = next.message;
  state.snapshot = next.snapshot;
}

function snapshotFixture(provider) {
  return {
    detectedProvider: provider,
    providerSource: "test",
    sessionFilesFound: 1,
    inconsistentCount: 0,
    status: `${provider} status`,
    steps: [],
  };
}

function backupFixture(id) {
  return {
    id,
    createdAt: "2026-07-06T03:00:00Z",
    path: `/tmp/${id}`,
    codexHome: "/Users/test/.codex",
    codexHomeFingerprint: "fingerprint",
    targetProvider: "codex",
    sessionFiles: 1,
    stateDatabase: true,
    sessionIndex: true,
  };
}
