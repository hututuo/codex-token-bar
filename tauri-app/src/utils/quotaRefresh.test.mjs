import assert from "node:assert/strict";
import test from "node:test";
import { nextQuotaResetRefreshDelayMs, QUOTA_RESET_REFRESH_GRACE_MS } from "./quotaRefresh.ts";

function quotaWithResets(fiveHourReset, sevenDayReset) {
  return {
    fiveHour: {
      label: "5h",
      remainingPercent: 0,
      usedPercent: 0,
      resetsAt: "",
      resetsAtUnix: fiveHourReset,
    },
    sevenDay: {
      label: "7d",
      remainingPercent: 0,
      usedPercent: 0,
      resetsAt: "",
      resetsAtUnix: sevenDayReset,
    },
    resetCredit: {
      availableCount: 0,
      status: "",
      credits: [],
    },
    paceLabel: "",
  };
}

test("nextQuotaResetRefreshDelayMs schedules the nearest reset plus a short grace", () => {
  const nowMs = 1_000_000;
  const quota = quotaWithResets(1_060, 1_360);

  assert.equal(nextQuotaResetRefreshDelayMs(quota, nowMs), 60_000 + QUOTA_RESET_REFRESH_GRACE_MS);
});

test("nextQuotaResetRefreshDelayMs ignores expired reset timestamps to avoid refresh loops", () => {
  const nowMs = 1_000_000;
  const quota = quotaWithResets(900, 950);

  assert.equal(nextQuotaResetRefreshDelayMs(quota, nowMs), null);
});

test("nextQuotaResetRefreshDelayMs works when only one quota window has a reset timestamp", () => {
  const nowMs = 1_000_000;
  const quota = quotaWithResets(null, 1_090);

  assert.equal(nextQuotaResetRefreshDelayMs(quota, nowMs, 2_000), 92_000);
});
