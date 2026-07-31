import assert from "node:assert/strict";
import test from "node:test";
import {
  clearPreciseUsageContinuityGap,
  markPreciseUsageContinuityGap,
  preciseUsageContinuityStorageKey,
  readPreciseUsageObserverState,
  readPreciseUsageContinuityGap,
  readPreciseUsageContinuityState,
  reconcilePreciseUsageObserverEpoch,
} from "./preciseUsageContinuity.ts";

function storage() {
  const values = new Map();
  return {
    values,
    getItem(key) { return values.get(key) ?? null; },
    setItem(key, value) { values.set(key, value); },
    removeItem(key) { values.delete(key); },
  };
}

test("each failed exact-read generation receives a distinct durable UUID", () => {
  const target = storage();
  const first = markPreciseUsageContinuityGap("home-a", 200, target);
  const second = markPreciseUsageContinuityGap("home-a", 300, target);
  const third = markPreciseUsageContinuityGap("home-a", 100, target);

  assert.match(first.id, /^[0-9a-f-]{36}$/i);
  assert.equal(first.generation, 1);
  assert.equal(first.detectedAtUnix, 200);
  assert.equal(second.generation, 2);
  assert.equal(second.detectedAtUnix, 300);
  assert.notEqual(second.id, first.id);
  assert.equal(third.generation, 3);
  assert.equal(third.detectedAtUnix, 100);
  assert.notEqual(third.id, second.id);
  assert.deepEqual(readPreciseUsageContinuityGap("home-a", target), third);
  assert.equal(readPreciseUsageContinuityGap("home-b", target), null);
  assert.doesNotMatch(preciseUsageContinuityStorageKey("home-a"), /home-a/);
});

test("a gap clears only when the durably cut-over UUID matches", () => {
  const target = storage();
  const gap = markPreciseUsageContinuityGap("home-a", 100, target);
  assert.equal(clearPreciseUsageContinuityGap(
    "home-a",
    "00000000-0000-4000-8000-000000000000",
    target,
  ), false);
  assert.notEqual(readPreciseUsageContinuityGap("home-a", target), null);
  assert.equal(clearPreciseUsageContinuityGap("home-a", gap.id, target), true);
  assert.equal(readPreciseUsageContinuityGap("home-a", target), null);
});

test("corrupt continuity storage fails closed and is never overwritten", () => {
  const target = storage();
  const key = preciseUsageContinuityStorageKey("home-a");
  target.values.set(key, "{broken-json");

  assert.deepEqual(readPreciseUsageContinuityState("home-a", target), {
    healthy: false,
    gap: null,
  });
  assert.equal(markPreciseUsageContinuityGap("home-a", 200, target), null);
  assert.equal(target.values.get(key), "{broken-json");
  assert.equal(clearPreciseUsageContinuityGap(
    "home-a",
    "00000000-0000-4000-8000-000000000000",
    target,
  ), false);
});

test("a valid v1 gap migrates once and removes legacy storage only after read-back", () => {
  const target = storage();
  const currentKey = preciseUsageContinuityStorageKey("home-a");
  const legacyKey = currentKey.replace(
    "sharedAccountAttributionPreciseContinuity:v2",
    "sharedAccountAttributionPreciseContinuity:v1",
  );
  target.values.set(legacyKey, JSON.stringify({ detectedAtUnix: 123 }));

  const state = readPreciseUsageContinuityState("home-a", target);
  assert.equal(state.healthy, true);
  assert.equal(state.gap.generation, 1);
  assert.equal(state.gap.detectedAtUnix, 123);
  assert.equal(target.values.has(currentKey), true);
  assert.equal(target.values.has(legacyKey), false);
});

test("a non-owner reads legacy continuity fail-closed without migrating it", () => {
  const target = storage();
  const currentKey = preciseUsageContinuityStorageKey("home-a");
  const legacyKey = currentKey.replace(
    "sharedAccountAttributionPreciseContinuity:v2",
    "sharedAccountAttributionPreciseContinuity:v1",
  );
  target.values.set(legacyKey, JSON.stringify({ detectedAtUnix: 123 }));

  assert.deepEqual(readPreciseUsageContinuityState("home-a", target, false), {
    healthy: false,
    gap: null,
  });
  assert.equal(target.values.has(currentKey), false);
  assert.equal(target.values.has(legacyKey), true);
});

test("a native observer restart creates a durable synthetic gap before publishing its epoch", () => {
  const target = storage();
  const first = {
    epoch: "11111111-1111-4111-8111-111111111111",
    startedAtUnixMicros: 1_000_000,
    sequence: 0,
  };
  const second = {
    epoch: "22222222-2222-4222-8222-222222222222",
    startedAtUnixMicros: 2_000_000,
    sequence: 0,
  };
  assert.deepEqual(
    reconcilePreciseUsageObserverEpoch("home-a", first, false, 100, target),
    { healthy: true, changed: true, gapCreated: false, transition: "initialize" },
  );
  const restarted = reconcilePreciseUsageObserverEpoch("home-a", second, true, 200, target);
  assert.equal(restarted.healthy, true);
  assert.equal(restarted.gapCreated, true);
  assert.equal(restarted.transition, "restart");
  assert.deepEqual(readPreciseUsageObserverState("home-a", target).observer, second);
  assert.equal(readPreciseUsageContinuityGap("home-a", target).detectedAtUnix, 200);
});

test("a late writer from an older process cannot replace the newer observer or its gap", () => {
  const target = storage();
  const oldObserver = {
    epoch: "33333333-3333-4333-8333-333333333333",
    startedAtUnixMicros: 3_000_000,
    sequence: 0,
  };
  const newObserver = {
    epoch: "44444444-4444-4444-8444-444444444444",
    startedAtUnixMicros: 4_000_000,
    sequence: 0,
  };
  reconcilePreciseUsageObserverEpoch("home-a", oldObserver, false, 100, target);
  reconcilePreciseUsageObserverEpoch("home-a", newObserver, true, 200, target);
  const gapBefore = readPreciseUsageContinuityGap("home-a", target);

  const stale = reconcilePreciseUsageObserverEpoch("home-a", oldObserver, true, 300, target);
  assert.equal(stale.healthy, false);
  assert.equal(stale.transition, "superseded");
  assert.deepEqual(readPreciseUsageObserverState("home-a", target).observer, newObserver);
  assert.deepEqual(readPreciseUsageContinuityGap("home-a", target), gapBefore);

  const sameWindow = reconcilePreciseUsageObserverEpoch("home-a", newObserver, true, 400, target);
  assert.deepEqual(sameWindow, {
    healthy: true,
    changed: false,
    gapCreated: false,
    transition: "current",
  });
  assert.deepEqual(readPreciseUsageContinuityGap("home-a", target), gapBefore);
});

test("native watcher sequence orders cutovers inside one process epoch", () => {
  const target = storage();
  const initial = {
    epoch: "55555555-5555-4555-8555-555555555555",
    startedAtUnixMicros: 5_000_000,
    sequence: 0,
  };
  const watcherCutover = {
    epoch: "66666666-6666-4666-8666-666666666666",
    startedAtUnixMicros: 5_000_000,
    sequence: 1,
  };
  reconcilePreciseUsageObserverEpoch("home-a", initial, false, 100, target);

  const advanced = reconcilePreciseUsageObserverEpoch(
    "home-a",
    watcherCutover,
    true,
    200,
    target,
  );
  assert.equal(advanced.healthy, true);
  assert.equal(advanced.transition, "restart");
  assert.equal(advanced.gapCreated, true);
  assert.deepEqual(readPreciseUsageObserverState("home-a", target).observer, watcherCutover);
  const durableGap = readPreciseUsageContinuityGap("home-a", target);

  const stale = reconcilePreciseUsageObserverEpoch("home-a", initial, true, 300, target);
  assert.equal(stale.healthy, false);
  assert.equal(stale.transition, "superseded");
  assert.deepEqual(readPreciseUsageObserverState("home-a", target).observer, watcherCutover);
  assert.deepEqual(readPreciseUsageContinuityGap("home-a", target), durableGap);
});
