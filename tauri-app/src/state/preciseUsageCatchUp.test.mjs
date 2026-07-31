import assert from "node:assert/strict";
import test from "node:test";

import { planPreciseUsageCatchUp } from "./preciseUsageCatchUp.ts";

function plan(overrides = {}) {
  return planPreciseUsageCatchUp({
    quotaUpdatedAt: "2026-07-31T05:02:00Z",
    preciseCoveredAt: "2026-07-31T05:01:59Z",
    preciseFresh: true,
    requestedForQuotaUpdatedAt: null,
    ...overrides,
  });
}

test("an in-flight scan older than a new quota schedules one catch-up only", () => {
  const first = plan();
  assert.deepEqual(first, {
    shouldSchedule: true,
    requestedForQuotaUpdatedAt: "2026-07-31T05:02:00Z",
  });

  const repeated = plan({ requestedForQuotaUpdatedAt: first.requestedForQuotaUpdatedAt });
  assert.equal(repeated.shouldSchedule, false);

  const nextQuota = plan({
    quotaUpdatedAt: "2026-07-31T05:07:00Z",
    preciseCoveredAt: "2026-07-31T05:06:59Z",
    requestedForQuotaUpdatedAt: first.requestedForQuotaUpdatedAt,
  });
  assert.equal(nextQuota.shouldSchedule, true);
  assert.equal(nextQuota.requestedForQuotaUpdatedAt, "2026-07-31T05:07:00Z");
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
