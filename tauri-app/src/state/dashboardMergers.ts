import type {
  AccountQuotaBundle,
  ActivityDay,
  DashboardSnapshot,
  LiveRateSnapshot,
  LiveThreadOption,
  QuotaHistoryDailyPoint,
  QuotaHistoryPoint,
  RecentUsagePoint,
} from "../types/dashboard";
import type { DashboardAppState } from "./dashboardState";
import {
  mergeQuotaDiagnostics,
  mergeWarnings,
  replaceQuotaDiagnostics,
  replaceQuotaWarnings,
} from "./dashboardWarnings";

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
            activityDays: mergeActivityQuotaHistory(precise.activityDays, state.dashboard.activityDays),
            recentUsage24h: mergeQuotaHistory(precise.recentUsage24h, state.dashboard.recentUsage24h),
            recentUsage7d: mergeQuotaHistory(precise.recentUsage7d, state.dashboard.recentUsage7d),
            recentUsage30d: mergeQuotaHistory(precise.recentUsage30d, state.dashboard.recentUsage30d),
            warnings: mergeWarnings(state.dashboard.warnings, precise.warnings),
            diagnostics: mergeQuotaDiagnostics(state.dashboard.diagnostics ?? [], precise.diagnostics ?? []),
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
          activityDays: mergeActivityQuotaHistory(state.dashboard.activityDays, quota.quotaHistoryDaily),
          recentUsage24h: mergeQuotaHistory(state.dashboard.recentUsage24h, quota.quotaHistory24h),
          recentUsage7d: mergeQuotaHistory(state.dashboard.recentUsage7d, quota.quotaHistory7d),
          recentUsage30d: mergeQuotaHistory(state.dashboard.recentUsage30d, quota.quotaHistory30d),
          warnings: replaceQuotaWarnings(state.dashboard.warnings, quota.warnings),
          diagnostics: replaceQuotaDiagnostics(state.dashboard.diagnostics ?? [], quota.diagnostics ?? []),
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

function mergeActivityQuotaHistory(
  days: ActivityDay[],
  historyDays: Array<QuotaHistoryDailyPoint | ActivityDay>,
): ActivityDay[] {
  if (historyDays.length === 0) {
    return days;
  }

  const historyByDate = new Map(historyDays.map((day) => [day.date, day]));
  return days.map((day) => {
    const history = historyByDate.get(day.date);
    if (history === undefined) {
      return day;
    }
    return {
      ...day,
      fiveHourRemainingPercent: history.fiveHourRemainingPercent,
      sevenDayRemainingPercent: history.sevenDayRemainingPercent,
    };
  });
}

function mergeQuotaHistory(points: RecentUsagePoint[], historyPoints: QuotaHistoryPoint[]): RecentUsagePoint[] {
  if (historyPoints.length === 0) {
    return points;
  }

  const historyByStart = new Map(historyPoints.map((point) => [point.startUnix, point]));
  return points.map((point) => {
    const history = historyByStart.get(point.startUnix);
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
