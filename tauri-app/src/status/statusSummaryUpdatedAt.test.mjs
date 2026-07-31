import assert from "node:assert/strict";
import test from "node:test";

import { latestTrustedStatusUpdate } from "./statusSummaryUpdatedAt.ts";

const pendingRunning = {
  total: null,
  mainThreads: null,
  subagents: null,
  status: "scanning",
  updatedAt: null,
  detail: "",
  livenessLeaseHours: 24,
};

function unavailableQuota() {
  return {
    updatedAt: new Date().toISOString(),
    quota: {
      fiveHour: { availability: "unavailable" },
      sevenDay: { availability: "unavailable" },
    },
  };
}

test("status summary never presents placeholder construction time as a data update", () => {
  assert.equal(
    latestTrustedStatusUpdate(unavailableQuota(), pendingRunning),
    null,
  );
});

test("status summary uses the newest successful source timestamp and retains stale success time", () => {
  const quota = unavailableQuota();
  quota.updatedAt = "2026-08-01T10:00:00.000Z";
  quota.quota.sevenDay.availability = "measured";
  const running = {
    ...pendingRunning,
    total: 2,
    mainThreads: 1,
    subagents: 1,
    status: "stale",
    updatedAt: Date.parse("2026-08-01T10:00:01.000Z"),
  };

  assert.equal(
    latestTrustedStatusUpdate(quota, running)?.toISOString(),
    "2026-08-01T10:00:01.000Z",
  );
});

test("status summary ignores timestamps attached only to unavailable results", () => {
  const quota = unavailableQuota();
  quota.updatedAt = "2026-08-01T10:00:00.000Z";
  const unavailableRunning = {
    ...pendingRunning,
    status: "unavailable",
    updatedAt: Date.parse("2026-08-01T10:00:01.000Z"),
  };

  assert.equal(latestTrustedStatusUpdate(quota, unavailableRunning), null);
});
