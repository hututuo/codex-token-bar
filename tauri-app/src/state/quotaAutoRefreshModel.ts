import { sanitizeQuotaRefreshIntervalMs } from "../settings/quotaRefreshCadence";

interface QuotaAutoRefreshPlanInput {
  dashboardReady: boolean;
  fastSnapshotLoaded: boolean;
  intervalMs: unknown;
}

export interface QuotaAutoRefreshPlan {
  active: boolean;
  intervalMs: number | null;
}

export function makeQuotaAutoRefreshPlan({
  dashboardReady,
  fastSnapshotLoaded,
  intervalMs,
}: QuotaAutoRefreshPlanInput): QuotaAutoRefreshPlan {
  if (!fastSnapshotLoaded || !dashboardReady) {
    return { active: false, intervalMs: null };
  }

  return {
    active: true,
    intervalMs: sanitizeQuotaRefreshIntervalMs(intervalMs),
  };
}
