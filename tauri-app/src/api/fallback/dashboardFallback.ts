import type { DashboardSnapshot } from "../../types/usage";
import { emptyQuotaSnapshot } from "./quotaFallback";
import { emptyActivityDays, emptyRecentUsage } from "./timeSeriesFallback";

export function emptyDashboardSnapshot(): DashboardSnapshot {
  const now = new Date();
  return {
    generatedAt: now.toISOString(),
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
    cacheHitRanking: [],
    warnings: [],
  };
}
