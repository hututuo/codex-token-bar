import assert from "node:assert/strict";
import test from "node:test";

import {
  MAX_QUOTA_REFRESH_DELAY_MS,
  MAX_BACKGROUND_REFRESH_DELAY_MS,
  persistentRefreshDelayMs,
} from "./persistentRefreshBackoff.ts";

test("quota retry starts fast and remains capped at one minute forever", () => {
  assert.deepEqual(
    Array.from({ length: 10 }, (_, failureCount) => persistentRefreshDelayMs(failureCount)),
    [1_000, 2_000, 5_000, 10_000, 30_000, 60_000, 60_000, 60_000, 60_000, 60_000],
  );
  assert.equal(MAX_QUOTA_REFRESH_DELAY_MS, 60_000);
});

test("channel-specific maximum delay is honored without terminating retries", () => {
  assert.equal(persistentRefreshDelayMs(99, 5_000), 5_000);
  assert.equal(persistentRefreshDelayMs(Number.NaN), 1_000);
  assert.deepEqual(
    Array.from({ length: 12 }, (_, count) => (
      persistentRefreshDelayMs(count, MAX_BACKGROUND_REFRESH_DELAY_MS)
    )),
    [1_000, 2_000, 5_000, 10_000, 30_000, 60_000, 120_000, 300_000, 600_000, 600_000, 600_000, 600_000],
  );
});
