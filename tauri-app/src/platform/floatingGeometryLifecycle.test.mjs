import assert from "node:assert/strict";
import test from "node:test";
import {
  floatingGeometryLifecycle, isFloatingGeometryTransient, onFloatingSettledPosition,
  publishFloatingSettledPosition, registerFloatingGeometryLifecycle, runFloatingGeometryChange,
} from "./floatingGeometryLifecycle.ts";

test("native geometry writes are serialized, including a rejected write", async () => {
  const order = [];
  let release;
  const held = new Promise((resolve) => { release = resolve; });
  const first = runFloatingGeometryChange(async () => {
    order.push("first-start");
    assert.equal(isFloatingGeometryTransient(), true);
    await held;
    order.push("first-end");
    throw new Error("native write failed");
  });
  const handledFirst = assert.rejects(first, /native write failed/);
  const second = runFloatingGeometryChange(async () => { order.push("second"); });
  await Promise.resolve();
  assert.deepEqual(order, ["first-start"]);
  release();
  await handledFirst; await second;
  assert.deepEqual(order, ["first-start", "first-end", "second"]);
  assert.equal(isFloatingGeometryTransient(), true);
  await new Promise((resolve) => setTimeout(resolve, 270));
  assert.equal(isFloatingGeometryTransient(), false);
});

test("stale lifecycle cleanup cannot unregister a replacement controller", () => {
  const a = { beforeResize: async () => {}, afterResize() {} };
  const b = { beforeResize: async () => {}, afterResize() {} };
  const removeA = registerFloatingGeometryLifecycle(a);
  const removeB = registerFloatingGeometryLifecycle(b);
  removeA(); assert.equal(floatingGeometryLifecycle(), b);
  removeB(); assert.equal(floatingGeometryLifecycle(), null);
});

test("only explicitly settled anchors enter position persistence", () => {
  const saved = [];
  const remove = onFloatingSettledPosition((point) => saved.push(point));
  publishFloatingSettledPosition({ x: -1200, y: 60, width: 300, height: 120 });
  assert.deepEqual(saved, [{ x: -1200, y: 60 }]);
  remove(); publishFloatingSettledPosition({ x: 0, y: 0 });
  assert.equal(saved.length, 1);
});
