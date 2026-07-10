import assert from "node:assert/strict";
import test from "node:test";
import { withSsrModules } from "../test/ssrHarness.mjs";

test("provider timeout stays uncertain until the backend lease ends", async () => {
  await withSsrModules(async (load) => {
    const { executeProviderRepairMutation } = await load("/src/api/providerRepairClient.ts");
    const mutation = deferred();
    const firstStatus = deferred();
    const secondStatus = deferred();
    const statusReads = [firstStatus, secondStatus];
    let phase = "busy";
    let settled = false;

    const execution = executeProviderRepairMutation({
      mutation: () => mutation.promise,
      onUncertain: () => {
        phase = "uncertain";
      },
      operationId: "operation-a",
      readStatus: () => statusReads.shift().promise,
      waitForNextPoll: async () => {},
    }).finally(() => {
      settled = true;
      phase = "idle";
    });

    mutation.reject(new Error("Command timed out after 60000ms"));
    await nextTurn();
    assert.equal(phase, "uncertain");
    assert.equal(settled, false);
    assert.equal(canStartDestructiveAction(phase), false);

    firstStatus.resolve({ active: true, operationId: "operation-a" });
    await nextTurn();
    assert.equal(phase, "uncertain");
    assert.equal(settled, false);
    assert.equal(canStartDestructiveAction(phase), false);

    secondStatus.resolve({ active: false, operationId: "operation-a" });
    await assert.rejects(execution, /timed out/i);
    assert.equal(phase, "idle");
    assert.equal(settled, true);
    assert.equal(canStartDestructiveAction(phase), true);
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

function canStartDestructiveAction(phase) {
  return phase === "idle";
}
