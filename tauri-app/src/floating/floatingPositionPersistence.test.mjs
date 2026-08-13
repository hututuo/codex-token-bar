import assert from "node:assert/strict";
import test from "node:test";
import { createFloatingPositionPersistence } from "./floatingPositionPersistence.ts";
import { readFileSync } from "node:fs";

const placementSource = readFileSync(new URL("./useFloatingWindowPlacement.ts", import.meta.url), "utf8");

test("startup restore waits for the move listener and rejects a stale position after user movement", () => {
  assert.match(placementSource, /onFloatingWindowMoved/);
  assert.match(placementSource, /const restoreGeneration = movementGeneration/);
  assert.match(placementSource, /movementGeneration !== restoreGeneration/);
  assert.match(placementSource, /restoringStoredPosition/);
});

test("floating position persistence deduplicates coordinates and trails the final move", async () => {
  let scheduled = null;
  let delay = null;
  let clearCount = 0;
  const saved = [];
  const persistence = createFloatingPositionPersistence(
    async (position) => saved.push(position),
    400,
    {
      set(callback, delayMs) {
        scheduled = callback;
        delay = delayMs;
        return 1;
      },
      clear() {
        clearCount += 1;
        scheduled = null;
      },
    },
  );

  persistence.setPersisted({ x: 10, y: 20 });
  persistence.schedule({ x: 10, y: 20 });
  assert.equal(scheduled, null, "an unchanged move must not schedule a settings write");

  persistence.schedule({ x: 11, y: 21 });
  persistence.schedule({ x: 12, y: 22 });
  assert.equal(delay, 400);
  assert.equal(clearCount, 1);
  const trailing = scheduled;
  trailing();
  await Promise.resolve();
  assert.deepEqual(saved, [{ x: 12, y: 22 }]);

  persistence.schedule({ x: 12, y: 22 });
  assert.equal(scheduled, null, "the last persisted coordinates must remain deduplicated");
});

test("floating position persistence flushes the pending final position", async () => {
  let scheduled = null;
  const saved = [];
  const persistence = createFloatingPositionPersistence(
    async (position) => saved.push(position),
    400,
    {
      set(callback) {
        scheduled = callback;
        return 1;
      },
      clear() {
        scheduled = null;
      },
    },
  );

  persistence.schedule({ x: -5, y: 42 });
  assert.notEqual(scheduled, null);
  persistence.flush();
  await Promise.resolve();
  assert.deepEqual(saved, [{ x: -5, y: 42 }]);
  assert.equal(scheduled, null);
});

test("floating position persistence serializes writes so an older save cannot finish last", async () => {
  const writes = [];
  const resolvers = [];
  const persistence = createFloatingPositionPersistence(
    (position) => {
      writes.push(position);
      return new Promise((resolve) => resolvers.push(resolve));
    },
    0,
    {
      set(callback) {
        callback();
        return 1;
      },
      clear() {},
    },
  );

  persistence.schedule({ x: 1, y: 1 });
  persistence.schedule({ x: 2, y: 2 });
  assert.deepEqual(writes, [{ x: 1, y: 1 }]);

  resolvers.shift()();
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(writes, [{ x: 1, y: 1 }, { x: 2, y: 2 }]);

  resolvers.shift()();
  await new Promise((resolve) => setImmediate(resolve));
});
