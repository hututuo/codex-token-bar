import assert from "node:assert/strict";
import test from "node:test";
import {
  ACTIVE_USAGE_REFRESH_INTERVAL_MS,
  LIVE_USAGE_ACTIVITY_HOLD_MS,
  liveRateHasUsageRefreshActivity,
  usageRefreshIntervalMs,
} from "./usageRefreshCadence.ts";

const BASELINE_INTERVAL_MS = 180_000;
const NOW_MS = 10_000_000;

test("usageRefreshIntervalMs uses the active interval while live activity is inside the hold window", () => {
  const interval = usageRefreshIntervalMs({
    baselineIntervalMs: BASELINE_INTERVAL_MS,
    lastLiveActivityAtMs: NOW_MS - LIVE_USAGE_ACTIVITY_HOLD_MS + 1,
    nowMs: NOW_MS,
  });

  assert.equal(interval, ACTIVE_USAGE_REFRESH_INTERVAL_MS);
});

test("usageRefreshIntervalMs returns baseline when the hold window expires or activity is missing", () => {
  assert.equal(
    usageRefreshIntervalMs({
      baselineIntervalMs: BASELINE_INTERVAL_MS,
      lastLiveActivityAtMs: NOW_MS - LIVE_USAGE_ACTIVITY_HOLD_MS,
      nowMs: NOW_MS,
    }),
    BASELINE_INTERVAL_MS,
  );
  assert.equal(
    usageRefreshIntervalMs({
      baselineIntervalMs: BASELINE_INTERVAL_MS,
      lastLiveActivityAtMs: 0,
      nowMs: NOW_MS,
    }),
    BASELINE_INTERVAL_MS,
  );
});

test("liveRateHasUsageRefreshActivity treats selected and all-session rates independently", () => {
  assert.equal(liveRateHasUsageRefreshActivity({ tokensPerSecond: 0.051, selectedTokensPerSecond: 0 }), true);
  assert.equal(liveRateHasUsageRefreshActivity({ tokensPerSecond: 0, selectedTokensPerSecond: 0.051 }), true);
  assert.equal(liveRateHasUsageRefreshActivity({ tokensPerSecond: 0, selectedTokensPerSecond: 0 }), false);
});

test("liveRateHasUsageRefreshActivity requires rates above the activity threshold", () => {
  assert.equal(liveRateHasUsageRefreshActivity({ tokensPerSecond: 0.05, selectedTokensPerSecond: 0 }), false);
  assert.equal(liveRateHasUsageRefreshActivity({ tokensPerSecond: 0.049, selectedTokensPerSecond: 0.05 }), false);
  assert.equal(liveRateHasUsageRefreshActivity({ tokensPerSecond: 0.050_001, selectedTokensPerSecond: 0 }), true);
});
