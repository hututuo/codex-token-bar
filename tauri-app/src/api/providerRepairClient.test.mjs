import assert from "node:assert/strict";
import test from "node:test";
import { withSsrModules } from "../test/ssrHarness.mjs";

test("provider timeout latches safety while pre-admission status stays notStarted", async () => {
  await withSsrModules(async (load) => {
    const { executeProviderRepairMutation } = await load("/src/api/providerRepairClient.ts");
    const {
      createProviderRepairSafetyLatch,
      reconcileProviderRepairOperation,
    } = await load("/src/services/providerRepairOperationCoordinator.ts");
    const latch = createProviderRepairSafetyLatch();
    latch.completeBootstrap([]);

    await assert.rejects(executeProviderRepairMutation({
      mutation: async () => {
        throw new Error("Command timed out after 60000ms");
      },
      operationId: "operation-a",
      safetyLatch: latch,
    }), /timed out/i);
    assert.equal(latch.getSnapshot().phase, "uncertain");
    assert.deepEqual(latch.getSnapshot().operationIds, ["operation-a"]);

    const statuses = [
      { lifecycle: "notStarted", operationId: "operation-a" },
      { lifecycle: "active", operationId: "operation-a" },
      { lifecycle: "finished", operationId: "operation-a" },
    ];
    const outcome = await reconcileProviderRepairOperation({
      operationId: "operation-a",
      readStatus: async () => statuses.shift(),
      signal: new AbortController().signal,
      waitForNextPoll: async () => {},
    });
    assert.equal(outcome, "finished");
    assert.equal(latch.clearFinished("operation-a"), true);
    assert.equal(latch.getSnapshot().phase, "ready");
  });
});

test("timeout starts a fresh reconciliation generation after an early pre-admission budget is exhausted", async () => {
  await withSsrModules(async (load) => {
    const { executeProviderRepairMutation } = await load("/src/api/providerRepairClient.ts");
    const {
      createProviderRepairSafetyLatch,
      reconcileProviderRepairOperation,
    } = await load("/src/services/providerRepairOperationCoordinator.ts");
    const latch = createProviderRepairSafetyLatch();
    latch.completeBootstrap([]);
    const invoke = deferred();
    const mutation = executeProviderRepairMutation({
      mutation: () => invoke.promise,
      operationId: "operation-ordering",
      safetyLatch: latch,
    });
    const pending = latch.getSnapshot();
    assert.equal(pending.phase, "invokePending");

    let admitted = false;
    const earlyOutcome = await reconcileProviderRepairOperation({
      maxNotStartedReads: 2,
      operationId: "operation-ordering",
      readStatus: async () => ({
        lifecycle: admitted ? "active" : "notStarted",
        operationId: "operation-ordering",
      }),
      signal: new AbortController().signal,
      waitForNextPoll: async () => {},
    });
    assert.equal(earlyOutcome, "statusUnavailable");

    admitted = true;
    invoke.reject(new Error("Command timed out after 60000ms"));
    await assert.rejects(mutation, /timed out/i);
    const uncertain = latch.getSnapshot();
    assert.equal(uncertain.phase, "uncertain");
    assert.ok(uncertain.generation > pending.generation);

    const statuses = [
      { lifecycle: "active", operationId: "operation-ordering" },
      { lifecycle: "finished", operationId: "operation-ordering" },
    ];
    assert.equal(await reconcileProviderRepairOperation({
      operationId: "operation-ordering",
      readStatus: async () => statuses.shift(),
      signal: new AbortController().signal,
      waitForNextPoll: async () => {},
    }), "finished");
  });
});

test("typed busy rejection survives command normalization and latches the real owner", async () => {
  await withSsrModules(async (load) => {
    const { normalizeCommandError } = await load("/src/api/command.ts");
    const { executeProviderRepairMutation } = await load("/src/api/providerRepairClient.ts");
    const { createProviderRepairSafetyLatch } = await load(
      "/src/services/providerRepairOperationCoordinator.ts",
    );
    const latch = createProviderRepairSafetyLatch();
    latch.completeBootstrap([]);
    const normalized = normalizeCommandError({
      kind: "busy",
      activeOperationId: "operation-owner",
      message: "同一 Codex Home 正在执行另一个 Provider 写操作。",
    });

    await assert.rejects(executeProviderRepairMutation({
      mutation: async () => {
        throw normalized;
      },
      operationId: "operation-contender",
      safetyLatch: latch,
    }), /同一 Codex Home/);

    assert.deepEqual(latch.getSnapshot().operationIds, ["operation-owner"]);
  });
});

test("legacy Provider backup compatibility remains explicit at the API boundary", async () => {
  await withSsrModules(async (load) => {
    const { isProviderBackupRollbackSupported } = await load("/src/api/providerRepairClient.ts");
    const legacy = {
      id: "legacy-backup-1",
      path: "/tmp/provider-repair/legacy-backup-1",
      restoreStatus: "legacyUnsupported",
      restoreUnsupportedReason: "旧版 v1 清单缺少可验证的成员摘要。",
    };

    assert.equal(isProviderBackupRollbackSupported(legacy), false);
    assert.equal(legacy.path, "/tmp/provider-repair/legacy-backup-1");
    assert.match(legacy.restoreUnsupportedReason, /v1/);
  });
});

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, reject, resolve };
}
