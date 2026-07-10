import assert from "node:assert/strict";
import test from "node:test";
import { withSsrModules } from "../../test/ssrHarness.mjs";

test("teardown aborts polling without clearing the durable latch and remount reconciles it", async () => {
  await withSsrModules(async (load) => {
    const {
      createProviderRepairSafetyLatch,
      reconcileProviderRepairOperation,
    } = await load("/src/components/providerRepair/providerOperationCoordinator.ts");
    const latch = createProviderRepairSafetyLatch();
    latch.latch("operation-a");
    const firstWait = deferred();
    const firstController = new AbortController();
    let firstReads = 0;

    const firstMount = reconcileProviderRepairOperation({
      operationId: latch.getSnapshot(),
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
    assert.equal(latch.getSnapshot(), "operation-a");

    const statuses = [
      { lifecycle: "active", operationId: "operation-a" },
      { lifecycle: "finished", operationId: "operation-a" },
    ];
    const remount = await reconcileProviderRepairOperation({
      operationId: latch.getSnapshot(),
      readStatus: async () => statuses.shift(),
      signal: new AbortController().signal,
      waitForNextPoll: async () => {},
    });
    assert.equal(remount, "finished");
    assert.equal(latch.clearFinished("operation-a"), true);
    assert.equal(latch.getSnapshot(), null);
  });
});

test("status failures stop at the bounded budget and leave the latch fail-closed", async () => {
  await withSsrModules(async (load) => {
    const {
      createProviderRepairSafetyLatch,
      reconcileProviderRepairOperation,
    } = await load("/src/components/providerRepair/providerOperationCoordinator.ts");
    const latch = createProviderRepairSafetyLatch();
    latch.latch("operation-failed-status");
    let reads = 0;

    const outcome = await reconcileProviderRepairOperation({
      maxStatusFailures: 3,
      operationId: latch.getSnapshot(),
      readStatus: async () => {
        reads += 1;
        throw new Error("status unavailable");
      },
      signal: new AbortController().signal,
      waitForNextPoll: async () => {},
    });

    assert.equal(outcome, "statusUnavailable");
    assert.equal(reads, 3);
    assert.equal(latch.getSnapshot(), "operation-failed-status");
  });
});

test("owner-matching latch clear cannot erase a replacement operation", async () => {
  await withSsrModules(async (load) => {
    const { createProviderRepairSafetyLatch } = await load(
      "/src/components/providerRepair/providerOperationCoordinator.ts",
    );
    const latch = createProviderRepairSafetyLatch();
    latch.latch("operation-old");
    latch.latch("operation-replacement");

    assert.equal(latch.clearFinished("operation-old"), false);
    assert.equal(latch.getSnapshot(), "operation-replacement");
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
