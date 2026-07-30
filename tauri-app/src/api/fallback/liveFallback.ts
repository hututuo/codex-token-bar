import type {
  FloatingPanelSnapshot,
  LiveRateSnapshot,
  UnreadSummary,
} from "../../types/live";

export function emptyLiveRateSnapshot(selectedThreadId?: string | null): LiveRateSnapshot {
  return {
    scopeLabel: "全会话",
    threadTitle: "等待任意会话输出",
    selectedThreadId: selectedThreadId || null,
    selectedThreadTitle: selectedThreadId ? "选中会话待读取" : "选择会话查看单会话速率",
    selectedTokensPerSecond: 0,
    tokensPerSecond: 0,
    totalTokens: 0,
    totalTokensToday: 0,
    requestsToday: 0,
    maxTokensPerSecond: 200,
    preciseEnabled: false,
    unreadSummary: emptyUnreadSummary,
    warnings: [],
  };
}

export const emptyUnreadSummary: UnreadSummary = {
  active: false,
  count: 0,
  label: "暂无未读完成会话",
  detail: "未读状态待读取。",
  source: "pending",
};

export const emptyFloatingPanelSnapshot: FloatingPanelSnapshot = {
  tokensPerSecond: 0,
  maxTokensPerSecond: 200,
  liveRateAvailable: false,
  trendLabel: "",
  resetCreditLabel: "",
  resetCreditRateBarLabel: "",
  resetCreditStandaloneLabel: "",
  totalTokensLabel: "总 待读取",
  todayTokensLabel: "今 待读取",
  requestsLabel: "次 待读取",
  fiveHourLabel: "5h 待读取",
  fiveHourAvailability: "unavailable",
  fiveHourRemainingPercent: null,
  fiveHourExpectedRemainingPercent: null,
  sevenDayLabel: "7d 待读取",
  sevenDayAvailability: "unavailable",
  sevenDayRemainingPercent: null,
  sevenDayExpectedRemainingPercent: null,
  unread: false,
  unreadSummary: emptyUnreadSummary,
};
