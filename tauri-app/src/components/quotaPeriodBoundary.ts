export const QUOTA_PERIOD_BUCKET_SECONDS = 5 * 60;
export const QUOTA_PERIOD_SAFETY_MARGIN_SECONDS = 60;

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
    (boundaryUnix + QUOTA_PERIOD_SAFETY_MARGIN_SECONDS) / bucketSeconds,
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
    (boundaryUnix - QUOTA_PERIOD_SAFETY_MARGIN_SECONDS) / bucketSeconds,
  ) * bucketSeconds;
}
