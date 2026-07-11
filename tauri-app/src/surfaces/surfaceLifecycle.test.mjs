import assert from "node:assert/strict";
import test from "node:test";

import {
  INITIAL_FLOATING_SURFACE_LIFECYCLE,
  observeFloatingSurfaceVisibility,
  reduceFloatingSurfaceLifecycle,
  statusPanelIsActive,
} from "./surfaceLifecycle.ts";

test("floating lifecycle pauses while hidden and activates once per real visibility transition", () => {
  let state = INITIAL_FLOATING_SURFACE_LIFECYCLE;
  state = reduceFloatingSurfaceLifecycle(state, { type: "enabled", value: true });
  assert.equal(state.active, false);
  assert.equal(state.activationGeneration, 0);

  state = reduceFloatingSurfaceLifecycle(state, { type: "visible", value: true });
  assert.equal(state.active, true);
  assert.equal(state.activationGeneration, 1);
  const activeState = state;

  state = reduceFloatingSurfaceLifecycle(state, { type: "visible", value: true });
  assert.equal(state, activeState);
  assert.equal(state.activationGeneration, 1);

  state = reduceFloatingSurfaceLifecycle(state, { type: "visible", value: false });
  assert.equal(state.active, false);
  state = reduceFloatingSurfaceLifecycle(state, { type: "visible", value: true });
  assert.equal(state.active, true);
  assert.equal(state.activationGeneration, 2);
});

test("floating feature disable and restore follows native visibility without duplicate activation", () => {
  let state = reduceFloatingSurfaceLifecycle(
    INITIAL_FLOATING_SURFACE_LIFECYCLE,
    { type: "visible", value: true },
  );
  assert.equal(state.active, false);

  state = reduceFloatingSurfaceLifecycle(state, { type: "enabled", value: true });
  assert.equal(state.active, true);
  assert.equal(state.activationGeneration, 1);
  state = reduceFloatingSurfaceLifecycle(state, { type: "enabled", value: false });
  assert.equal(state.active, false);
  state = reduceFloatingSurfaceLifecycle(state, { type: "enabled", value: true });
  assert.equal(state.active, true);
  assert.equal(state.activationGeneration, 2);
});

test("status panel remains active only while both visible and focused", () => {
  assert.equal(statusPanelIsActive(false, false), false);
  assert.equal(statusPanelIsActive(true, false), false);
  assert.equal(statusPanelIsActive(false, true), false);
  assert.equal(statusPanelIsActive(true, true), true);
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
  subscriptionReady.resolve(() => {
    unlistenCalls += 1;
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

function deferred() {
  let resolve;
  const promise = new Promise((next) => {
    resolve = next;
  });
  return { promise, resolve };
}
