import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { createLiveRateLeaseController } from "./liveRateLease.ts";

test("cleanup before a delayed start releases only the late lease and preserves B", async () => {
  const released = [];
  const controller = createLiveRateLeaseController((leaseId) => {
    released.push(leaseId);
  }, "dashboard-owner");

  const requestA = controller.begin();
  requestA.cancel();
  const requestB = controller.begin();
  assert.equal(requestB.ownerGeneration, 2);
  assert.equal(requestB.accept({ leaseId: "lease-b" }), true);

  await Promise.resolve();
  assert.equal(requestA.accept({ leaseId: "lease-a" }), false);
  assert.deepEqual(released, ["lease-a"]);

  requestB.cancel();
  assert.deepEqual(released, ["lease-a", "lease-b"]);
});

test("each request carries one stable owner token and a monotonic owner generation", () => {
  const controller = createLiveRateLeaseController(() => {}, "owner-token");
  const first = controller.begin();
  const second = controller.begin();

  assert.equal(first.ownerToken, "owner-token");
  assert.equal(second.ownerToken, "owner-token");
  assert.equal(first.ownerGeneration, 1);
  assert.equal(second.ownerGeneration, 2);
});

test("lease-granting start waits for its backend response so cleanup can release late leases", async () => {
  const [surfaceCommands, desktopBridge] = await Promise.all([
    readFile(new URL("../platform/surfaceCommands.ts", import.meta.url), "utf8"),
    readFile(new URL("../platform/desktopBridge.ts", import.meta.url), "utf8"),
  ]);
  const startCommand = surfaceCommands.slice(
    surfaceCommands.indexOf("export function startLiveRateStreamCommand"),
    surfaceCommands.indexOf("export function stopLiveRateStream"),
  );

  assert.match(startCommand, /invokePlatformCommandResult\([\s\S]*?,\s*null\s*\);/);
  assert.match(desktopBridge, /timeoutMs: number \| null/);
});
