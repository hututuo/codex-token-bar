import assert from "node:assert/strict";
import test from "node:test";

import { createCompactLiveRateAttemptRunner } from "./compactLiveRateAttempt.ts";

test("failed start cannot be overwritten by a later initial snapshot", async () => {
  const initial = deferred();
  const states = [];
  const retries = [];
  const runner = createCompactLiveRateAttemptRunner({
    retryDelaysMs: [5_000, 10_000, 30_000],
    scheduleRetry(delayMs, retry) {
      retries.push({ delayMs, retry });
      return () => {};
    },
  });

  const attempt = runner.start({
    start: async () => ({ ok: false, error: "start failed" }),
    readInitial: () => initial.promise,
    publishSnapshot: (value) => states.push(["snapshot", value]),
    publishFailure: (message) => states.push(["failure", message]),
  });
  await attempt.settled;

  assert.deepEqual(states, [["failure", "start failed"]]);
  assert.equal(retries[0].delayMs, 5_000);
  assert.equal(initial.started, false);
});

test("cleanup cancels retry and stale attempt while a later success may publish", async () => {
  const firstStart = deferred();
  const secondInitial = deferred();
  const states = [];
  const scheduled = [];
  const runner = createCompactLiveRateAttemptRunner({
    retryDelaysMs: [5_000, 10_000],
    scheduleRetry(delayMs, retry) {
      const entry = { cancelled: false, delayMs, retry };
      scheduled.push(entry);
      return () => { entry.cancelled = true; };
    },
  });

  const first = runner.start({
    start: () => firstStart.promise,
    readInitial: async () => "old initial",
    publishSnapshot: (value) => states.push(value),
    publishFailure: (message) => states.push(message),
  });
  first.cancel();
  firstStart.resolve({ ok: false, error: "old failure" });
  await first.settled;

  const second = runner.start({
    start: async () => ({ ok: true, accepted: true }),
    readInitial: () => secondInitial.promise,
    publishSnapshot: (value) => states.push(value),
    publishFailure: (message) => states.push(message),
  });
  secondInitial.resolve("new snapshot");
  await second.settled;

  assert.deepEqual(states, ["new snapshot"]);
  assert.equal(scheduled.length, 0);
});

test("bounded retry starts one replacement attempt and publishes only its success", async () => {
  const scheduled = [];
  const states = [];
  let starts = 0;
  const runner = createCompactLiveRateAttemptRunner({
    retryDelaysMs: [5_000, 10_000],
    scheduleRetry(delayMs, retry) {
      const entry = { cancelled: false, delayMs, retry };
      scheduled.push(entry);
      return () => { entry.cancelled = true; };
    },
  });
  const attempt = runner.start({
    async start() {
      starts += 1;
      return starts === 1
        ? { ok: false, error: "temporary" }
        : { ok: true, accepted: true };
    },
    readInitial: async () => "recovered",
    publishSnapshot: (value) => states.push(value),
    publishFailure: (message) => states.push(message),
  });
  await attempt.settled;

  assert.equal(starts, 1);
  assert.equal(scheduled.length, 1);
  assert.equal(scheduled[0].delayMs, 5_000);
  scheduled[0].retry();
  await Promise.resolve();
  await Promise.resolve();

  assert.equal(starts, 2);
  assert.deepEqual(states, ["temporary", "recovered"]);
  attempt.cancel();
});

test("cleanup cancels a scheduled retry", async () => {
  const scheduled = [];
  const runner = createCompactLiveRateAttemptRunner({
    scheduleRetry(delayMs, retry) {
      const entry = { cancelled: false, delayMs, retry };
      scheduled.push(entry);
      return () => { entry.cancelled = true; };
    },
  });
  const attempt = runner.start({
    start: async () => ({ ok: false, error: "temporary" }),
    readInitial: async () => "unused",
    publishSnapshot() {},
    publishFailure() {},
  });
  await attempt.settled;
  attempt.cancel();

  assert.equal(scheduled.length, 1);
  assert.equal(scheduled[0].cancelled, true);
});

function deferred() {
  let resolve;
  let started = false;
  const promise = new Promise((complete) => {
    resolve = complete;
  });
  return {
    get started() { return started; },
    promise: {
      then(...args) {
        started = true;
        return promise.then(...args);
      },
    },
    resolve,
  };
}
