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
    lastSuccessfulRefreshAt: "2026-07-06T18:01:00+08:00",
    now,
  }), true);
  assert.equal(shouldRefreshCodexRadarDetail({
    lastSuccessfulRefreshAt: "2026-07-07T08:00:30+08:00",
    now,
  }), false);
  assert.equal(shouldRefreshCodexRadarDetail({
    lastSuccessfulRefreshAt: null,
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
