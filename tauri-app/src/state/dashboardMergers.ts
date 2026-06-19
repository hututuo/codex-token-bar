import type {
  AccountQuotaBundle,
  DashboardSnapshot,
  LiveRateSnapshot,
  LiveThreadOption,
  RecentUsagePoint,
} from "../types/dashboard";
import type { DashboardAppState } from "./dashboardState";
import { mergeWarnings } from "./dashboardWarnings";

export function mergePreciseDashboard(
  state: DashboardAppState,
  precise: DashboardSnapshot,
): DashboardAppState {
  return {
    ...state,
    dashboard:
      state.dashboard === null
        ? precise
        : {
            ...precise,
            account: state.dashboard.account,
            quota: state.dashboard.quota,
            warnings: mergeWarnings(state.dashboard.warnings, precise.warnings),
          },
  };
}

export function mergeQuota(state: DashboardAppState, quota: AccountQuotaBundle): DashboardAppState {
  const dashboard =
    state.dashboard === null
      ? null
      : {
          ...state.dashboard,
          account: quota.account,
          quota: quota.quota,
          recentUsage24h: mergeQuotaHistory(state.dashboard.recentUsage24h, quota),
          warnings: mergeWarnings(state.dashboard.warnings, quota.warnings),
        };
  return {
    ...state,
    dashboard,
  };
}

export function mergeLiveRate(
  state: DashboardAppState,
  liveRate: LiveRateSnapshot,
): DashboardAppState {
  return {
    ...state,
    liveRate,
  };
}

export function mergeLiveThreadOptions(
  state: DashboardAppState,
  liveThreadOptions: LiveThreadOption[],
): DashboardAppState {
  return {
    ...state,
    liveThreadOptions,
  };
}

function mergeQuotaHistory(points: RecentUsagePoint[], quota: AccountQuotaBundle): RecentUsagePoint[] {
  if (quota.quotaHistory24h.length === 0) {
    return points;
  }

  return points.map((point, index) => {
    const history = quota.quotaHistory24h[index];
    if (history === undefined) {
      return point;
    }
    return {
      ...point,
      fiveHourRemainingPercent: history.fiveHourRemainingPercent,
      sevenDayRemainingPercent: history.sevenDayRemainingPercent,
    };
  });
}
