import { canonicalAttributionBoundaryKey } from "./attributionBoundary.ts";

export interface PreciseUsageCatchUpInput {
  quotaUpdatedAt: string | null;
  preciseCoveredAt: string | null | undefined;
  preciseFresh: boolean | undefined;
  requestedForQuotaBoundaryKey: string | null;
}

export interface PreciseUsageCatchUpPlan {
  shouldSchedule: boolean;
  requestedForQuotaBoundaryKey: string | null;
}

/**
 * A quota refresh can finish while an older exact scan is already in flight.
 * The old scan publishes a conservative pre-sync coverage watermark, so it may
 * still trail the accepted quota. Schedule at most one post-settlement catch-up
 * for each distinct five-minute quota bucket; never spin indefinitely on a bad clock or
 * malformed native snapshot.
 */
export function planPreciseUsageCatchUp({
  quotaUpdatedAt,
  preciseCoveredAt,
  preciseFresh,
  requestedForQuotaBoundaryKey,
}: PreciseUsageCatchUpInput): PreciseUsageCatchUpPlan {
  const quotaMilliseconds = parsedMilliseconds(quotaUpdatedAt);
  const quotaBoundaryKey = canonicalAttributionBoundaryKey(quotaUpdatedAt);
  if (quotaMilliseconds === null || quotaBoundaryKey === undefined) {
    return { shouldSchedule: false, requestedForQuotaBoundaryKey };
  }
  const coveredBoundaryKey = canonicalAttributionBoundaryKey(preciseCoveredAt);
  if (preciseFresh === true
    && coveredBoundaryKey !== undefined
    && Number(coveredBoundaryKey) >= Number(quotaBoundaryKey)) {
    return { shouldSchedule: false, requestedForQuotaBoundaryKey };
  }
  if (quotaBoundaryKey === undefined
    || requestedForQuotaBoundaryKey === quotaBoundaryKey) {
    return { shouldSchedule: false, requestedForQuotaBoundaryKey };
  }
  return {
    shouldSchedule: true,
    requestedForQuotaBoundaryKey: quotaBoundaryKey,
  };
}

function parsedMilliseconds(value: string | null): number | null {
  if (!value) return null;
  const milliseconds = Date.parse(value);
  return Number.isFinite(milliseconds) ? milliseconds : null;
}
