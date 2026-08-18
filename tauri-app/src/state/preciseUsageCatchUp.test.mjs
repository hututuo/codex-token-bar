import assert from "node:assert/strict";
import test from "node:test";

import { planPreciseUsageCatchUp } from "./preciseUsageCatchUp.ts";

function plan(overrides = {}) {
  return planPreciseUsageCatchUp({
    quotaUpdatedAt: "2026-07-31T05:02:00Z",
    preciseCoveredAt: "2026-07-31T04:59:59Z",
    preciseFresh: true,
    requestedForQuotaBoundaryKey: null,
    ...overrides,
  });
}

test("an in-flight scan older than a new quota schedules one catch-up only", () => {
  const first = plan();
  assert.deepEqual(first, {
    shouldSchedule: true,
    requestedForQuotaBoundaryKey: "1785474000",
  });

  const repeated = plan({ requestedForQuotaBoundaryKey: first.requestedForQuotaBoundaryKey });
  assert.equal(repeated.shouldSchedule, false);

  const nextQuota = plan({
    quotaUpdatedAt: "2026-07-31T05:07:00Z",
    preciseCoveredAt: "2026-07-31T05:04:59Z",
    requestedForQuotaBoundaryKey: first.requestedForQuotaBoundaryKey,
  });
  assert.equal(nextQuota.shouldSchedule, true);
  assert.equal(nextQuota.requestedForQuotaBoundaryKey, "1785474300");
});

test("millisecond renderings within one quota bucket schedule only one catch-up", () => {
  const first = plan({ quotaUpdatedAt: "2026-07-31T05:02:00.123Z" });
  assert.equal(first.shouldSchedule, true);
  const repeated = plan({
    quotaUpdatedAt: "2026-07-31T05:02:00.000Z",
    requestedForQuotaBoundaryKey: first.requestedForQuotaBoundaryKey,
  });
  assert.equal(repeated.shouldSchedule, false);
});

test("coverage and quota renderings in one bucket are one semantic boundary", () => {
  assert.equal(plan({
    quotaUpdatedAt: "2026-07-31T05:02:00.999Z",
    preciseCoveredAt: "2026-07-31T05:02:00.000Z",
  }).shouldSchedule, false);
});

test("equal or newer full precise coverage never schedules a catch-up", () => {
  assert.equal(plan({ preciseCoveredAt: "2026-07-31T05:02:00Z" }).shouldSchedule, false);
  assert.equal(plan({ preciseCoveredAt: "2026-07-31T05:03:00Z" }).shouldSchedule, false);
});

test("missing freshness can retry once but malformed quota time cannot loop", () => {
  assert.equal(plan({ preciseFresh: false }).shouldSchedule, true);
  assert.equal(plan({ quotaUpdatedAt: "bad-time" }).shouldSchedule, false);
  assert.equal(plan({ quotaUpdatedAt: null }).shouldSchedule, false);
});
