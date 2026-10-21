import type { LocalDataWarning } from "./diagnostics";
import type { CodexHomeSourceToken } from "./platform";
import type { ModelTokenBreakdown } from "./usage";

export interface CacheUsageAdvice {
  threadId: string;
  threadTitle?: string | null;
  hitRate: number;
  affectedThreads?: number;
  low: boolean;
  timestamp: number;
  idleGapSeconds?: number | null;
  model?: string | null;
}

export interface LiveRateSnapshot {
  speedSamples?: SpeedSample[];
  modelSpeeds?: ModelSpeedSummary[];
  modelSpeeds15m?: ModelSpeedSummary[];
  modelSpeeds30m?: ModelSpeedSummary[];
  measurementStatus?: string;
  cacheAdvice?: CacheUsageAdvice | null;
  scopeLabel: string;
  threadTitle: string;
  selectedThreadId: string | null;
  selectedThreadTitle: string;
  selectedTokensPerSecond: number;
  tokensPerSecond: number;
  totalTokens: number;
  totalTokensToday: number;
  requestsToday: number;
  maxTokensPerSecond: number;
  preciseEnabled: boolean;
  unreadSummary: UnreadSummary;
  warnings: LocalDataWarning[];
}

export interface LiveThreadOption {
  id: string;
  title: string;
  subtitle: string;
  updatedAt: string;
  tokensUsed: number;
}

export interface LiveRateStreamLease {
  leaseId: string;
  registered: boolean;
}

export interface FloatingPanelSnapshot {
  speedSamples?: SpeedSample[];
  modelSpeeds?: ModelSpeedSummary[];
  modelSpeeds15m?: ModelSpeedSummary[];
  modelSpeeds30m?: ModelSpeedSummary[];
  measurementStatus?: string;
  cacheAdvice?: CacheUsageAdvice | null;
  tokensPerSecond: number;
  maxTokensPerSecond: number;
  liveRateAvailable?: boolean;
  trendLabel: string;
  liveRateStatusKind?: "failure" | "pending";
  liveRateStatusLabel?: string;
  resetCreditLabel: string;
  resetCreditRateBarLabel?: string;
  resetCreditStandaloneLabel?: string;
  totalTokensLabel: string;
  todayTokensLabel: string;
  requestsLabel: string;
  todayModelBreakdowns: ModelTokenBreakdown[];
  fiveHourLabel: string;
  fiveHourAvailability: "measured" | "unavailable" | "absent";
  fiveHourRemainingPercent: number | null;
  /** Even-pace reference in percentage points (0–100), not the remaining ratio. */
  fiveHourExpectedRemainingPercent: number | null;
  sevenDayLabel: string;
  sevenDayAvailability: "measured" | "unavailable" | "absent";
  sevenDayRemainingPercent: number | null;
  /** Even-pace reference in percentage points (0–100), not the remaining ratio. */
  sevenDayExpectedRemainingPercent: number | null;
  /** The displayed quota is last-good data after a prolonged read failure. */
  quotaDataStale?: boolean;
  unread: boolean;
  unreadSummary: UnreadSummary;
}

export interface UnreadSummary {
  active: boolean;
  count: number;
  label: string;
  detail: string;
  source: string;
}

export interface UnreadSummaryChangedPayload {
  sourceToken: CodexHomeSourceToken;
  summary: UnreadSummary;
}

export interface SpeedSample {
  id: string;
  threadId: string;
  turnId: string;
  itemId: string;
  model: string | null;
  startedAt: number;
  endedAt: number;
  outputTokens: number;
  outputCharacters: number;
  outputBytes: number;
  chunkCount: number;
  durationSeconds: number;
  tokensPerSecond: number;
  confidence: string;
  networkWarning?: string | boolean | null;
  source: string;
  measurementKind?: string | null;
  tokenizer?: string | null;
}
export interface ModelSpeedSummary {
  model: string;
  tokensPerSecond: number;
  sampleCount: number;
  outputTokens: number;
  durationSeconds: number;
  activeSampleCount?: number;
  qualifiedSampleCount?: number;
  confidence?: string;
}
