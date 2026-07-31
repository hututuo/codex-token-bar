import type {
  AccountQuotaBundle,
  RunningThreadSummary,
} from "../types/dashboard";

export function latestTrustedStatusUpdate(
  quota: AccountQuotaBundle,
  runningThreads: RunningThreadSummary,
): Date | null {
  const candidates: number[] = [];
  if (
    runningThreads.updatedAt !== null
    && Number.isFinite(runningThreads.updatedAt)
    && runningThreads.updatedAt > 0
    && (runningThreads.status === "ready" || runningThreads.status === "stale")
  ) {
    candidates.push(runningThreads.updatedAt);
  }

  const quotaLoaded = [quota.quota.fiveHour, quota.quota.sevenDay]
    .some((window) => window.availability !== "unavailable");
  if (quotaLoaded) {
    const quotaUpdatedAt = Date.parse(quota.updatedAt);
    if (Number.isFinite(quotaUpdatedAt) && quotaUpdatedAt > 0) {
      candidates.push(quotaUpdatedAt);
    }
  }

  if (candidates.length === 0) {
    return null;
  }
  return new Date(Math.max(...candidates));
}
