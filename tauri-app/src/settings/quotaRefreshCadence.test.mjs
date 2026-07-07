import assert from "node:assert/strict";
import test from "node:test";
import {
  DEFAULT_QUOTA_REFRESH_INTERVAL_MS,
  QUOTA_REFRESH_CADENCE_OPTIONS,
  quotaRefreshCadenceLabel,
  sanitizeQuotaRefreshIntervalMs,
} from "./quotaRefreshCadence.ts";

test("quota refresh cadence exposes the fixed supported intervals", () => {
  assert.deepEqual(
    QUOTA_REFRESH_CADENCE_OPTIONS.map((option) => option.valueMs),
    [30_000, 60_000, 180_000, 300_000, 600_000],
  );
  assert.deepEqual(
    QUOTA_REFRESH_CADENCE_OPTIONS.map((option) => option.label),
    ["30 秒", "1 分钟", "3 分钟", "5 分钟", "10 分钟"],
  );
  assert.equal(DEFAULT_QUOTA_REFRESH_INTERVAL_MS, 60_000);
});

test("quota refresh cadence sanitizes invalid values back to the current one-minute default", () => {
  for (const value of [undefined, null, Number.NaN, Infinity, -1, 0, 31_000, "60000"]) {
    assert.equal(sanitizeQuotaRefreshIntervalMs(value), 60_000, String(value));
  }

  assert.equal(sanitizeQuotaRefreshIntervalMs(30_000), 30_000);
  assert.equal(sanitizeQuotaRefreshIntervalMs(600_000), 600_000);
});

test("quota refresh cadence labels use compact Chinese copy", () => {
  assert.equal(quotaRefreshCadenceLabel(30_000), "30 秒");
  assert.equal(quotaRefreshCadenceLabel(60_000), "1 分钟");
  assert.equal(quotaRefreshCadenceLabel(180_000), "3 分钟");
  assert.equal(quotaRefreshCadenceLabel(300_000), "5 分钟");
  assert.equal(quotaRefreshCadenceLabel(600_000), "10 分钟");
  assert.equal(quotaRefreshCadenceLabel(123), "1 分钟");
});
