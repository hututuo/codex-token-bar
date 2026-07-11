import assert from "node:assert/strict";
import test from "node:test";

import {
  DEFAULT_UPDATE_CHECK_INTERVAL_MS,
  createUpdateCheckScheduler,
} from "./updateCheckScheduler.ts";

test("startup performs the first automatic check and persists its attempt", async () => {
  const harness = schedulerHarness();

  const outcome = await harness.scheduler.runAutomatic();

  assert.equal(outcome.kind, "completed");
  assert.equal(harness.checks, 1);
  assert.equal(harness.storage.getItem(harness.key), "1000");
});

test("focus and wake events inside the interval do not repeat a check", async () => {
  const harness = schedulerHarness();
  await harness.scheduler.runAutomatic();

  harness.advance(DEFAULT_UPDATE_CHECK_INTERVAL_MS - 1);
  const focus = await harness.scheduler.runAutomatic();
  const wake = await harness.scheduler.runAutomatic();

  assert.equal(focus.kind, "skipped");
  assert.equal(wake.kind, "skipped");
  assert.equal(harness.checks, 1);
});

test("an automatic event checks again after the persisted interval", async () => {
  const harness = schedulerHarness();
  await harness.scheduler.runAutomatic();

  harness.advance(DEFAULT_UPDATE_CHECK_INTERVAL_MS);
  const outcome = await harness.scheduler.runAutomatic();

  assert.equal(outcome.kind, "completed");
  assert.equal(harness.checks, 2);
});

test("a remounted scheduler honors the persisted interval", async () => {
  const storage = memoryStorage();
  let checks = 0;
  const options = {
    check: async () => {
      checks += 1;
      return { status: "none", message: "latest" };
    },
    now: () => 10_000,
    storage,
    storageKey: "test:persisted-update-check",
  };
  await createUpdateCheckScheduler(options).runAutomatic();

  const remounted = createUpdateCheckScheduler(options);
  const outcome = await remounted.runAutomatic();

  assert.equal(outcome.kind, "skipped");
  assert.equal(checks, 1);
});

test("concurrent lifecycle events join one in-flight check", async () => {
  const pending = deferred();
  const harness = schedulerHarness({ check: () => pending.promise });

  const startup = harness.scheduler.runAutomatic();
  const focus = harness.scheduler.runAutomatic();
  const wake = harness.scheduler.runAutomatic();
  assert.equal(harness.checks, 1);

  pending.resolve({ status: "none", message: "latest" });
  const outcomes = await Promise.all([startup, focus, wake]);
  assert.deepEqual(outcomes.map((outcome) => outcome.kind), ["completed", "completed", "completed"]);
  assert.equal(harness.checks, 1);
});

test("manual checks bypass cadence but still join an automatic in-flight check", async () => {
  const pending = deferred();
  const harness = schedulerHarness({ check: () => pending.promise });
  const automatic = harness.scheduler.runAutomatic();
  const manual = harness.scheduler.runManual();

  pending.resolve({ status: "none", message: "latest" });
  await Promise.all([automatic, manual]);
  assert.equal(harness.checks, 1);

  await harness.scheduler.runManual();
  assert.equal(harness.checks, 2);
});

test("automatic update availability is data only and never installs", async () => {
  let installs = 0;
  const harness = schedulerHarness({
    check: async () => ({ status: "available", version: "0.8.0", update: { install: () => { installs += 1; } } }),
  });

  const outcome = await harness.scheduler.runAutomatic();

  assert.equal(outcome.kind, "completed");
  assert.equal(outcome.value.status, "available");
  assert.equal(installs, 0);
});

function schedulerHarness(options = {}) {
  let now = 1_000;
  let checks = 0;
  const storage = memoryStorage();
  const key = "test:update-check";
  const check = options.check ?? (async () => ({ status: "none", message: "latest" }));
  const scheduler = createUpdateCheckScheduler({
    check: () => {
      checks += 1;
      return check();
    },
    now: () => now,
    storage,
    storageKey: key,
  });
  return {
    advance(ms) { now += ms; },
    get checks() { return checks; },
    key,
    scheduler,
    storage,
  };
}

function memoryStorage() {
  const values = new Map();
  return {
    getItem(key) { return values.get(key) ?? null; },
    setItem(key, value) { values.set(key, value); },
  };
}

function deferred() {
  let resolve;
  const promise = new Promise((complete) => { resolve = complete; });
  return { promise, resolve };
}
