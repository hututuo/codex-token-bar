export const QUOTA_PERIOD_BUCKET_SECONDS = 5 * 60;

/**
 * Returns the first complete bucket that is safe to include after a
 * quota-period boundary. Mixed edge buckets are kept separately by callers;
 * this helper defines only the comparable interior.
 */
export function firstCompleteQuotaBucketStart(
  boundaryUnix: number,
  bucketSeconds = QUOTA_PERIOD_BUCKET_SECONDS,
): number {
  if (!Number.isFinite(boundaryUnix)) return Number.NaN;
  if (!Number.isFinite(bucketSeconds) || bucketSeconds <= 0) return Number.NaN;
  const bucketStart = Math.floor(boundaryUnix / bucketSeconds) * bucketSeconds;
  if (Math.abs(boundaryUnix - bucketStart) <= 1e-6) return bucketStart;
  return Math.ceil(
    boundaryUnix / bucketSeconds,
  ) * bucketSeconds;
}

/**
 * Returns the exclusive end of the last complete bucket that is safe to
 * include before a quota-period boundary. Mixed edge buckets are kept
 * separately by callers.
 */
export function lastCompleteQuotaBucketEnd(
  boundaryUnix: number,
  bucketSeconds = QUOTA_PERIOD_BUCKET_SECONDS,
): number {
  if (!Number.isFinite(boundaryUnix)) return Number.NaN;
  if (!Number.isFinite(bucketSeconds) || bucketSeconds <= 0) return Number.NaN;
  const bucketStart = Math.floor(boundaryUnix / bucketSeconds) * bucketSeconds;
  if (Math.abs(boundaryUnix - bucketStart) <= 1e-6) return bucketStart;
  return Math.floor(
    boundaryUnix / bucketSeconds,
  ) * bucketSeconds;
}

/**
 * Read old five-minute snapshots unchanged; refine only edge points whose raw
 * minute detail reconciles with every aggregate component. No proportional
 * allocation or historical rebuild is used.
 */
export function partitionQuotaPeriodPoints(
  points: import("../types/usage").RecentUsagePoint[],
  periodStartUnix: number,
  periodEndUnix: number,
): {
  included: import("../types/usage").RecentUsagePoint[];
  leading: import("../types/usage").RecentUsagePoint[];
  trailing: import("../types/usage").RecentUsagePoint[];
} {
  const included: import("../types/usage").RecentUsagePoint[] = [];
  const leading: import("../types/usage").RecentUsagePoint[] = [];
  const trailing: import("../types/usage").RecentUsagePoint[] = [];
  if (!Number.isFinite(periodStartUnix) || !Number.isFinite(periodEndUnix)
    || periodEndUnix <= periodStartUnix) return { included, leading, trailing };
  const firstMinute = Math.ceil(periodStartUnix / 60) * 60;
  const lastMinuteEnd = Math.floor(periodEndUnix / 60) * 60;
  for (const point of points) {
    const end = point.startUnix + QUOTA_PERIOD_BUCKET_SECONDS;
    if (!Number.isFinite(point.startUnix) || end <= periodStartUnix || point.startUnix >= periodEndUnix) continue;
    if (point.startUnix >= periodStartUnix && end <= periodEndUnix) {
      included.push(point);
      continue;
    }
    const minutes = reconciledMinutePoints(point);
    const duration = minutes ? 60 : QUOTA_PERIOD_BUCKET_SECONDS;
    for (const slice of minutes ?? [point]) {
      const sliceEnd = slice.startUnix + duration;
      if (minutes && slice.startUnix >= firstMinute && slice.startUnix < lastMinuteEnd) {
        included.push(slice);
      } else if (slice.startUnix < periodStartUnix && sliceEnd > periodStartUnix) {
        leading.push(slice);
      } else if (slice.startUnix < periodEndUnix && sliceEnd > periodEndUnix) {
        trailing.push(slice);
      }
    }
  }
  return { included, leading, trailing };
}

function reconciledMinutePoints(
  point: import("../types/usage").RecentUsagePoint,
): import("../types/usage").RecentUsagePoint[] | null {
  const rows = point.minuteModelBreakdowns;
  if (!Array.isArray(rows) || rows.length === 0) return null;
  const byMinute = new Map<number, import("../types/usage").RecentUsagePoint>();
  const totals = { inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, tokens: 0, calls: 0 };
  for (const row of rows) {
    const start = row.eventStartUnix;
    const b = row.breakdown;
    if (typeof start !== "number" || !Number.isFinite(start) || start % 60 !== 0
      || start < point.startUnix || start >= point.startUnix + QUOTA_PERIOD_BUCKET_SECONDS
      || !b || ![b.inputTokens, b.cachedInputTokens, b.outputTokens, b.totalTokens, b.calls]
        .every((value) => typeof value === "number" && Number.isSafeInteger(value) && value >= 0)
      || b.cachedInputTokens > b.inputTokens) return null;
    const minute = byMinute.get(start) ?? {
      ...point, startUnix: start, minuteModelBreakdowns: undefined,
      tokens: 0, calls: 0, inputTokens: 0, cachedInputTokens: 0, outputTokens: 0,
      modelBreakdowns: [], sourceContributions: undefined,
    };
    minute.tokens += b.totalTokens;
    minute.calls += b.calls;
    minute.inputTokens += b.inputTokens;
    minute.cachedInputTokens += b.cachedInputTokens;
    minute.outputTokens += b.outputTokens;
    minute.modelBreakdowns!.push(row);
    minute.cacheHitRate = minute.inputTokens > 0 ? minute.cachedInputTokens / minute.inputTokens : null;
    byMinute.set(start, minute);
    totals.tokens += b.totalTokens;
    totals.calls += b.calls;
    totals.inputTokens += b.inputTokens;
    totals.cachedInputTokens += b.cachedInputTokens;
    totals.outputTokens += b.outputTokens;
  }
  if (totals.tokens !== point.tokens || totals.calls !== point.calls
    || totals.inputTokens !== point.inputTokens || totals.cachedInputTokens !== point.cachedInputTokens
    || totals.outputTokens !== point.outputTokens) return null;
  return [...byMinute.values()].sort((left, right) => left.startUnix - right.startUnix);
}
