import type { LocalDataWarning } from "./diagnostics";

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
  fiveHourRemainingPercent: number;
  sevenDayLabel: string;
  sevenDayRemainingPercent: number;
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
