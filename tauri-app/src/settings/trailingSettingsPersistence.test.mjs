import assert from "node:assert/strict";
import test from "node:test";
import { createTrailingSettingsPersistence } from "./trailingSettingsPersistence.ts";

function controlledTimer() {
  let scheduled = null;
  let delay = null;
  return {
    api: {
      set(callback, delayMs) {
        scheduled = callback;
        delay = delayMs;
        return 1;
      },
      clear() {
        scheduled = null;
      },
    },
    fire() {
      const callback = scheduled;
      scheduled = null;
      callback?.();
    },
    get delay() {
      return delay;
    },
    get scheduled() {
      return scheduled;
    },
  };
}

test("trailing settings persistence deduplicates and writes only the final value", async () => {
  const timer = controlledTimer();
  const saved = [];
  const persistence = createTrailingSettingsPersistence(
    async (value) => {
      saved.push(value);
      return value;
    },
    { delayMs: 375, timerApi: timer.api },
  );

  persistence.setPersisted("initial");
  persistence.schedule("initial");
  assert.equal(timer.scheduled, null);

  persistence.schedule("one");
  persistence.schedule("two");
  assert.equal(timer.delay, 375);
  timer.fire();
  await persistence.flush();

  assert.deepEqual(saved, ["two"]);
});

test("trailing settings persistence serializes writes and the newest value wins", async () => {
  const timer = controlledTimer();
  const writes = [];
  const resolvers = [];
  const persistence = createTrailingSettingsPersistence(
    (value) => {
      writes.push(value);
      return new Promise((resolve) => resolvers.push(resolve));
    },
    { timerApi: timer.api },
  );

  persistence.setPersisted("zero");
  persistence.schedule("one");
  timer.fire();
  persistence.schedule("two");
  timer.fire();
  assert.deepEqual(writes, ["one"]);

  resolvers.shift()("one");
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(writes, ["one", "two"]);

  resolvers.shift()("two");
  await persistence.flush();
});

test("reverting while an older write is active restores the final UI value on disk", async () => {
  const timer = controlledTimer();
  const writes = [];
  const resolvers = [];
  const persistedEvents = [];
  const persistence = createTrailingSettingsPersistence(
    (value) => {
      writes.push(value);
      return new Promise((resolve) => resolvers.push(resolve));
    },
    {
      timerApi: timer.api,
      onLatestPersisted(value) {
        persistedEvents.push(value);
      },
    },
  );

  persistence.setPersisted("zero");
  persistence.schedule("one");
  timer.fire();
  persistence.schedule("zero");
  timer.fire();

  resolvers.shift()("one");
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(writes, ["one", "zero"]);

  resolvers.shift()("zero");
  await persistence.flush();
  assert.deepEqual(persistedEvents, ["zero"]);
});

test("flush starts a pending save and waits for the serialized queue", async () => {
  const timer = controlledTimer();
  let resolveWrite;
  const persistence = createTrailingSettingsPersistence(
    () => new Promise((resolve) => {
      resolveWrite = resolve;
    }),
    { timerApi: timer.api },
  );

  persistence.schedule("final");
  let flushed = false;
  const flush = persistence.flush().then(() => {
    flushed = true;
  });
  await Promise.resolve();
  assert.equal(flushed, false);

  resolveWrite("final");
  await flush;
  assert.equal(flushed, true);
});

test("only the latest failed generation reports an error and can be retried", async () => {
  const timer = controlledTimer();
  const errors = [];
  let attempts = 0;
  const persistence = createTrailingSettingsPersistence(
    async () => {
      attempts += 1;
      throw new Error(`failure-${attempts}`);
    },
    {
      timerApi: timer.api,
      onLatestError(error, value) {
        errors.push([error.message, value]);
      },
    },
  );

  persistence.schedule("value");
  timer.fire();
  await persistence.flush();
  assert.deepEqual(errors, [["failure-1", "value"]]);

  persistence.schedule("value");
  timer.fire();
  await persistence.flush();
  assert.deepEqual(errors, [
    ["failure-1", "value"],
    ["failure-2", "value"],
  ]);
});
