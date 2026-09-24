import assert from "node:assert/strict";
import test from "node:test";
import { createSidebarNativeCoordinator } from "./nativeCoordinator.ts";
const tick = () => new Promise(resolve => setImmediate(resolve));

test("native acceptance is not completion and a per-frame failure invalidates deduplication", async () => {
  const calls = [], errors = [];
  const queue = createSidebarNativeCoordinator(async (...args) => calls.push(args), e => errors.push(e));
  queue.update("hover"); queue.setEnabled(true); await tick();
  assert.equal(queue.isSettled(), false);
  queue.complete(calls[0][3], null); assert.equal(queue.isSettled(), true);
  queue.complete(calls[0][3], "injected frame failure"); assert.equal(queue.isSettled(), false);
  queue.update("hover"); await tick();
  assert.equal(calls.length, 2);
  assert.ok(errors.includes("injected frame failure"));
  queue.complete(calls[0][3], "stale failure");
  assert.ok(!errors.includes("stale failure"));
  queue.complete(calls[1][3], null); assert.equal(queue.isSettled(), true);
  queue.setEnabled(false);
});

test("failure arriving before the IPC return cannot be overwritten by a late acceptance", async () => {
  let release; const calls = [];
  const queue = createSidebarNativeCoordinator((...args) => {
    calls.push(args); return new Promise(resolve => { release = resolve; });
  }, () => {});
  queue.setEnabled(true);
  queue.complete(calls[0][3], "frame failed before return");
  release(); await tick();
  queue.update("rest"); assert.equal(calls.length, 2);
  queue.setEnabled(false); queue.complete(calls[1][3], null);
  release(); await tick(); assert.equal(queue.isSettled(), false);
});
