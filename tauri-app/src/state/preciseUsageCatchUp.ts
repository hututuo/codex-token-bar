export interface PreciseUsageCatchUpInput {
  quotaUpdatedAt: string | null;
  preciseCoveredAt: string | null | undefined;
  preciseFresh: boolean | undefined;
  requestedForQuotaUpdatedAt: string | null;
}

export interface PreciseUsageCatchUpPlan {
  shouldSchedule: boolean;
  requestedForQuotaUpdatedAt: string | null;
}

/**
 * A quota refresh can finish while an older exact scan is already in flight.
 * The old scan publishes a conservative pre-sync coverage watermark, so it may
 * still trail the accepted quota. Schedule at most one post-settlement catch-up
 * for each distinct quota timestamp; never spin indefinitely on a bad clock or
 * malformed native snapshot.
 */
export function planPreciseUsageCatchUp({
  quotaUpdatedAt,
  preciseCoveredAt,
  preciseFresh,
  requestedForQuotaUpdatedAt,
}: PreciseUsageCatchUpInput): PreciseUsageCatchUpPlan {
  const quotaMilliseconds = parsedMilliseconds(quotaUpdatedAt);
  if (quotaMilliseconds === null) {
    return { shouldSchedule: false, requestedForQuotaUpdatedAt };
  }
  const coveredMilliseconds = parsedMilliseconds(preciseCoveredAt ?? null);
  if (preciseFresh === true
    && coveredMilliseconds !== null
    && coveredMilliseconds >= quotaMilliseconds) {
    return { shouldSchedule: false, requestedForQuotaUpdatedAt };
  }
  if (requestedForQuotaUpdatedAt === quotaUpdatedAt) {
    return { shouldSchedule: false, requestedForQuotaUpdatedAt };
  }
  return {
    shouldSchedule: true,
    requestedForQuotaUpdatedAt: quotaUpdatedAt,
  };
}

function parsedMilliseconds(value: string | null): number | null {
  if (!value) return null;
  const milliseconds = Date.parse(value);
  return Number.isFinite(milliseconds) ? milliseconds : null;
}
