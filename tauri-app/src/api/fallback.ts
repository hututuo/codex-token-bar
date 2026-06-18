import type {
  AccountQuotaBundle,
  AppSettingsSnapshot,
  AutostartStatus,
  CodexHomeStatus,
  DashboardSnapshot,
  FloatingPanelSnapshot,
  LiveRateSnapshot,
  PlatformCapabilities,
  ProviderRepairActionResult,
  ProviderRepairSnapshot,
  UnreadSummary,
} from "../types/dashboard";

export const fallbackCodexHome: CodexHomeStatus = {
  path: "~/.codex",
  exists: false,
  source: "待读取",
};

export const fallbackAppSettings: AppSettingsSnapshot = {
  codexHome: null,
  floatingWindow: {
    opacity: 0.92,
    scale: 1,
    unreadEffect: "ripple",
  },
  floatingPosition: null,
  displaySurfaces: {
    floatingWindowEnabled: true,
    statusTrayLiveTextEnabled: true,
  },
  setupGuideCompleted: false,
};

export const fallbackPlatformCapabilities: PlatformCapabilities = {
  platform: "unknown",
  shell: "Tauri desktop",
  floatingWindow: pendingFeature("悬浮窗"),
  floatingTransparency: pendingFeature("透明悬浮窗"),
  floatingDrag: pendingFeature("拖动悬浮窗"),
  floatingLock: pendingFeature("窗口锁定"),
  statusTray: pendingFeature("状态栏"),
  statusTrayLiveText: pendingFeature("状态栏实时数字"),
  autostart: pendingFeature("开机自启"),
  notifications: pendingFeature("完成提醒"),
};

export const fallbackAutostartStatus: AutostartStatus = {
  available: false,
  enabled: false,
  status: "unavailable",
  message: "开机自启状态待读取。",
};

export function emptyDashboardSnapshot(): DashboardSnapshot {
  const now = new Date();
  return {
    generatedAt: now.toISOString(),
    account: {
      displayName: "账户待读取",
      planLabel: "计划待读取",
    },
    stats: {
      totalTokens: 0,
      peakDayTokens: 0,
      peakThreadTokens: 0,
      currentStreakDays: 0,
      longestStreakDays: 0,
      totalCalls: 0,
      totalThreads: 0,
    },
    quota: emptyQuotaSnapshot(),
    activityDays: emptyActivityDays(now),
    recentUsage24h: emptyRecentUsage(now),
    cacheHitRanking: [],
    warnings: [],
  };
}

export function emptyAccountQuotaBundle(): AccountQuotaBundle {
  return {
    account: {
      displayName: "账户待读取",
      planLabel: "计划待读取",
    },
    quota: emptyQuotaSnapshot(),
    quotaHistory24h: emptyRecentUsage(new Date()).map((point) => ({
      label: point.label,
      fiveHourRemainingPercent: null,
      sevenDayRemainingPercent: null,
    })),
    warnings: [],
  };
}

export function emptyLiveRateSnapshot(selectedThreadId?: string | null): LiveRateSnapshot {
  return {
    scopeLabel: "全会话",
    threadTitle: "等待任意会话输出",
    selectedThreadId: selectedThreadId || null,
    selectedThreadTitle: selectedThreadId ? "选中会话待读取" : "选择会话查看单会话速率",
    selectedTokensPerSecond: 0,
    tokensPerSecond: 0,
    totalTokensToday: 0,
    requestsToday: 0,
    maxTokensPerSecond: 200,
    preciseEnabled: false,
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
  trendLabel: "待输出",
  totalTokensLabel: "总 0",
  todayTokensLabel: "今 0",
  requestsLabel: "次 0",
  fiveHourLabel: "5h 待读取",
  sevenDayLabel: "7d 待读取",
  unread: false,
  unreadSummary: emptyUnreadSummary,
};

export const fallbackProviderRepairSnapshot: ProviderRepairSnapshot = {
  detectedProvider: "待读取",
  providerSource: "本地扫描",
  sessionFilesFound: 0,
  inconsistentCount: 0,
  status: "会话修复状态待读取。",
  steps: [
    { label: "扫描", status: "未扫描", done: false, healthy: true },
    { label: "备份", status: "未备份", done: false, healthy: true },
    { label: "修复", status: "未进行修复", done: false, healthy: true },
    { label: "验证", status: "未验证", done: false, healthy: true },
  ],
};

export const fallbackProviderRepairActionResult: ProviderRepairActionResult = {
  snapshot: fallbackProviderRepairSnapshot,
  message: "本地操作未完成，请稍后重试。",
  backup: null,
  backups: [],
};

function pendingFeature(label: string) {
  return {
    available: false,
    status: "pending",
    label,
    note: "平台能力待读取。",
  };
}

function emptyQuotaSnapshot() {
  return {
    fiveHour: {
      label: "5h",
      remainingPercent: 0,
      usedPercent: 0,
      resetsAt: "待读取",
      resetsAtUnix: null,
    },
    sevenDay: {
      label: "7d",
      remainingPercent: 0,
      usedPercent: 0,
      resetsAt: "待读取",
      resetsAtUnix: null,
    },
    resetCredit: {
      availableCount: 0,
      status: "重置卡待读取",
      credits: [],
    },
    paceLabel: "额度待读取",
  };
}

function emptyActivityDays(now: Date) {
  return Array.from({ length: 365 }, (_, index) => {
    const date = new Date(now);
    date.setDate(date.getDate() - (364 - index));
    return {
      date: date.toISOString().slice(0, 10),
      tokens: 0,
      calls: 0,
      cacheHitRate: 0,
      fiveHourRemainingPercent: null,
      sevenDayRemainingPercent: null,
    };
  });
}

function emptyRecentUsage(now: Date) {
  const end = Math.floor(now.getTime() / 300_000) * 300_000;
  const start = end - 24 * 60 * 60 * 1_000;
  return Array.from({ length: 289 }, (_, index) => {
    const date = new Date(start + index * 300_000);
    return {
      label: `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`,
      tokens: 0,
      calls: 0,
      cacheHitRate: null,
      fiveHourRemainingPercent: null,
      sevenDayRemainingPercent: null,
    };
  });
}
