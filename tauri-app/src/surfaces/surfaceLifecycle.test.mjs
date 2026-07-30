import assert from "node:assert/strict";
import test from "node:test";

import {
  FLOATING_VISIBILITY_RECONCILE_INTERVAL_MS,
  INITIAL_FLOATING_SURFACE_LIFECYCLE,
  observeFloatingSurfaceVisibility,
  reduceFloatingSurfaceLifecycle,
  statusPanelIsActive,
} from "./surfaceLifecycle.ts";

test("floating lifecycle pauses while hidden and activates once per real visibility transition", () => {
  let state = INITIAL_FLOATING_SURFACE_LIFECYCLE;
  state = reduceFloatingSurfaceLifecycle(state, { type: "enabled", value: true });
  assert.deepEqual(state, { active: false, enabled: true, visible: false });

  state = reduceFloatingSurfaceLifecycle(state, { type: "visible", value: true });
  assert.deepEqual(state, { active: true, enabled: true, visible: true });
  const activeState = state;

  state = reduceFloatingSurfaceLifecycle(state, { type: "visible", value: true });
  assert.equal(state, activeState);

  state = reduceFloatingSurfaceLifecycle(state, { type: "visible", value: false });
  assert.equal(state.active, false);
  state = reduceFloatingSurfaceLifecycle(state, { type: "visible", value: true });
  assert.equal(state.active, true);
});

test("floating feature disable and restore follows native visibility without duplicate activation", () => {
  let state = reduceFloatingSurfaceLifecycle(
    INITIAL_FLOATING_SURFACE_LIFECYCLE,
    { type: "visible", value: true },
  );
  assert.equal(state.active, false);

  state = reduceFloatingSurfaceLifecycle(state, { type: "enabled", value: true });
  assert.equal(state.active, true);
  state = reduceFloatingSurfaceLifecycle(state, { type: "enabled", value: false });
  assert.equal(state.active, false);
  state = reduceFloatingSurfaceLifecycle(state, { type: "enabled", value: true });
  assert.equal(state.active, true);
});

test("status panel remains active whenever it is visible regardless of focus", () => {
  assert.equal(statusPanelIsActive(false), false);
  assert.equal(statusPanelIsActive(true), true);
});

test("floating visibility subscribes before reading and ignores a stale initial read", async () => {
  const subscriptionReady = deferred();
  const initialRead = deferred();
  const observed = [];
  let listener = null;
  let readCalls = 0;
  let unlistenCalls = 0;
  const stop = observeFloatingSurfaceVisibility({
    onVisible: (visible) => observed.push(visible),
    readVisible: () => {
      readCalls += 1;
      return initialRead.promise;
    },
    subscribe: (next) => {
      listener = next;
      return subscriptionReady.promise;
    },
  });

  await Promise.resolve();
  assert.equal(readCalls, 0);
  subscriptionReady.resolve({
    ok: true,
    unlisten: () => {
      unlistenCalls += 1;
    },
  });
  await Promise.resolve();
  await Promise.resolve();
  assert.equal(readCalls, 1);

  listener(true);
  initialRead.resolve(false);
  await Promise.resolve();
  await Promise.resolve();
  assert.deepEqual(observed, [true]);

  stop();
  assert.equal(unlistenCalls, 1);
});

test("visibility listener failure enables only low-frequency reconciliation", async () => {
  const observed = [];
  let scheduled = null;
  let cancelCalls = 0;
  let readCalls = 0;
  const visibleReads = [true, false];
  const stop = observeFloatingSurfaceVisibility({
    onVisible: (visible) => observed.push(visible),
    readVisible: () => Promise.resolve(visibleReads[readCalls++]),
    scheduleReconcile(refresh, intervalMs) {
      scheduled = { refresh, intervalMs };
      return () => {
        cancelCalls += 1;
      };
    },
    subscribe: () => Promise.resolve({ ok: false, error: "listen denied" }),
  });

  await settle();
  assert.deepEqual(observed, [true]);
  assert.equal(readCalls, 1);
  assert.equal(scheduled.intervalMs, FLOATING_VISIBILITY_RECONCILE_INTERVAL_MS);

  await scheduled.refresh();
  assert.deepEqual(observed, [true, false]);
  stop();
  assert.equal(cancelCalls, 1);
});

test("StrictMode cleanup releases a late listener without starting reconciliation", async () => {
  const subscriptionReady = deferred();
  let lateUnlistenCalls = 0;
  let readCalls = 0;
  let scheduleCalls = 0;
  const stop = observeFloatingSurfaceVisibility({
    onVisible: () => {},
    readVisible: () => {
      readCalls += 1;
      return Promise.resolve(true);
    },
    scheduleReconcile: () => {
      scheduleCalls += 1;
      return () => {};
    },
    subscribe: () => subscriptionReady.promise,
  });

  stop();
  subscriptionReady.resolve({
    ok: true,
    unlisten: () => {
      lateUnlistenCalls += 1;
    },
  });
  await settle();

  assert.equal(lateUnlistenCalls, 1);
  assert.equal(readCalls, 0);
  assert.equal(scheduleCalls, 0);
});

function deferred() {
  let resolve;
  const promise = new Promise((next) => {
    resolve = next;
  });
  return { promise, resolve };
}

async function settle() {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
}
