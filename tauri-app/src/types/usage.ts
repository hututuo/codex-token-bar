import type { LocalDataWarning } from "./diagnostics";
import type { AccountInfo, QuotaSnapshot } from "./quota";

export interface DashboardStats {
  totalTokens: number;
  peakDayTokens: number;
  peakThreadTokens: number;
  currentStreakDays: number;
  longestStreakDays: number;
  totalCalls: number;
  totalThreads: number;
}

export interface ActivityDay {
  date: string;
  tokens: number;
  calls: number;
  cacheHitRate: number;
  fiveHourRemainingPercent: number | null;
  sevenDayRemainingPercent: number | null;
}

export interface RecentUsagePoint {
  label: string;
  startUnix: number;
  tokens: number;
  calls: number;
  inputTokens: number;
  cachedInputTokens: number;
  outputTokens: number;
  cacheHitRate: number | null;
  fiveHourRemainingPercent: number | null;
  sevenDayRemainingPercent: number | null;
}

export interface CacheHitRankingItem {
  rank: number;
  title: string;
  subtitle: string;
  hitRate: number;
  inputTokens: number;
  cachedTokens: number;
}

export interface TokenCacheBreakdown {
  inputTokens: number;
  cachedInputTokens: number;
  outputTokens: number;
  totalTokens: number;
  calls: number;
}

export interface SessionCacheUsage {
  id: string;
  title: string;
  lastUpdated: string | null;
  breakdown: TokenCacheBreakdown;
}

export interface TurnCacheUsage {
  id: string;
  sessionId: string;
  sessionTitle: string;
  timestamp: string;
  turnIndexInSession: number;
  userPrompt: string;
  assistantResponse: string;
  breakdown: TokenCacheBreakdown;
}

export interface TokenCacheUsage {
  sessions: SessionCacheUsage[];
  turns: TurnCacheUsage[];
}

export interface DashboardSnapshot {
  generatedAt: string;
  account: AccountInfo;
  stats: DashboardStats;
  quota: QuotaSnapshot;
  activityDays: ActivityDay[];
  recentUsage24h: RecentUsagePoint[];
  recentUsage7d: RecentUsagePoint[];
  recentUsage30d: RecentUsagePoint[];
  cacheHitRanking: CacheHitRankingItem[];
  cacheUsage: TokenCacheUsage;
  warnings: LocalDataWarning[];
}
