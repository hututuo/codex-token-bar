import { emptyAccountQuotaBundle } from "../api/fallback";
import type { DashboardAppState } from "./dashboardState";

/** Clear account-derived fields only; preserve the entire local token ledger. */
export function clearAccountQuota(state: DashboardAppState): DashboardAppState {
  if (!state.dashboard) return state;
  const empty = emptyAccountQuotaBundle();
  const clear = <T extends object>(point: T) => ({ ...point, fiveHourRemainingPercent: null,
    sevenDayRemainingPercent: null, fiveHourCycleId: null, sevenDayCycleId: null });
  return { ...state, dashboard: { ...state.dashboard, quota: empty.quota,
    quotaUpdatedAt: empty.updatedAt, attributionIdentity: null,
    activityDays: state.dashboard.activityDays.map(clear),
    recentUsage24h: state.dashboard.recentUsage24h.map(clear),
    recentUsage7d: state.dashboard.recentUsage7d.map(clear),
    recentUsage30d: state.dashboard.recentUsage30d.map(clear),
    warnings: state.dashboard.warnings.filter(w => !["account_quota", "reset_credit", "quota_history"].includes(w.source)),
    diagnostics: (state.dashboard.diagnostics ?? []).filter(d => !["account_quota", "reset_credit", "quota_history"].includes(d.source)),
  } };
}
