import type {
  AccountQuotaBundle,
  CodexHomeStatus,
  DashboardSnapshot,
  FloatingPanelSnapshot,
  LiveRateSnapshot,
  ProviderRepairSnapshot,
} from "../types/dashboard";

export const mockCodexHome: CodexHomeStatus = {
  path: "~/.codex",
  exists: true,
  source: "mock",
};

const activityDays = Array.from({ length: 84 }, (_, index) => {
  const active = index > 64;
  const value = active ? Math.min(1, (index - 63) / 22) : index % 17 === 0 ? 0.32 : 0.06;
  return {
    date: `2026-${String(3 + Math.floor(index / 28)).padStart(2, "0")}-${String(
      1 + (index % 28),
    ).padStart(2, "0")}`,
    tokens: Math.round(value * 58_000_000),
    calls: Math.round(value * 16),
    cacheHitRate: 0.78 + value * 0.18,
  };
});

const recentUsage24h = Array.from({ length: 48 }, (_, index) => {
  const active = index > 34;
  const wave = ((index % 7) + 1) / 8;
  return {
    label: `${String(Math.floor(index / 2) % 24).padStart(2, "0")}:00`,
    tokens: active ? Math.round(wave * 8_600_000) : 0,
    calls: active ? Math.round(wave * 8) : 0,
    cacheHitRate: active ? 0.84 + wave * 0.12 : null,
    fiveHourRemainingPercent: index > 30 ? 1 - wave * 0.08 : null,
    sevenDayRemainingPercent: index > 30 ? 0.84 - wave * 0.02 : null,
  };
});

export const mockDashboardSnapshot: DashboardSnapshot = {
  generatedAt: "2026-06-18T13:30:00Z",
  account: {
    displayName: "来先生",
    planLabel: "Pro",
  },
  stats: {
    totalTokens: 4_360_000_000,
    peakDayTokens: 390_000_000,
    peakThreadTokens: 410_000_000,
    currentStreakDays: 10,
    longestStreakDays: 27,
    totalCalls: 513,
    totalThreads: 182,
  },
  quota: {
    fiveHour: {
      label: "5h",
      remainingPercent: 1,
      usedPercent: 0,
      resetsAt: "00:59",
    },
    sevenDay: {
      label: "7d",
      remainingPercent: 0.83,
      usedPercent: 0.17,
      resetsAt: "06/18 09:56",
    },
    resetCredit: {
      availableCount: 1,
      status: "1 张重置卡可用",
    },
    paceLabel: "节奏稳，多 3%",
  },
  activityDays,
  recentUsage24h,
  cacheHitRanking: [
    {
      rank: 1,
      title: "Codex Token Bar 迁移方案",
      subtitle: "多轮缓存命中稳定",
      hitRate: 0.94,
      inputTokens: 820_000,
      cachedTokens: 771_000,
    },
    {
      rank: 2,
      title: "悬浮窗视觉调整",
      subtitle: "排除第一轮后统计",
      hitRate: 0.89,
      inputTokens: 610_000,
      cachedTokens: 543_000,
    },
    {
      rank: 3,
      title: "会话消失修复",
      subtitle: "provider / index / backup",
      hitRate: 0.86,
      inputTokens: 540_000,
      cachedTokens: 464_000,
    },
  ],
};

export const mockAccountQuotaBundle: AccountQuotaBundle = {
  account: mockDashboardSnapshot.account,
  quota: mockDashboardSnapshot.quota,
};

export const mockLiveRateSnapshot: LiveRateSnapshot = {
  scopeLabel: "全会话",
  threadTitle: "等待任意会话输出",
  tokensPerSecond: 43.1,
  totalTokensToday: 61_461_000,
  requestsToday: 513,
  maxTokensPerSecond: 200,
  preciseEnabled: true,
};

export const mockFloatingPanelSnapshot: FloatingPanelSnapshot = {
  tokensPerSecond: 43.1,
  trendLabel: "节奏稳，多 3%",
  totalTokensLabel: "总 43.6亿",
  todayTokensLabel: "今 6146.1万",
  requestsLabel: "次 513",
  fiveHourLabel: "5h 100% 00:59",
  sevenDayLabel: "7d 83% 06/18",
  unread: true,
};

export const mockProviderRepairSnapshot: ProviderRepairSnapshot = {
  detectedProvider: "openai",
  providerSource: "mock",
  sessionFilesFound: 182,
  inconsistentCount: 0,
  status: "示例扫描结果",
  steps: [
    { label: "扫描", status: "未发现不一致", done: true, healthy: true },
    { label: "备份", status: "等待备份", done: false, healthy: true },
    { label: "修复", status: "未进行修复", done: false, healthy: true },
    { label: "验证", status: "未验证", done: false, healthy: true },
  ],
};
