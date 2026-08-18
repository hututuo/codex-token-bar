const RFC3339_TIMESTAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;

/**
 * Return the semantic attribution boundary represented by an RFC3339
 * timestamp. The exact index publishes attribution in fixed five-minute
 * buckets, so a poll timestamp is only a new boundary when it enters a new
 * bucket. Keeping the key at bucket precision prevents every quota poll (or
 * a millisecond rendering of the same poll) from promoting another full
 * dashboard aggregation. Invalid or missing values are intentionally rejected
 * so callers fall back to a real native refresh.
 */
export function canonicalAttributionBoundaryKey(
  value: string | null | undefined,
): string | undefined {
  if (typeof value !== "string") {
    return undefined;
  }
  const timestamp = value.trim();
  if (!RFC3339_TIMESTAMP.test(timestamp)) {
    return undefined;
  }
  const milliseconds = Date.parse(timestamp);
  if (!Number.isFinite(milliseconds)) {
    return undefined;
  }
  const unixSeconds = Math.floor(milliseconds / 1_000);
  const bucketStart = Math.floor(unixSeconds / 300) * 300;
  return Number.isSafeInteger(bucketStart) ? String(bucketStart) : undefined;
}
