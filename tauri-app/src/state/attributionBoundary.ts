const RFC3339_TIMESTAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;

/**
 * Return the semantic attribution boundary represented by an RFC3339
 * timestamp. Attribution callbacks can carry different string renderings of
 * the same second (for example, `.123Z` versus `.000Z`); dedupe must use this
 * shared unit rather than the source spelling. Invalid or missing values are
 * intentionally rejected so callers fall back to a real native refresh.
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
  return Number.isSafeInteger(unixSeconds) ? String(unixSeconds) : undefined;
}
