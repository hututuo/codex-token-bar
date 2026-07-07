import { sanitizeQuotaRefreshIntervalMs } from "../settings/quotaRefreshCadence";

interface QuotaAutoRefreshPlanInput {
  dashboardReady: boolean;
  fastSnapshotLoaded: boolean;
  intervalMs: unknown;
  loading: boolean;
}

export interface QuotaAutoRefreshPlan {
  active: boolean;
  intervalMs: number | null;
}

export function makeQuotaAutoRefreshPlan({
  dashboardReady,
  fastSnapshotLoaded,
  intervalMs,
  loading,
}: QuotaAutoRefreshPlanInput): QuotaAutoRefreshPlan {
  if (!fastSnapshotLoaded || !dashboardReady || loading) {
    return { active: false, intervalMs: null };
  }

  return {
    active: true,
    intervalMs: sanitizeQuotaRefreshIntervalMs(intervalMs),
  };
}
