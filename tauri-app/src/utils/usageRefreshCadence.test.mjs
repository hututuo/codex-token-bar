import assert from "node:assert/strict";
import test from "node:test";
import {
  aggregateInterval,
  USAGE_AGGREGATE_BUCKET_SECONDS,
  USAGE_AGGREGATE_SETTLE_SECONDS,
  latestEligibleBoundary,
  latestEligibleBoundaryMs,
  nextAggregateFireDate,
  nextWallClockBoundaryEpochSeconds,
  nextWallClockBoundaryMs,
  usageAggregateBucketStartMs,
  utcEpochFiveMinuteBucket,
} from "./usageRefreshCadence.ts";
import { sanitizeUsageRefreshSettings } from "../settings/usageRefreshCadence.ts";

test("usage buckets are aligned to UTC Unix five-minute boundaries", () => {
  assert.equal(USAGE_AGGREGATE_BUCKET_SECONDS, 300);
  assert.equal(utcEpochFiveMinuteBucket(0), 0);
  assert.equal(utcEpochFiveMinuteBucket(301), 300);
  assert.equal(utcEpochFiveMinuteBucket(599), 300);
  assert.equal(utcEpochFiveMinuteBucket(600), 600);
  assert.equal(usageAggregateBucketStartMs(300_001), 300_000);
});

test("latest eligible boundary waits for the fifteen-second settle window", () => {
  const boundary = 10 * 60;
  assert.equal(
    latestEligibleBoundary(boundary + USAGE_AGGREGATE_SETTLE_SECONDS - 1),
    boundary - 300,
  );
  assert.equal(
    latestEligibleBoundary(boundary + USAGE_AGGREGATE_SETTLE_SECONDS),
    boundary,
  );
  assert.equal(latestEligibleBoundaryMs((boundary + 15) * 1_000), boundary * 1_000);
  assert.equal(latestEligibleBoundary(boundary + 15, 30), boundary - 300);
});

test("next wall-clock fire is strictly after now and aligned to the selected cadence", () => {
  const now = Date.UTC(2026, 7, 18, 12, 23, 41) / 1_000;
  assert.equal(
    nextWallClockBoundaryEpochSeconds(now, 5),
    Date.UTC(2026, 7, 18, 12, 25, 0) / 1_000,
  );
  assert.equal(
    nextWallClockBoundaryEpochSeconds(Date.UTC(2026, 7, 18, 12, 30, 0) / 1_000, 10),
    Date.UTC(2026, 7, 18, 12, 40, 0) / 1_000,
  );
  assert.equal(
    nextWallClockBoundaryMs(Date.UTC(2026, 7, 18, 12, 44, 0), 15),
    Date.UTC(2026, 7, 18, 12, 45, 0),
  );
  assert.equal(
    nextWallClockBoundaryEpochSeconds(now, 30),
    Date.UTC(2026, 7, 18, 12, 30, 0) / 1_000,
  );
});

test("aggregate fire date includes settle delay and never re-fires the settled boundary", () => {
  const after = 4 * 60 + 50;
  for (const minutes of [5, 10, 15, 30]) {
    assert.equal(nextAggregateFireDate(after, minutes), minutes * 60 + 15);
  }
  assert.equal(nextAggregateFireDate(5 * 60 + 15, 5), 10 * 60 + 15);
  assert.equal(nextAggregateFireDate(5 * 60 + 15, 99), 10 * 60 + 15);
});

test("aggregate interval follows visible/background settings without quota coupling", () => {
  const settings = sanitizeUsageRefreshSettings({
    usageLightRefreshIntervalSeconds: 60,
    usageVisibleAggregateIntervalMinutes: 15,
    usageBackgroundAggregateIntervalMinutes: 30,
  });
  // Keep the pure utility test independent from the settings module's public
  // object shape while documenting the expected runtime values.
  assert.equal(settings.usageVisibleAggregateIntervalMinutes * 60, 900);
  assert.equal(settings.usageBackgroundAggregateIntervalMinutes * 60, 1_800);
  assert.equal(aggregateInterval({ mainDashboardVisible: true, settings }), 900);
  assert.equal(aggregateInterval({ mainDashboardVisible: false, settings }), 1_800);
});
