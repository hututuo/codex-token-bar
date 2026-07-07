import assert from "node:assert/strict";
import test from "node:test";

import {
  latestCodexRadarDetailSlot,
  millisecondsUntilNextCodexRadarDetailSlot,
  shouldRefreshCodexRadarDetail,
} from "./codexRadarDetailRefreshPlan.ts";

test("latestCodexRadarDetailSlot follows local 08:00 and 18:00 boundaries", () => {
  assert.equal(
    latestCodexRadarDetailSlot(new Date("2026-07-07T07:59:00+08:00")).toISOString(),
    "2026-07-06T10:00:00.000Z",
  );
  assert.equal(
    latestCodexRadarDetailSlot(new Date("2026-07-07T08:00:00+08:00")).toISOString(),
    "2026-07-07T00:00:00.000Z",
  );
  assert.equal(
    latestCodexRadarDetailSlot(new Date("2026-07-07T18:00:00+08:00")).toISOString(),
    "2026-07-07T10:00:00.000Z",
  );
});

test("shouldRefreshCodexRadarDetail catches up once after a missed slot", () => {
  const now = new Date("2026-07-07T08:05:00+08:00");

  assert.equal(shouldRefreshCodexRadarDetail({
    lastAttemptedSlotAt: null,
    lastSuccessfulRefreshAt: "2026-07-06T18:01:00+08:00",
    now,
  }), true);
  assert.equal(shouldRefreshCodexRadarDetail({
    lastAttemptedSlotAt: null,
    lastSuccessfulRefreshAt: "2026-07-07T08:00:30+08:00",
    now,
  }), false);
  assert.equal(shouldRefreshCodexRadarDetail({
    lastAttemptedSlotAt: null,
    lastSuccessfulRefreshAt: null,
    now,
  }), true);
});

test("shouldRefreshCodexRadarDetail does not retry-loop the same automatic slot", () => {
  const morningNow = new Date("2026-07-07T08:05:00+08:00");
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
  }), false);
  assert.equal(shouldRefreshCodexRadarDetail({
    lastAttemptedSlotAt: morningSlot,
    lastSuccessfulRefreshAt: null,
    now: new Date("2026-07-07T18:05:00+08:00"),
  }), true);
  assert.equal(shouldRefreshCodexRadarDetail({
    lastAttemptedSlotAt: morningSlot,
    lastSuccessfulRefreshAt: "2026-07-07T08:02:00+08:00",
    now: morningNow,
  }), false);
});

test("manual Codex Radar detail refresh ignores the automatic attempt guard", () => {
  const now = new Date("2026-07-07T08:05:00+08:00");

  assert.equal(shouldRefreshCodexRadarDetail({
    lastAttemptedSlotAt: latestCodexRadarDetailSlot(now).toISOString(),
    lastSuccessfulRefreshAt: null,
    mode: "manual",
    now,
  }), true);
});

test("millisecondsUntilNextCodexRadarDetailSlot points to the next local schedule", () => {
  assert.equal(
    millisecondsUntilNextCodexRadarDetailSlot(new Date("2026-07-07T07:30:00+08:00")),
    30 * 60 * 1000,
  );
  assert.equal(
    millisecondsUntilNextCodexRadarDetailSlot(new Date("2026-07-07T17:45:00+08:00")),
    15 * 60 * 1000,
  );
  assert.equal(
    millisecondsUntilNextCodexRadarDetailSlot(new Date("2026-07-07T18:30:00+08:00")),
    13.5 * 60 * 60 * 1000,
  );
});
