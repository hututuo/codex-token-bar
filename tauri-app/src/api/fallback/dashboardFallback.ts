import type { DashboardSnapshot } from "../../types/usage";
import { emptyQuotaSnapshot } from "./quotaFallback";
import { emptyActivityDays, emptyRecentUsage } from "./timeSeriesFallback";

export function emptyDashboardSnapshot(): DashboardSnapshot {
  const now = new Date();
  return {
    generatedAt: now.toISOString(),
    homeIdentity: null,
    usageRevision: null,
    coverageKind: null,
    observedThrough: null,
    settledThrough: null,
    exactGeneration: null,
    dashboardRevision: null,
    aggregateBoundaryUnix: null,
    usageSummaryUpdatedAt: null,
    usageSummaryCheckedAt: null,
    usageSummaryDataUpdatedAt: null,
    usageSummary: null,
    usageSummaryFresh: false,
    preciseRecentUsageCoveredAt: null,
    preciseRecentUsageFresh: false,
    preciseObserverEpoch: null,
    preciseObserverStartedAtUnixMicros: null,
    preciseObserverSequence: null,
    preciseAttributionProvenanceEpoch: null,
    preciseAttributionGeneration: null,
    preciseAttributionUnsafeSinceGeneration: null,
    preciseAttributionUnsafeId: null,
    preciseAttributionCurrentScanUnsafe: false,
    quotaUpdatedAt: null,
    attributionIdentity: null,
    account: {
      displayName: "账户待读取",
      planLabel: "计划待读取",
    },
    stats: {
      totalTokens: 0,
      peakDayTokens: 0,
      peakThreadTokens: 0,
      currentStreakDays: 0,
      longestStreakDays: 0,
      totalCalls: 0,
      totalThreads: 0,
    },
    quota: emptyQuotaSnapshot(),
    activityDays: emptyActivityDays(now),
    recentUsage24h: emptyRecentUsage(now),
    recentUsage7d: emptyRecentUsage(now, 60 * 60 * 1_000, 30 * 24),
    recentUsage30d: emptyRecentUsage(now, 6 * 60 * 60 * 1_000, 30 * 4),
    cacheHitRanking: [],
    cacheUsage: {
      sessions: [],
      turns: [],
    },
    warnings: [],
    diagnostics: [],
  };
}
