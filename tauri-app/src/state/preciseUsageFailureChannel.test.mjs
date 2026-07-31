import assert from "node:assert/strict";
import test from "node:test";
import {
  acknowledgePreciseUsageFailure,
  publishPreciseUsageFailure,
  subscribePreciseUsageFailures,
} from "./preciseUsageFailureChannel.ts";

test("precise read failures reach the source owner and durable acknowledgement stops replay", async () => {
  const observed = [];
  const unsubscribe = subscribePreciseUsageFailures("home-a", (signal) => observed.push(signal));
  const signal = publishPreciseUsageFailure("home-a", 123);
  assert.equal(observed.length, 1);
  assert.equal(observed[0].id, signal.id);
  unsubscribe();

  const replayed = [];
  const stopReplay = subscribePreciseUsageFailures("home-a", (value) => replayed.push(value));
  await Promise.resolve();
  assert.equal(replayed.length, 1);
  acknowledgePreciseUsageFailure("home-a", signal.id);
  stopReplay();

  const afterAcknowledgement = [];
  const stopAfter = subscribePreciseUsageFailures(
    "home-a",
    (value) => afterAcknowledgement.push(value),
  );
  await Promise.resolve();
  assert.deepEqual(afterAcknowledgement, []);
  stopAfter();
});

test("failure signals remain source scoped", () => {
  const observed = [];
  const unsubscribe = subscribePreciseUsageFailures("home-b", (signal) => observed.push(signal));
  publishPreciseUsageFailure("home-a", 456);
  assert.deepEqual(observed, []);
  unsubscribe();
});
