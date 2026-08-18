import type {
  AccountQuotaBundle,
  ActivityDay,
  DashboardSnapshot,
  LiveRateSnapshot,
  LiveThreadOption,
  QuotaHistoryDailyPoint,
  QuotaHistoryPoint,
  RecentUsagePoint,
  UsageSummarySnapshot,
} from "../types/dashboard";
import type { ResetCreditBundle } from "../types/quota";
import type { DashboardAppState } from "./dashboardState";
import {
  mergeQuotaDiagnostics,
  mergeWarnings,
  removeUsagePrecisionWarnings,
  replaceAccountQuotaDiagnostics,
  replaceAccountQuotaWarnings,
  replaceResetCreditDiagnostics,
  replaceResetCreditWarnings,
} from "./dashboardWarnings";

export function mergePreciseDashboard(
  state: DashboardAppState,
  precise: DashboardSnapshot,
): DashboardAppState {
  const previous = state.dashboard;
  const incomingCoverageAt = precise.preciseRecentUsageCoveredAt ?? null;
  const incomingCoverageIsTrusted = precise.preciseRecentUsageFresh === true
    && incomingCoverageAt !== null
    && Number.isFinite(Date.parse(incomingCoverageAt));
  const previousCoverageAt = previous?.preciseRecentUsageCoveredAt ?? null;
  const previousCoverageIsTrusted = previousCoverageAt !== null
    && Number.isFinite(Date.parse(previousCoverageAt));
  if (previous !== null && previousCoverageIsTrusted && !incomingCoverageIsTrusted) {
    // A failed/incomplete owner result is a status update, not a new usage
    // truth. Keep the last materialized canvas intact so a long exact scan
    // cannot replace real values with the zero/"待读取" placeholder snapshot.
    // The stale bit and diagnostics still make the incomplete read visible.
    return {
      ...state,
      dashboard: {
        ...previous,
        preciseRecentUsageFresh: false,
        preciseAttributionCurrentScanUnsafe: previous.preciseAttributionCurrentScanUnsafe
          || precise.preciseAttributionCurrentScanUnsafe,
        warnings: mergeWarnings(
          removeUsagePrecisionWarnings(previous.warnings),
          precise.warnings,
        ),
        diagnostics: mergeQuotaDiagnostics(
          previous.diagnostics ?? [],
          precise.diagnostics ?? [],
        ),
      },
    };
  }
  const previousSummaryTime = previous?.usageSummary?.generatedAt
    ? Date.parse(previous.usageSummary.generatedAt)
    : Number.NaN;
  const preciseTime = Date.parse(precise.generatedAt);
  const keepNewerLightSummary = previous?.usageSummary !== null
    && previous?.usageSummary !== undefined
    && Number.isFinite(previousSummaryTime)
    && Number.isFinite(preciseTime)
    && previousSummaryTime > preciseTime;
  const retainedLightSummary = keepNewerLightSummary ? previous?.usageSummary ?? null : null;
  return {
    ...state,
    dashboard:
      previous === null
        ? precise
        : {
            ...precise,
            usageSummary: retainedLightSummary,
            usageSummaryUpdatedAt: retainedLightSummary?.generatedAt
              ?? precise.usageSummaryUpdatedAt
              ?? precise.generatedAt,
            usageSummaryFresh: retainedLightSummary !== null
              ? previous?.usageSummaryFresh !== false
              : false,
            stats: retainedLightSummary === null
              ? precise.stats
              : {
                  ...precise.stats,
                  totalTokens: Math.max(0, retainedLightSummary.totalTokens),
                },
            // An incomplete scan intentionally publishes no new coverage
            // watermark. Keep the previous trusted watermark so the UI can
            // continue showing last-good data with a stale indicator instead
            // of falling back to the all-zero startup canvas.
            preciseRecentUsageCoveredAt: incomingCoverageIsTrusted
              ? incomingCoverageAt
              : previous.preciseRecentUsageCoveredAt ?? null,
            preciseRecentUsageFresh: incomingCoverageIsTrusted,
            preciseObserverEpoch: incomingCoverageIsTrusted
              ? precise.preciseObserverEpoch
              : previous.preciseObserverEpoch ?? null,
            preciseObserverStartedAtUnixMicros: incomingCoverageIsTrusted
              ? precise.preciseObserverStartedAtUnixMicros
              : previous.preciseObserverStartedAtUnixMicros ?? null,
            preciseObserverSequence: incomingCoverageIsTrusted
              ? precise.preciseObserverSequence
              : previous.preciseObserverSequence ?? null,
            preciseAttributionProvenanceEpoch: incomingCoverageIsTrusted
              ? precise.preciseAttributionProvenanceEpoch
              : previous.preciseAttributionProvenanceEpoch ?? null,
            preciseAttributionGeneration: incomingCoverageIsTrusted
              ? precise.preciseAttributionGeneration
              : previous.preciseAttributionGeneration ?? null,
            preciseAttributionUnsafeSinceGeneration: incomingCoverageIsTrusted
              ? precise.preciseAttributionUnsafeSinceGeneration
              : previous.preciseAttributionUnsafeSinceGeneration ?? null,
            preciseAttributionUnsafeId: incomingCoverageIsTrusted
              ? precise.preciseAttributionUnsafeId
              : previous.preciseAttributionUnsafeId ?? null,
            preciseAttributionCurrentScanUnsafe: incomingCoverageIsTrusted
              ? precise.preciseAttributionCurrentScanUnsafe
              : true,
            quotaUpdatedAt: previous.quotaUpdatedAt ?? null,
            attributionIdentity: previous.attributionIdentity ?? null,
            account: previous.account,
            quota: previous.quota,
            activityDays: mergeActivityQuotaHistory(precise.activityDays, previous.activityDays),
            recentUsage24h: mergeQuotaHistory(precise.recentUsage24h, previous.recentUsage24h),
            recentUsage7d: mergeQuotaHistory(precise.recentUsage7d, previous.recentUsage7d),
            recentUsage30d: mergeQuotaHistory(precise.recentUsage30d, previous.recentUsage30d),
            warnings: mergeWarnings(removeUsagePrecisionWarnings(previous.warnings), precise.warnings),
            diagnostics: mergeQuotaDiagnostics(previous.diagnostics ?? [], precise.diagnostics ?? []),
          },
  };
}

/**
 * Apply the lightweight exact-index summary without touching charts,
 * rankings, quota history, or the last settled aggregate watermark.
 */
export function mergeUsageSummary(
  state: DashboardAppState,
  summary: UsageSummarySnapshot,
  generatedAt = summary.generatedAt ?? new Date().toISOString(),
): DashboardAppState {
  const dashboard = state.dashboard;
  if (dashboard === null) return state;
  const incomingTime = Date.parse(generatedAt);
  const previousSummaryTime = Date.parse(
    dashboard.usageSummaryUpdatedAt ?? dashboard.usageSummary?.generatedAt ?? "",
  );
  // This lane has its own clock. A cache summary may legitimately predate a
  // newer five-minute dashboard snapshot; comparing against dashboard.generatedAt
  // would discard the only trusted model rows and leave today's card pending.
  if (Number.isFinite(incomingTime)
    && Number.isFinite(previousSummaryTime)
    && incomingTime < previousSummaryTime) return state;

  return {
    ...state,
    dashboard: {
      ...dashboard,
      usageSummaryUpdatedAt: generatedAt,
      usageSummary: {
        ...summary,
        generatedAt,
      },
      usageSummaryFresh: true,
      stats: {
        ...dashboard.stats,
        totalTokens: Math.max(0, summary.totalTokens),
      },
    },
  };
}

/**
 * Mark only the lightweight summary as in flight. Chart buckets and their
 * precise coverage remain untouched; the model card can keep showing the last
 * trusted rows with its own stale state while the compact owner retries.
 */
export function markUsageSummaryStale(state: DashboardAppState): DashboardAppState {
  if (state.dashboard === null || state.dashboard.usageSummaryFresh === false) {
    return state;
  }
  return {
    ...state,
    dashboard: {
      ...state.dashboard,
      usageSummaryFresh: false,
    },
  };
}

export function markPreciseRecentUsageStale(state: DashboardAppState): DashboardAppState {
  if (state.dashboard === null || state.dashboard.preciseRecentUsageFresh === false) {
    return state;
  }
  return {
    ...state,
    dashboard: {
      ...state.dashboard,
      preciseRecentUsageFresh: false,
    },
  };
}

/**
 * The native safety acknowledgement only removes an already-reviewed
 * attribution episode marker. It does not change token usage or quota data,
 * so the UI can clear the marker locally and wait for the next scheduled
 * source probe instead of forcing a second full exact scan immediately.
 */
export function clearPreciseAttributionSafety(
  state: DashboardAppState,
): DashboardAppState {
  const dashboard = state.dashboard;
  if (dashboard === null
    || (dashboard.preciseAttributionUnsafeSinceGeneration == null
      && dashboard.preciseAttributionUnsafeId == null
      && dashboard.preciseAttributionCurrentScanUnsafe !== true)) {
    return state;
  }
  return {
    ...state,
    dashboard: {
      ...dashboard,
      preciseAttributionUnsafeSinceGeneration: null,
      preciseAttributionUnsafeId: null,
      preciseAttributionCurrentScanUnsafe: false,
    },
  };
}

export function mergeQuota(state: DashboardAppState, quota: AccountQuotaBundle): DashboardAppState {
  const dashboard =
    state.dashboard === null
      ? null
      : {
          ...state.dashboard,
          quotaUpdatedAt: quota.updatedAt,
          attributionIdentity: quota.attributionIdentity ?? null,
          account: quota.account,
          quota: {
            ...quota.quota,
            resetCredit: state.dashboard.quota.resetCredit,
          },
          activityDays: mergeActivityQuotaHistory(state.dashboard.activityDays, quota.quotaHistoryDaily),
          recentUsage24h: mergeQuotaHistory(state.dashboard.recentUsage24h, quota.quotaHistory24h),
          recentUsage7d: mergeQuotaHistory(state.dashboard.recentUsage7d, quota.quotaHistory7d),
          recentUsage30d: mergeQuotaHistory(state.dashboard.recentUsage30d, quota.quotaHistory30d),
          warnings: replaceAccountQuotaWarnings(state.dashboard.warnings, quota.warnings),
          diagnostics: replaceAccountQuotaDiagnostics(
            state.dashboard.diagnostics ?? [],
            quota.diagnostics ?? [],
          ),
        };
  return {
    ...state,
    dashboard,
  };
}

export function mergeResetCredits(
  state: DashboardAppState,
  reset: ResetCreditBundle,
): DashboardAppState {
  if (state.dashboard === null) {
    return state;
  }
  const previous = state.dashboard.quota.resetCredit;
  const resetCredit = reset.successful
    ? { ...reset.resetCredit, updatedAt: reset.updatedAt }
    : {
        ...previous,
        status: reset.resetCredit.status,
        updatedAt: previous.updatedAt ?? null,
      };
  return {
    ...state,
    dashboard: {
      ...state.dashboard,
      quota: {
        ...state.dashboard.quota,
        resetCredit,
      },
      warnings: replaceResetCreditWarnings(state.dashboard.warnings, reset.warnings),
      diagnostics: replaceResetCreditDiagnostics(
        state.dashboard.diagnostics ?? [],
        reset.diagnostics ?? [],
      ),
    },
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
