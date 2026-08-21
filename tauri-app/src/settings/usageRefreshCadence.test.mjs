import assert from "node:assert/strict";
import test from "node:test";
import {
  DEFAULT_USAGE_BACKGROUND_AGGREGATE_INTERVAL_MINUTES,
  DEFAULT_USAGE_LIGHT_REFRESH_INTERVAL_SECONDS,
  DEFAULT_USAGE_VISIBLE_AGGREGATE_INTERVAL_MINUTES,
  sanitizeUsageBackgroundAggregateIntervalMinutes,
  sanitizeUsageRefreshSettings,
  usageLightRefreshIntervalLabel,
  USAGE_AGGREGATE_INTERVAL_OPTIONS,
  USAGE_LIGHT_REFRESH_INTERVAL_OPTIONS,
} from "./usageRefreshCadence.ts";

test("local usage cadence exposes the requested supported values and defaults", () => {
  assert.deepEqual(
    USAGE_LIGHT_REFRESH_INTERVAL_OPTIONS.map((option) => option.valueSeconds),
    [60, 150, 300, 600],
  );
  assert.deepEqual(
    USAGE_AGGREGATE_INTERVAL_OPTIONS.map((option) => option.valueMinutes),
    [5, 10, 15, 30],
  );
  assert.equal(DEFAULT_USAGE_LIGHT_REFRESH_INTERVAL_SECONDS, 150);
  assert.equal(DEFAULT_USAGE_VISIBLE_AGGREGATE_INTERVAL_MINUTES, 10);
  assert.equal(DEFAULT_USAGE_BACKGROUND_AGGREGATE_INTERVAL_MINUTES, 30);
  assert.equal(usageLightRefreshIntervalLabel(150), "2.5 分钟");
});

test("local usage cadence sanitizes missing and invalid values independently", () => {
  assert.deepEqual(sanitizeUsageRefreshSettings(undefined), {
    usageLightRefreshIntervalSeconds: 150,
    usageVisibleAggregateIntervalMinutes: 10,
    usageBackgroundAggregateIntervalMinutes: 30,
  });
  assert.deepEqual(sanitizeUsageRefreshSettings({
    usageLightRefreshIntervalSeconds: 301,
    usageVisibleAggregateIntervalMinutes: 0,
    usageBackgroundAggregateIntervalMinutes: "30",
  }), {
    usageLightRefreshIntervalSeconds: 150,
    usageVisibleAggregateIntervalMinutes: 10,
    usageBackgroundAggregateIntervalMinutes: 30,
  });
  assert.equal(sanitizeUsageBackgroundAggregateIntervalMinutes(null), 30);
  assert.deepEqual(sanitizeUsageRefreshSettings({
    usageLightRefreshIntervalSeconds: 600,
    usageVisibleAggregateIntervalMinutes: 15,
    usageBackgroundAggregateIntervalMinutes: 10,
  }), {
    usageLightRefreshIntervalSeconds: 600,
    usageVisibleAggregateIntervalMinutes: 15,
    usageBackgroundAggregateIntervalMinutes: 10,
  });
});
