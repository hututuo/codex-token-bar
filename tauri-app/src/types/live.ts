import type { LocalDataWarning } from "./diagnostics";

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
