import assert from "node:assert/strict";
import test from "node:test";
import { radarCountdownDelayMs } from "./countdown.ts";

test("long Radar countdowns wait for the next minute boundary", () => {
  assert.equal(radarCountdownDelayMs(10 * 60_000, 0), 60_000);
  assert.equal(radarCountdownDelayMs(10 * 60_000 + 12_345, 0), 12_345);
});

test("Radar countdowns switch to second updates only in the final minute", () => {
  assert.equal(radarCountdownDelayMs(60_000, 0), 1_000);
  assert.equal(radarCountdownDelayMs(15_000, 0), 1_000);
  assert.equal(radarCountdownDelayMs(0, 0), 0);
});
