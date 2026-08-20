import type { LocalDataWarning, QuotaDiagnostic } from "./diagnostics";
import type { AccountInfo, QuotaAttributionIdentity, QuotaSnapshot } from "./quota";

/**
 * Stable, non-sensitive labels for the events that can request an exact
 * dashboard refresh. These labels are also used in native performance trace
 * entries; keep them closed so paths or user content can never leak into the
 * trace.
 */
export type PreciseDashboardRefreshReason =
  | "cadence"
  | "source-change"
  | "quota"
  | "catch-up"
  | "attribution"
  | "manual"
  | "wake"
  | "retry"
  | "unknown";

export type PreciseDashboardDedupeDomain =
  | "aggregate-boundary"
  | "attribution-boundary"
  | "wake";

export type PreciseDashboardRequestRevision = string | number;

/**
 * Small, transport-safe lineage attached to numeric dashboard payloads.
 *
 * These fields are deliberately independent from `generatedAt`: the native
 * owner can publish an open/observed bucket after a settled aggregate has
 * already been materialised, and wall-clock publication time is not a source
 * freshness proof.
 */
export type DashboardLineageScalar = number | string | null;

export type DashboardCoverageKind = "summary" | "settled" | "full";

export interface DashboardPayloadLineage {
  homeIdentity?: string | null;
  usageRevision?: DashboardLineageScalar;
  coverageKind?: DashboardCoverageKind | null;
  observedThrough?: string | null;
  settledThrough?: string | null;
  exactGeneration?: DashboardLineageScalar;
}

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
  /** Optional event/bucket start in Unix seconds for time-versioned pricing. */
  eventStartUnix?: number;
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

export interface DashboardSnapshot extends DashboardPayloadLineage {
  generatedAt: string;
  /** Compatibility aliases emitted by older exact-index owners. */
  dashboardRevision?: DashboardLineageScalar;
  aggregateBoundaryUnix?: DashboardLineageScalar;
  /** Frontend publication time of the latest lightweight numeric summary. */
  usageSummaryUpdatedAt?: string | null;
  /** Process-local successful check time for the lightweight summary lane. */
  usageSummaryCheckedAt?: string | null;
  /** Newest source-file modification represented by the lightweight summary. */
  usageSummaryDataUpdatedAt?: string | null;
  /** Latest lightweight totals; deliberately separate from chart buckets. */
  usageSummary?: UsageSummarySnapshot | null;
  /**
   * Whether the latest lightweight summary owner has published successfully.
   * This is intentionally independent from `preciseRecentUsageFresh`, which
   * only describes the five-minute chart/aggregate coverage.
   */
  usageSummaryFresh?: boolean;
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

export type PreciseDashboardSourceProbeState = "unchanged" | "changed" | "unknown";

export interface PreciseDashboardSourceProbe {
  state: PreciseDashboardSourceProbeState;
  publishedGeneration: string;
}

export type PreciseDashboardProgressPhase =
  | "idle"
  | "waiting"
  | "preparing"
  | "migrating"
  | "scanning"
  | "backfillingModel"
  | "publishing"
  | "complete"
  | "failed";

export interface PreciseDashboardProgress {
  phase: PreciseDashboardProgressPhase | string;
  message: string;
  completed: number;
  total: number | null;
  fraction: number | null;
  startedAt: string;
  updatedAt: string;
}

export interface UsageSummarySnapshot {
  /** Minimal source identity and freshness lineage for the summary lane. */
  homeIdentity?: string | null;
  usageRevision?: DashboardLineageScalar;
  coverageKind?: DashboardCoverageKind | null;
  observedThrough?: string | null;
  settledThrough?: string | null;
  exactGeneration?: DashboardLineageScalar;
  totalTokens: number;
  todayTokens: number;
  todayRequests: number;
  todayModelBreakdowns?: ModelTokenBreakdown[];
  /** V19 summary names retained for old Rust payloads. */
  dashboardRevision?: DashboardLineageScalar;
  aggregateBoundaryUnix?: DashboardLineageScalar;
  generatedAt?: string;
  checkedAt?: string | null;
  dataUpdatedAt?: string | null;
}
