export interface CodexHomeStatus {
  path: string;
  exists: boolean;
  source: string;
}

export interface AccountInfo {
  displayName: string;
  planLabel: string;
}

export interface DashboardStats {
  totalTokens: number;
  peakDayTokens: number;
  peakThreadTokens: number;
  currentStreakDays: number;
  longestStreakDays: number;
  totalCalls: number;
  totalThreads: number;
}

export interface QuotaLimit {
  label: string;
  remainingPercent: number;
  usedPercent: number;
  resetsAt: string;
}

export interface ResetCreditSummary {
  availableCount: number;
  status: string;
}

export interface QuotaSnapshot {
  fiveHour: QuotaLimit;
  sevenDay: QuotaLimit;
  resetCredit: ResetCreditSummary;
  paceLabel: string;
}

export interface ActivityDay {
  date: string;
  tokens: number;
  calls: number;
  cacheHitRate: number;
}

export interface RecentUsagePoint {
  label: string;
  tokens: number;
  calls: number;
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

export interface DashboardSnapshot {
  generatedAt: string;
  account: AccountInfo;
  stats: DashboardStats;
  quota: QuotaSnapshot;
  activityDays: ActivityDay[];
  recentUsage24h: RecentUsagePoint[];
  cacheHitRanking: CacheHitRankingItem[];
}

export interface LiveRateSnapshot {
  scopeLabel: string;
  threadTitle: string;
  tokensPerSecond: number;
  totalTokensToday: number;
  requestsToday: number;
  maxTokensPerSecond: number;
  preciseEnabled: boolean;
}

export interface FloatingPanelSnapshot {
  tokensPerSecond: number;
  trendLabel: string;
  totalTokensLabel: string;
  todayTokensLabel: string;
  requestsLabel: string;
  fiveHourLabel: string;
  sevenDayLabel: string;
  unread: boolean;
}

export interface ProviderRepairStep {
  label: string;
  status: string;
  done: boolean;
  healthy: boolean;
}

export interface ProviderRepairSnapshot {
  detectedProvider: string;
  sessionFilesFound: number;
  inconsistentCount: number;
  steps: ProviderRepairStep[];
}
