import type { LocalDataWarning, QuotaDiagnostic } from "./diagnostics";
import type { AccountInfo, QuotaAttributionIdentity, QuotaSnapshot } from "./quota";

export interface DashboardStats {
  totalTokens: number;
  peakDayTokens: number;
  peakThreadTokens: number;
  currentStreakDays: number;
  longestStreakDays: number;
  totalCalls: number;
  totalThreads: number;
  totalInputTokens?: number;
  totalCachedInputTokens?: number;
  totalOutputTokens?: number;
  modelBreakdowns?: ModelTokenBreakdown[];
  firstUsageAt?: string | null;
}

export interface ActivityDay {
  date: string;
  tokens: number;
  calls: number;
  modelBreakdowns?: ModelTokenBreakdown[];
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
  modelBreakdowns?: ModelTokenBreakdown[];
  cacheHitRate: number | null;
  fiveHourRemainingPercent: number | null;
  sevenDayRemainingPercent: number | null;
  /** Opaque stable session/event-source contributions for monotonic archival merge. */
  sourceContributions?: RecentUsageSourceContribution[];
  /** Rotates whenever the native exact index can no longer prove append-only lineage. */
  sourceContributionEpoch?: string | null;
}

export interface RecentUsageSourceContribution {
  sourceId: string;
  tokens: number;
  calls: number;
  inputTokens: number;
  cachedInputTokens: number;
  outputTokens: number;
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

export interface ModelTokenBreakdown {
  model: string | null;
  breakdown: TokenCacheBreakdown;
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
  /** Last native full exact-usage sync that covers the five-minute series. */
  preciseRecentUsageCoveredAt?: string | null;
  /** False for compact startup data, metadata-only data, and failed refreshes. */
  preciseRecentUsageFresh?: boolean;
  /** Stable for one native process; changes after an app restart/observer gap. */
  preciseObserverEpoch?: string | null;
  preciseObserverStartedAtUnixMicros?: number | null;
  preciseObserverSequence?: number | null;
  preciseAttributionProvenanceEpoch?: string | null;
  preciseAttributionGeneration?: number | null;
  preciseAttributionUnsafeSinceGeneration?: number | null;
  preciseAttributionUnsafeId?: string | null;
  preciseAttributionCurrentScanUnsafe?: boolean;
  quotaUpdatedAt?: string | null;
  attributionIdentity?: QuotaAttributionIdentity | null;
  account: AccountInfo;
  stats: DashboardStats;
  quota: QuotaSnapshot;
  activityDays: ActivityDay[];
  /** Compatibility name: this is the 30-day, five-minute long recent canvas. */
  recentUsage24h: RecentUsagePoint[];
  recentUsage7d: RecentUsagePoint[];
  recentUsage30d: RecentUsagePoint[];
  cacheHitRanking: CacheHitRankingItem[];
  cacheUsage: TokenCacheUsage;
  warnings: LocalDataWarning[];
  diagnostics: QuotaDiagnostic[];
}

export interface UsageCacheStatus {
  namespace: string;
  initialized: boolean;
  initializedAt: string | null;
}

export interface UsageSummarySnapshot {
  totalTokens: number;
  todayTokens: number;
  todayRequests: number;
}
