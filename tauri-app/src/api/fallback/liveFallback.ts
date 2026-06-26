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
  trendLabel: "",
  resetCreditLabel: "卡--",
  totalTokensLabel: "总 0",
  todayTokensLabel: "今 0",
  requestsLabel: "次 0",
  fiveHourLabel: "5h 待读取",
  fiveHourRemainingPercent: 0,
  sevenDayLabel: "7d 待读取",
  sevenDayRemainingPercent: 0,
  unread: false,
  unreadSummary: emptyUnreadSummary,
};
