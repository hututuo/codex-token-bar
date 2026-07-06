import type {
  FloatingPanelSnapshot,
  LiveRateSnapshot,
  UsageSummarySnapshot,
} from "../types/dashboard";

const baseFloatingPanelSnapshot: FloatingPanelSnapshot = {
  tokensPerSecond: 0,
  maxTokensPerSecond: 200,
  trendLabel: "",
  resetCreditLabel: "",
  resetCreditRateBarLabel: "",
  resetCreditStandaloneLabel: "",
  totalTokensLabel: "总 待读取",
  todayTokensLabel: "今 待读取",
  requestsLabel: "次 待读取",
  fiveHourLabel: "5h 待读取",
  fiveHourRemainingPercent: 0,
  sevenDayLabel: "7d 待读取",
  sevenDayRemainingPercent: 0,
  unread: false,
  unreadSummary: {
    active: false,
    count: 0,
    label: "暂无未读完成会话",
    detail: "未读状态待读取。",
    source: "pending",
  },
};

const LIVE_RATE_STREAM_WARNING_SOURCE = "live_rate_stream";
const LIVE_RATE_SUMMARY_WARNING_SOURCE = "live_rate_summary";

export function floatingSnapshotForLiveRate(
  liveRate: LiveRateSnapshot,
  usageSummary: UsageSummarySnapshot | null,
): FloatingPanelSnapshot {
  const liveRateStatus = compactLiveRateStatus(liveRate);
  const snapshot: FloatingPanelSnapshot = {
    ...baseFloatingPanelSnapshot,
    tokensPerSecond: liveRate.tokensPerSecond,
    maxTokensPerSecond: liveRate.maxTokensPerSecond,
    liveRateStatusKind: liveRateStatus?.kind,
    liveRateStatusLabel: liveRateStatus?.label,
    unread: liveRate.unreadSummary.active,
    unreadSummary: liveRate.unreadSummary,
  };
  return usageSummary ? mergeFloatingUsageSummary(snapshot, usageSummary) : snapshot;
}

export function disabledFloatingLiveSnapshot(
  snapshot: FloatingPanelSnapshot,
): FloatingPanelSnapshot {
  return {
    ...snapshot,
    tokensPerSecond: 0,
    maxTokensPerSecond: baseFloatingPanelSnapshot.maxTokensPerSecond,
    liveRateStatusKind: undefined,
    liveRateStatusLabel: undefined,
  };
}

export function floatingLiveRateStatusText(
  snapshot: Pick<FloatingPanelSnapshot, "liveRateStatusLabel">,
): string {
  return snapshot.liveRateStatusLabel ?? "";
}

export function liveRateStreamStartFailureSnapshot(message: string): LiveRateSnapshot {
  return {
    scopeLabel: "实时速率",
    threadTitle: "实时速率不可用",
    selectedThreadId: null,
    selectedThreadTitle: "未选择",
    selectedTokensPerSecond: 0,
    tokensPerSecond: 0,
    totalTokens: 0,
    totalTokensToday: 0,
    requestsToday: 0,
    maxTokensPerSecond: baseFloatingPanelSnapshot.maxTokensPerSecond,
    preciseEnabled: false,
    unreadSummary: baseFloatingPanelSnapshot.unreadSummary,
    warnings: [
      {
        source: LIVE_RATE_STREAM_WARNING_SOURCE,
        message: message.trim() || "实时速率流暂不可用",
      },
    ],
  };
}

export function mergeFloatingUsageSummary(
  snapshot: FloatingPanelSnapshot,
  summary: UsageSummarySnapshot,
): FloatingPanelSnapshot {
  return {
    ...snapshot,
    totalTokensLabel: `总 ${compactTokens(summary.totalTokens)}`,
    todayTokensLabel: `今 ${compactTokens(summary.todayTokens)}`,
    requestsLabel: `次 ${summary.todayRequests}`,
  };
}

export function compactTokens(value: number): string {
  if (value >= 100_000_000) {
    return `${(value / 100_000_000).toFixed(1)}亿`;
  }
  if (value >= 10_000) {
    return `${(value / 10_000).toFixed(1)}万`;
  }
  return String(Math.max(0, Math.round(value)));
}

function compactLiveRateStatus(liveRate: LiveRateSnapshot): { kind: "failure" | "pending"; label: string } | null {
  if (liveRate.warnings.some((warning) => warning.source === LIVE_RATE_STREAM_WARNING_SOURCE)) {
    return {
      kind: "failure",
      label: "实时速率降级",
    };
  }

  if (liveRate.warnings.some((warning) => warning.source === LIVE_RATE_SUMMARY_WARNING_SOURCE)) {
    return {
      kind: "pending",
      label: "准备中，请稍后",
    };
  }

  return null;
}
