import assert from "node:assert/strict";
import test from "node:test";
import { withSsrModules } from "../test/ssrHarness.mjs";

test("provider timeout latches safety while pre-admission status stays notStarted", async () => {
  await withSsrModules(async (load) => {
    const { executeProviderRepairMutation } = await load("/src/api/providerRepairClient.ts");
    const {
      createProviderRepairSafetyLatch,
      reconcileProviderRepairOperation,
    } = await load("/src/components/providerRepair/providerOperationCoordinator.ts");
    const latch = createProviderRepairSafetyLatch();

    await assert.rejects(executeProviderRepairMutation({
      mutation: async () => {
        throw new Error("Command timed out after 60000ms");
      },
      operationId: "operation-a",
      safetyLatch: latch,
    }), /timed out/i);
    assert.equal(latch.getSnapshot(), "operation-a");

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
    assert.equal(latch.getSnapshot(), null);
  });
});

test("typed busy rejection survives command normalization and latches the real owner", async () => {
  await withSsrModules(async (load) => {
    const { normalizeCommandError } = await load("/src/api/command.ts");
    const { executeProviderRepairMutation } = await load("/src/api/providerRepairClient.ts");
    const { createProviderRepairSafetyLatch } = await load(
      "/src/components/providerRepair/providerOperationCoordinator.ts",
    );
    const latch = createProviderRepairSafetyLatch();
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

    assert.equal(latch.getSnapshot(), "operation-owner");
  });
});
