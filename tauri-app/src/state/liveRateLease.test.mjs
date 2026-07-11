import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  createLiveRateLeaseController,
  createLiveRateOwnerSession,
} from "./liveRateLease.ts";

test("cleanup before a delayed start releases only the late lease and preserves B", async () => {
  const released = [];
  const controller = createLiveRateLeaseController((leaseId) => {
    released.push(leaseId);
  }, { ownerToken: "dashboard-owner", ownerSessionEpoch: 1 });

  const requestA = controller.begin();
  requestA.cancel();
  const requestB = controller.begin();
  assert.equal(requestB.ownerGeneration, 2);
  assert.equal(requestB.accept({ leaseId: "lease-b", registered: true }), true);

  await Promise.resolve();
  assert.equal(requestA.accept({ leaseId: "lease-a", registered: true }), false);
  assert.deepEqual(released, ["lease-a"]);

  requestB.cancel();
  assert.deepEqual(released, ["lease-a", "lease-b"]);
});

test("each request carries one stable owner token and a monotonic owner generation", () => {
  const controller = createLiveRateLeaseController(
    () => {},
    { ownerToken: "owner-token", ownerSessionEpoch: 7 },
  );
  const first = controller.begin();
  const second = controller.begin();

  assert.equal(first.ownerToken, "owner-token");
  assert.equal(second.ownerToken, "owner-token");
  assert.equal(first.ownerSessionEpoch, 7);
  assert.equal(second.ownerSessionEpoch, 7);
  assert.equal(first.ownerGeneration, 1);
  assert.equal(second.ownerGeneration, 2);
});

test("WebView remount keeps a stable surface owner and advances a persisted session epoch", () => {
  const storage = memoryStorage();
  const firstSession = createLiveRateOwnerSession("dashboard-live-rate", storage);
  const secondSession = createLiveRateOwnerSession("dashboard-live-rate", storage);

  assert.equal(firstSession.ownerToken, "dashboard-live-rate");
  assert.equal(secondSession.ownerToken, "dashboard-live-rate");
  assert.equal(firstSession.ownerSessionEpoch, 1);
  assert.equal(secondSession.ownerSessionEpoch, 2);

  const oldController = createLiveRateLeaseController(() => {}, firstSession);
  const newController = createLiveRateLeaseController(() => {}, secondSession);
  assert.equal(oldController.begin().ownerSessionEpoch, 1);
  assert.equal(newController.begin().ownerSessionEpoch, 2);
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

function memoryStorage() {
  const values = new Map();
  return {
    getItem(key) {
      return values.get(key) ?? null;
    },
    setItem(key, value) {
      values.set(key, value);
    },
  };
}
