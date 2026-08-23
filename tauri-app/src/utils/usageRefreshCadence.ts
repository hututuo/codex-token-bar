/**
 * Pure local-usage scheduling primitives.
 *
 * Usage rows are keyed by UTC Unix-second five-minute buckets. Refreshes are
 * allowed to publish only after a short settle period so an open bucket is not
 * treated as final. The next timer fire is aligned to a wall-clock boundary,
 * rather than being scheduled relative to the completion time of the previous
 * refresh.
 */

import {
  DEFAULT_USAGE_BACKGROUND_AGGREGATE_INTERVAL_MINUTES,
  DEFAULT_USAGE_VISIBLE_AGGREGATE_INTERVAL_MINUTES,
} from "../settings/usageRefreshCadence.ts";

export const USAGE_AGGREGATE_BUCKET_SECONDS = 5 * 60;
export const USAGE_AGGREGATE_BUCKET_MS = USAGE_AGGREGATE_BUCKET_SECONDS * 1_000;
export const USAGE_AGGREGATE_SETTLE_SECONDS = 15;
export const USAGE_AGGREGATE_SETTLE_MS = USAGE_AGGREGATE_SETTLE_SECONDS * 1_000;
export const USAGE_AGGREGATE_INTERVAL_MINUTES = [5, 10, 15, 30] as const;
export const fiveMinuteBoundary = USAGE_AGGREGATE_BUCKET_SECONDS;
export const settleDelay = USAGE_AGGREGATE_SETTLE_SECONDS;

function finiteNumber(value: number): number {
  return Number.isFinite(value) ? value : 0;
}

function supportedWallClockIntervalMinutes(value: number): number {
  return USAGE_AGGREGATE_INTERVAL_MINUTES.includes(value as (typeof USAGE_AGGREGATE_INTERVAL_MINUTES)[number])
    ? value
    : 5;
}

/** Return the UTC epoch-aligned five-minute bucket start, in Unix seconds. */
export function utcEpochFiveMinuteBucket(epochSeconds: number | Date): number {
  const seconds = epochSeconds instanceof Date
    ? epochSeconds.getTime() / 1_000
    : epochSeconds;
  return Math.floor(finiteNumber(seconds) / USAGE_AGGREGATE_BUCKET_SECONDS)
    * USAGE_AGGREGATE_BUCKET_SECONDS;
}

export const utcEpochFiveMinuteBoundary = utcEpochFiveMinuteBucket;
export const utcEpochFiveMinuteBucketStart = utcEpochFiveMinuteBucket;
export const usageAggregateBucketStartSeconds = utcEpochFiveMinuteBucket;

export function utcEpochFiveMinuteBoundaryDate(date: Date = new Date()): Date {
  return new Date(utcEpochFiveMinuteBucket(date) * 1_000);
}

/** Millisecond counterpart for timer callers using Date.now(). */
export function usageAggregateBucketStartMs(epochMs: number): number {
  return Math.floor(finiteNumber(epochMs) / USAGE_AGGREGATE_BUCKET_MS)
    * USAGE_AGGREGATE_BUCKET_MS;
}

/**
 * Return the newest bucket boundary whose preceding bucket has settled.
 * At `12:05:14` the `12:05` boundary is not eligible; at `12:05:15` it is.
 */
export function latestEligibleBoundary(
  nowEpochSeconds: number | Date = Date.now() / 1_000,
  settleSeconds = USAGE_AGGREGATE_SETTLE_SECONDS,
): number {
  const epochSeconds = nowEpochSeconds instanceof Date
    ? nowEpochSeconds.getTime() / 1_000
    : nowEpochSeconds;
  return utcEpochFiveMinuteBucket(
    finiteNumber(epochSeconds) - Math.max(0, finiteNumber(settleSeconds)),
  );
}

export const latestEligibleUsageBoundary = latestEligibleBoundary;
export const latestEligibleUsageAggregateBoundary = latestEligibleBoundary;

export function latestEligibleBoundaryDate(now: Date = new Date()): Date {
  return new Date(latestEligibleBoundary(now) * 1_000);
}

export function latestEligibleBoundaryMs(
  nowMs: number,
  settleMs = USAGE_AGGREGATE_SETTLE_MS,
): number {
  return usageAggregateBucketStartMs(
    finiteNumber(nowMs) - Math.max(0, finiteNumber(settleMs)),
  );
}

/**
 * Return the next local wall-clock boundary in Unix seconds. The result is
 * strictly after `nowEpochSeconds`, including when the input is exactly on a
 * boundary. The four supported cadence values are the only values accepted;
 * invalid input falls back to the five-minute boundary.
 */
export function nextWallClockBoundaryEpochSeconds(
  nowEpochSeconds: number | Date,
  intervalMinutes: number,
): number {
  const epochSeconds = nowEpochSeconds instanceof Date
    ? nowEpochSeconds.getTime() / 1_000
    : nowEpochSeconds;
  return nextWallClockBoundaryMs(
    finiteNumber(epochSeconds) * 1_000,
    intervalMinutes,
  ) / 1_000;
}

export const nextWallClockBoundary = nextWallClockBoundaryEpochSeconds;

export function nextWallClockBoundaryMs(nowMs: number, intervalMinutes: number): number {
  const currentMs = finiteNumber(nowMs);
  const date = new Date(currentMs);
  if (Number.isNaN(date.getTime())) {
    return currentMs;
  }
  const interval = supportedWallClockIntervalMinutes(intervalMinutes);
  const next = new Date(date);
  next.setSeconds(0, 0);
  const minute = next.getMinutes();
  const offset = interval - (minute % interval || interval);
  next.setMinutes(minute + offset, 0, 0);
  if (next.getTime() <= currentMs) {
    next.setMinutes(next.getMinutes() + interval, 0, 0);
  }
  return next.getTime();
}

/**
 * Native-policy-compatible aggregate fire date. Aggregate boundaries are UTC
 * epoch aligned; the settle delay is part of the fire date so a resumed timer
 * cannot immediately re-fire for a boundary that is still closing.
 */
export function nextAggregateFireDate(
  after: number | Date | {
    after: number | Date;
    intervalMinutes: number;
  },
  intervalMinutes?: number,
): number {
  const input = typeof after === "object" && !(after instanceof Date)
    ? after.after
    : after;
  const selectedIntervalMinutes = typeof after === "object" && !(after instanceof Date)
    ? after.intervalMinutes
    : intervalMinutes ?? 5;
  const epochSeconds = input instanceof Date ? input.getTime() / 1_000 : input;
  const current = finiteNumber(epochSeconds);
  const interval = supportedWallClockIntervalMinutes(selectedIntervalMinutes) * 60;
  const currentBoundary = Math.floor(current / interval) * interval;
  let candidate = currentBoundary + USAGE_AGGREGATE_SETTLE_SECONDS;
  if (candidate <= current) {
    candidate += interval;
  }
  return candidate;
}

export const nextAggregateFireEpochSeconds = nextAggregateFireDate;
export function nextAggregateFireAtMs(afterMs: number, intervalMinutes: number): number {
  return nextAggregateFireDate(afterMs / 1_000, intervalMinutes) * 1_000;
}
export const nextUsageAggregateFireEpochSeconds = nextAggregateFireDate;
export const nextUsageAggregateFireAtMs = nextAggregateFireAtMs;

export function aggregateInterval({
  mainDashboardVisible,
  settings,
}: {
  mainDashboardVisible: boolean;
  settings: {
    usageVisibleAggregateIntervalMinutes?: unknown;
    usageBackgroundAggregateIntervalMinutes?: unknown;
  };
}): number {
  const minutes = mainDashboardVisible
    ? Number(settings.usageVisibleAggregateIntervalMinutes)
    : Number(settings.usageBackgroundAggregateIntervalMinutes);
  const fallback = mainDashboardVisible
    ? DEFAULT_USAGE_VISIBLE_AGGREGATE_INTERVAL_MINUTES
    : DEFAULT_USAGE_BACKGROUND_AGGREGATE_INTERVAL_MINUTES;
  const normalized = USAGE_AGGREGATE_INTERVAL_MINUTES.includes(
    minutes as (typeof USAGE_AGGREGATE_INTERVAL_MINUTES)[number],
  ) ? minutes : fallback;
  return normalized * 60;
}
