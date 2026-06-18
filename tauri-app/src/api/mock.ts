import type {
  AccountQuotaBundle,
  AppSettingsSnapshot,
  CodexHomeStatus,
  DashboardSnapshot,
  FloatingPanelSnapshot,
  LiveRateSnapshot,
  PlatformCapabilities,
  ProviderRepairActionResult,
  ProviderRepairBackupInfo,
  ProviderRepairSnapshot,
} from "../types/dashboard";

export const mockCodexHome: CodexHomeStatus = {
  path: "~/.codex",
  exists: true,
  source: "mock",
};

export const mockAppSettings: AppSettingsSnapshot = {
  codexHome: null,
  floatingWindow: {
    opacity: 0.92,
    scale: 1,
  },
  floatingPosition: null,
  displaySurfaces: {
    floatingWindowEnabled: true,
    statusTrayLiveTextEnabled: true,
  },
};

export const mockPlatformCapabilities: PlatformCapabilities = {
  platform: "mock",
  shell: "Tauri desktop",
  floatingWindow: {
    available: true,
    status: "ready",
    label: "悬浮窗",
    note: "共享 UI 调试模式可用。",
  },
  floatingTransparency: {
    available: true,
    status: "ready",
    label: "透明悬浮窗",
    note: "共享 UI 调试模式可用。",
  },
  floatingDrag: {
    available: true,
    status: "ready",
    label: "拖动悬浮窗",
    note: "共享 UI 调试模式可用。",
  },
  floatingLock: {
    available: false,
    status: "pending",
    label: "窗口锁定",
    note: "平台层待接入。",
  },
  statusTray: {
    available: true,
    status: "ready",
    label: "状态栏",
    note: "共享 UI 调试模式可用。",
  },
  statusTrayLiveText: {
    available: true,
    status: "ready",
    label: "状态栏实时数字",
    note: "共享 UI 调试模式可用。",
  },
  autostart: {
    available: false,
    status: "pending",
    label: "开机自启",
    note: "平台层待接入。",
  },
  notifications: {
    available: false,
    status: "pending",
    label: "完成提醒",
    note: "平台层待接入。",
  },
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
    fiveHourRemainingPercent: active ? 1 - value * 0.08 : null,
    sevenDayRemainingPercent: active ? 0.86 - value * 0.03 : null,
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
      resetsAtUnix: null,
    },
    sevenDay: {
      label: "7d",
      remainingPercent: 0.83,
      usedPercent: 0.17,
      resetsAt: "06/18 09:56",
      resetsAtUnix: null,
    },
    resetCredit: {
      availableCount: 1,
      status: "1 张重置卡可用",
      credits: [
        {
          title: "重置卡 1",
          status: "可用",
          summary: "状态 可用 · 到期 2026-06-20 09:56",
          issuedAt: "2026-06-12 09:56",
          expiresAt: "2026-06-20 09:56",
          redeemedAt: "未使用",
          source: "系统发放",
          associatedUser: "来先生",
          shortId: "rc_01...9f2a",
        },
      ],
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
  quotaHistory24h: recentUsage24h.map((point) => ({
    label: point.label,
    fiveHourRemainingPercent: point.fiveHourRemainingPercent,
    sevenDayRemainingPercent: point.sevenDayRemainingPercent,
  })),
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

export const mockProviderRepairBackups: ProviderRepairBackupInfo[] = [
  {
    id: "20260618-160300",
    createdAt: "2026-06-18T16:03:00+08:00",
    path: "~/Library/Application Support/CodexHistoryRepair/backups/20260618-160300",
    targetProvider: "openai",
    sessionFiles: 182,
    stateDatabase: true,
    sessionIndex: true,
  },
];

export const mockProviderRepairActionResult: ProviderRepairActionResult = {
  snapshot: mockProviderRepairSnapshot,
  message: "示例操作完成",
  backup: mockProviderRepairBackups[0],
  backups: mockProviderRepairBackups,
};
