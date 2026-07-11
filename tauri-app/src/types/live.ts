import type { LocalDataWarning } from "./diagnostics";
import type { CodexHomeSourceToken } from "./platform";

export interface LiveRateSnapshot {
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
  tokensPerSecond: number;
  maxTokensPerSecond: number;
  trendLabel: string;
  liveRateStatusKind?: "failure" | "pending";
  liveRateStatusLabel?: string;
  resetCreditLabel: string;
  resetCreditRateBarLabel?: string;
  resetCreditStandaloneLabel?: string;
  totalTokensLabel: string;
  todayTokensLabel: string;
  requestsLabel: string;
  fiveHourLabel: string;
  fiveHourAvailability: "measured" | "unavailable";
  fiveHourRemainingPercent: number | null;
  sevenDayLabel: string;
  sevenDayAvailability: "measured" | "unavailable";
  sevenDayRemainingPercent: number | null;
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
