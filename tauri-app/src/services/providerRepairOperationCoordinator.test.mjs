import assert from "node:assert/strict";
import test from "node:test";
import { withSsrModules } from "../test/ssrHarness.mjs";

test("teardown aborts polling without clearing the durable latch and remount reconciles it", async () => {
  await withSsrModules(async (load) => {
    const {
      createProviderRepairSafetyLatch,
      reconcileProviderRepairOperation,
    } = await load("/src/services/providerRepairOperationCoordinator.ts");
    const latch = createProviderRepairSafetyLatch();
    latch.completeBootstrap(["operation-a"]);
    const firstWait = deferred();
    const firstController = new AbortController();
    let firstReads = 0;

    const firstMount = reconcileProviderRepairOperation({
      operationId: latch.getSnapshot().operationIds[0],
      readStatus: async () => {
        firstReads += 1;
        return { lifecycle: "active", operationId: "operation-a" };
      },
      signal: firstController.signal,
      waitForNextPoll: () => firstWait.promise,
    });

    await nextTurn();
    firstController.abort();
    firstWait.resolve();
    assert.equal(await firstMount, "aborted");
    assert.equal(firstReads, 1);
    assert.deepEqual(latch.getSnapshot().operationIds, ["operation-a"]);

    const statuses = [
      { lifecycle: "active", operationId: "operation-a" },
      { lifecycle: "finished", operationId: "operation-a" },
    ];
    const remount = await reconcileProviderRepairOperation({
      operationId: latch.getSnapshot().operationIds[0],
      readStatus: async () => statuses.shift(),
      signal: new AbortController().signal,
      waitForNextPoll: async () => {},
    });
    assert.equal(remount, "finished");
    assert.equal(latch.clearFinished("operation-a"), true);
    assert.equal(latch.getSnapshot().phase, "ready");
  });
});

test("status failures stop at the bounded budget and leave the latch fail-closed", async () => {
  await withSsrModules(async (load) => {
    const {
      createProviderRepairSafetyLatch,
      reconcileProviderRepairOperation,
    } = await load("/src/services/providerRepairOperationCoordinator.ts");
    const latch = createProviderRepairSafetyLatch();
    latch.completeBootstrap(["operation-failed-status"]);
    let reads = 0;

    const outcome = await reconcileProviderRepairOperation({
      maxStatusFailures: 3,
      operationId: latch.getSnapshot().operationIds[0],
      readStatus: async () => {
        reads += 1;
        throw new Error("status unavailable");
      },
      signal: new AbortController().signal,
      waitForNextPoll: async () => {},
    });

    assert.equal(outcome, "statusUnavailable");
    assert.equal(reads, 3);
    assert.deepEqual(latch.getSnapshot().operationIds, ["operation-failed-status"]);
  });
});

test("owner-matching latch clear cannot erase a replacement operation", async () => {
  await withSsrModules(async (load) => {
    const { createProviderRepairSafetyLatch } = await load(
      "/src/services/providerRepairOperationCoordinator.ts",
    );
    const latch = createProviderRepairSafetyLatch();
    latch.completeBootstrap([]);
    latch.markInvokePending("operation-old");
    latch.markUncertain("operation-replacement");

    assert.equal(latch.clearFinished("operation-old"), false);
    assert.deepEqual(latch.getSnapshot().operationIds, ["operation-replacement"]);
  });
});

test("fresh latch bootstraps fail-closed, discovers Rust owners, and reconciles them", async () => {
  await withSsrModules(async (load) => {
    const {
      bootstrapProviderRepairSafetyLatch,
      providerRepairSafetyLatch,
      reconcileProviderRepairOperation,
    } = await load("/src/services/providerRepairOperationCoordinator.ts");
    const latch = providerRepairSafetyLatch;
    assert.equal(latch.getSnapshot().phase, "bootstrapping");

    assert.equal(await bootstrapProviderRepairSafetyLatch({
      discoverOwnership: async () => ({
        activeOperations: [{ canonicalHome: "/tmp/codex", operationId: "rust-owner" }],
      }),
      safetyLatch: latch,
    }), "ownersDiscovered");
    assert.deepEqual(latch.getSnapshot(), {
      generation: 1,
      operationIds: ["rust-owner"],
      phase: "uncertain",
    });

    const outcome = await reconcileProviderRepairOperation({
      operationId: "rust-owner",
      readStatus: async () => ({ lifecycle: "finished", operationId: "rust-owner" }),
      signal: new AbortController().signal,
      waitForNextPoll: async () => {},
    });
    assert.equal(outcome, "finished");
    assert.equal(latch.clearFinished("rust-owner"), true);
    assert.equal(latch.getSnapshot().phase, "ready");
  });
});

test("bootstrap failure is bounded and remains fail-closed until reopen retries", async () => {
  await withSsrModules(async (load) => {
    const {
      bootstrapProviderRepairSafetyLatch,
      createProviderRepairSafetyLatch,
    } = await load("/src/services/providerRepairOperationCoordinator.ts");
    const latch = createProviderRepairSafetyLatch();
    let reads = 0;

    assert.equal(await bootstrapProviderRepairSafetyLatch({
      discoverOwnership: async () => {
        reads += 1;
        throw new Error("status unavailable");
      },
      safetyLatch: latch,
    }), "statusUnavailable");
    assert.equal(reads, 1);
    assert.equal(latch.getSnapshot().phase, "statusUnavailable");

    latch.beginBootstrap();
    assert.equal(latch.getSnapshot().phase, "bootstrapping");
  });
});

test("uncertain backend ownership is closable while destructive controls stay disabled", async () => {
  await withSsrModules(async (load) => {
    const { deriveProviderRepairInteractionState } = await load(
      "/src/services/providerRepairOperationCoordinator.ts",
    );

    assert.deepEqual(deriveProviderRepairInteractionState(false, "uncertain"), {
      closeBlocked: false,
      controlsDisabled: true,
    });
    assert.deepEqual(deriveProviderRepairInteractionState(false, "statusUnavailable"), {
      closeBlocked: false,
      controlsDisabled: true,
    });
    assert.deepEqual(deriveProviderRepairInteractionState(true, "invokePending"), {
      closeBlocked: true,
      controlsDisabled: true,
    });
    assert.deepEqual(deriveProviderRepairInteractionState(false, "ready"), {
      closeBlocked: false,
      controlsDisabled: false,
    });
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

function nextTurn() {
  return new Promise((resolve) => setTimeout(resolve, 0));
}
