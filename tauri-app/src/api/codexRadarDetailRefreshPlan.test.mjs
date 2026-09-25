import assert from "node:assert/strict";
import test from "node:test";

import {
  latestCodexRadarDetailSlot,
  millisecondsUntilNextCodexRadarDetailSlot,
  nextCodexRadarDetailRecoveryDelayMs,
  shouldRefreshCodexRadarDetail,
} from "./codexRadarDetailRefreshPlan.ts";

// These are local-calendar scheduling tests, not fixed UTC+08:00 instants.
// Use local constructors so a clean UTC runner tests the same contract.
const local = (day, hour, minute = 0, second = 0) => new Date(2026, 6, day, hour, minute, second);

test("latestCodexRadarDetailSlot follows local 08:00 and 18:00 boundaries", () => {
  assert.equal(
    latestCodexRadarDetailSlot(local(7, 7, 59)).getTime(),
    local(6, 18).getTime(),
  );
  assert.equal(
    latestCodexRadarDetailSlot(local(7, 8)).getTime(),
    local(7, 8).getTime(),
  );
  assert.equal(
    latestCodexRadarDetailSlot(local(7, 18)).getTime(),
    local(7, 18).getTime(),
  );
});

test("shouldRefreshCodexRadarDetail catches up once after a missed slot", () => {
  const now = local(7, 8, 5);

  assert.equal(shouldRefreshCodexRadarDetail({
    lastAttemptedSlotAt: null,
    lastSuccessfulRefreshAt: local(6, 18, 1).toISOString(),
    now,
  }), true);
  assert.equal(shouldRefreshCodexRadarDetail({
    lastAttemptedSlotAt: null,
    lastSuccessfulRefreshAt: local(7, 8, 0, 30).toISOString(),
    now,
  }), false);
  assert.equal(shouldRefreshCodexRadarDetail({
    lastAttemptedSlotAt: null,
    lastSuccessfulRefreshAt: null,
    now,
  }), true);
});

test("shouldRefreshCodexRadarDetail keeps a failed automatic slot eligible for recovery", () => {
  const morningNow = local(7, 8, 5);
  const morningSlot = latestCodexRadarDetailSlot(morningNow).toISOString();

  assert.equal(shouldRefreshCodexRadarDetail({
    lastAttemptedSlotAt: null,
    lastSuccessfulRefreshAt: null,
    now: morningNow,
  }), true);
  assert.equal(shouldRefreshCodexRadarDetail({
    lastAttemptedSlotAt: morningSlot,
    lastSuccessfulRefreshAt: null,
    now: morningNow,
  }), true);
  assert.equal(shouldRefreshCodexRadarDetail({
    lastAttemptedSlotAt: morningSlot,
    lastSuccessfulRefreshAt: null,
    now: local(7, 18, 5),
  }), true);
  assert.equal(shouldRefreshCodexRadarDetail({
    lastAttemptedSlotAt: morningSlot,
    lastSuccessfulRefreshAt: local(7, 8, 2).toISOString(),
    now: morningNow,
  }), false);
});

test("Codex Radar detail recovery progresses to ten minutes and never stops", () => {
  assert.deepEqual(
    Array.from({ length: 12 }, (_, failureCount) => (
      nextCodexRadarDetailRecoveryDelayMs(failureCount)
    )),
    [1_000, 2_000, 5_000, 10_000, 30_000, 60_000, 120_000, 300_000, 600_000, 600_000, 600_000, 600_000],
  );
});

test("manual Codex Radar detail refresh ignores the automatic attempt guard", () => {
  const now = local(7, 8, 5);

  assert.equal(shouldRefreshCodexRadarDetail({
    lastAttemptedSlotAt: latestCodexRadarDetailSlot(now).toISOString(),
    lastSuccessfulRefreshAt: null,
    mode: "manual",
    now,
  }), true);
});

test("millisecondsUntilNextCodexRadarDetailSlot points to the next local schedule", () => {
  assert.equal(
    millisecondsUntilNextCodexRadarDetailSlot(local(7, 7, 30)),
    30 * 60 * 1000,
  );
  assert.equal(
    millisecondsUntilNextCodexRadarDetailSlot(local(7, 17, 45)),
    15 * 60 * 1000,
  );
  assert.equal(
    millisecondsUntilNextCodexRadarDetailSlot(local(7, 18, 30)),
    13.5 * 60 * 60 * 1000,
  );
});
