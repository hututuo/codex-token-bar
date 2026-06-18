export interface CodexHomeStatus {
  path: string;
  exists: boolean;
  source: string;
}

export interface PlatformCapabilities {
  platform: string;
  shell: string;
  floatingWindow: PlatformFeatureCapability;
  floatingTransparency: PlatformFeatureCapability;
  floatingDrag: PlatformFeatureCapability;
  floatingLock: PlatformFeatureCapability;
  statusTray: PlatformFeatureCapability;
  statusTrayLiveText: PlatformFeatureCapability;
  autostart: PlatformFeatureCapability;
  notifications: PlatformFeatureCapability;
}

export interface PlatformFeatureCapability {
  available: boolean;
  status: "ready" | "pending" | "unavailable" | string;
  label: string;
  note: string;
}

export interface FloatingWindowSettings {
  opacity: number;
  scale: number;
  unreadEffect: FloatingUnreadEffect;
}

export type FloatingUnreadEffect = "off" | "ripple" | "shimmer";

export interface AppSettingsSnapshot {
  codexHome: string | null;
  floatingWindow: FloatingWindowSettings;
  floatingPosition: FloatingWindowPosition | null;
  displaySurfaces: DisplaySurfaceSettings;
  setupGuideCompleted: boolean;
}

export interface FloatingWindowPosition {
  x: number;
  y: number;
  savedAt?: number | null;
}

export interface DisplaySurfaceSettings {
  floatingWindowEnabled: boolean;
  statusTrayLiveTextEnabled: boolean;
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
  resetsAtUnix?: number | null;
}

export interface QuotaHistoryPoint {
  label: string;
  fiveHourRemainingPercent: number | null;
  sevenDayRemainingPercent: number | null;
}

export interface ResetCreditSummary {
  availableCount: number;
  status: string;
  credits: ResetCreditDetail[];
}

export interface ResetCreditDetail {
  title: string;
  status: string;
  summary: string;
  issuedAt: string;
  expiresAt: string;
  redeemedAt: string;
  source: string;
  associatedUser: string;
  shortId: string;
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
  fiveHourRemainingPercent: number | null;
  sevenDayRemainingPercent: number | null;
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

export interface LocalDataWarning {
  source: string;
  message: string;
}

export interface DashboardSnapshot {
  generatedAt: string;
  account: AccountInfo;
  stats: DashboardStats;
  quota: QuotaSnapshot;
  activityDays: ActivityDay[];
  recentUsage24h: RecentUsagePoint[];
  cacheHitRanking: CacheHitRankingItem[];
  warnings: LocalDataWarning[];
}

export interface AccountQuotaBundle {
  account: AccountInfo;
  quota: QuotaSnapshot;
  quotaHistory24h: QuotaHistoryPoint[];
  warnings: LocalDataWarning[];
}

export interface LiveRateSnapshot {
  scopeLabel: string;
  threadTitle: string;
  selectedThreadId: string | null;
  selectedThreadTitle: string;
  selectedTokensPerSecond: number;
  tokensPerSecond: number;
  totalTokensToday: number;
  requestsToday: number;
  maxTokensPerSecond: number;
  preciseEnabled: boolean;
  warnings: LocalDataWarning[];
}

export interface LiveThreadOption {
  id: string;
  title: string;
  subtitle: string;
  updatedAt: string;
  tokensUsed: number;
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
  providerSource: string;
  sessionFilesFound: number;
  inconsistentCount: number;
  status: string;
  steps: ProviderRepairStep[];
}

export interface ProviderRepairBackupInfo {
  id: string;
  createdAt: string;
  path: string;
  codexHome: string;
  codexHomeFingerprint: string;
  targetProvider: string;
  sessionFiles: number;
  stateDatabase: boolean;
  sessionIndex: boolean;
}

export interface ProviderRepairActionResult {
  snapshot: ProviderRepairSnapshot;
  message: string;
  backup: ProviderRepairBackupInfo | null;
  backups: ProviderRepairBackupInfo[];
}
