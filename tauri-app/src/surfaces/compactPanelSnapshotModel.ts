import type {
  DashboardSnapshot,
  FloatingPanelSnapshot,
  LiveRateSnapshot,
  UsageSummarySnapshot,
} from "../types/dashboard";

const baseFloatingPanelSnapshot: FloatingPanelSnapshot = {
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
  todayModelBreakdowns: [],
  fiveHourLabel: "5h 待读取",
  fiveHourAvailability: "unavailable",
  fiveHourRemainingPercent: null,
  fiveHourExpectedRemainingPercent: null,
  sevenDayLabel: "7d 待读取",
  sevenDayAvailability: "unavailable",
  sevenDayRemainingPercent: null,
  sevenDayExpectedRemainingPercent: null,
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
    liveRateAvailable: liveRateStatus?.kind !== "failure",
    liveRateStatusKind: liveRateStatus?.kind,
    liveRateStatusLabel: liveRateStatus?.label,
    unread: liveRate.unreadSummary.active,
    unreadSummary: liveRate.unreadSummary,
  };
  return usageSummary ? mergeFloatingUsageSummary(snapshot, usageSummary) : snapshot;
}

export function floatingSnapshotForDashboardPreview(
  liveRate: LiveRateSnapshot,
  dashboard: DashboardSnapshot,
): FloatingPanelSnapshot {
  const generatedDate = new Date(dashboard.generatedAt);
  const dayKey = Number.isNaN(generatedDate.getTime())
    ? ""
    : new Intl.DateTimeFormat("en-CA", {
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }).format(generatedDate);
  const today = dashboard.activityDays.find((day) => day.date === dayKey)
    ?? dashboard.activityDays.at(-1);
  const snapshot = floatingSnapshotForLiveRate(liveRate, {
    totalTokens: dashboard.stats.totalTokens,
    todayTokens: today?.tokens ?? liveRate.totalTokensToday,
    todayRequests: today?.calls ?? liveRate.requestsToday,
    todayModelBreakdowns: today?.modelBreakdowns ?? [],
  });
  return {
    ...snapshot,
    fiveHourLabel: dashboard.quota.fiveHour.label || "5h",
    fiveHourAvailability: dashboard.quota.fiveHour.availability,
    fiveHourRemainingPercent: dashboard.quota.fiveHour.remainingPercent,
    fiveHourExpectedRemainingPercent: null,
    sevenDayLabel: dashboard.quota.sevenDay.label || "7d",
    sevenDayAvailability: dashboard.quota.sevenDay.availability,
    sevenDayRemainingPercent: dashboard.quota.sevenDay.remainingPercent,
    sevenDayExpectedRemainingPercent: null,
  };
}

export function disabledFloatingLiveSnapshot(
  snapshot: FloatingPanelSnapshot,
): FloatingPanelSnapshot {
  return {
    ...snapshot,
    tokensPerSecond: 0,
    maxTokensPerSecond: baseFloatingPanelSnapshot.maxTokensPerSecond,
    liveRateAvailable: false,
    liveRateStatusKind: undefined,
    liveRateStatusLabel: undefined,
  };
}

export function compactSnapshotForSurfaceActivity(
  snapshot: FloatingPanelSnapshot,
  active: boolean,
  liveRateEnabled: boolean,
): FloatingPanelSnapshot {
  if (!active) {
    return snapshot;
  }
  return liveRateEnabled ? snapshot : disabledFloatingLiveSnapshot(snapshot);
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
  const incomingModelBreakdowns = summary.todayModelBreakdowns;
  // The native summary command may briefly return a numeric summary while its
  // exact model projection is still rebuilding. An empty/omitted breakdown in
  // that state is not a successful zero-usage day: keep the last trusted rows
  // until a complete model projection arrives. A genuinely empty day has
  // todayTokens === 0 and is allowed to clear the rows.
  const keepTrustedModelBreakdowns = (
    (!incomingModelBreakdowns || incomingModelBreakdowns.length === 0)
    && summary.todayTokens > 0
    && snapshot.todayModelBreakdowns.length > 0
  );
  return {
    ...snapshot,
    totalTokensLabel: `总 ${compactTokens(summary.totalTokens)}`,
    todayTokensLabel: `今 ${compactTokens(summary.todayTokens)}`,
    requestsLabel: `次 ${summary.todayRequests}`,
    todayModelBreakdowns: keepTrustedModelBreakdowns
      ? snapshot.todayModelBreakdowns
      : incomingModelBreakdowns ?? [],
  };
}

export function preserveFloatingUsageSummary(
  snapshot: FloatingPanelSnapshot,
): FloatingPanelSnapshot {
  return snapshot;
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
      label: "统计重建中",
    };
  }

  return null;
}
