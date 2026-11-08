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

  // Native API-mode reads only recheck local connection facts and return an
  // inapplicable snapshot. Keep this tick to discover a switch to subscription.
  return {
    active: true,
    intervalMs: sanitizeQuotaRefreshIntervalMs(intervalMs),
  };
}
