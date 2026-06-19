import type {
  CodexHomeStatus,
  DashboardSnapshot,
  LiveRateSnapshot,
  PlatformCapabilities,
  ProviderRepairSnapshot,
} from "../types/dashboard";
import type { DashboardAppState } from "./dashboardState";

export const initialDashboardState: DashboardAppState = {
  codexHome: pendingCodexHomeStatus(),
  platform: pendingPlatformCapabilities(),
  dashboard: pendingDashboardSnapshot(),
  liveRate: pendingLiveRateSnapshot(),
  liveThreadOptions: [],
  repair: pendingRepairSnapshot(),
  diagnostics: [],
  loading: false,
};

export function pendingLiveRateSnapshot(): LiveRateSnapshot {
  return {
    scopeLabel: "全会话",
    threadTitle: "实时速率正在连接",
    selectedThreadId: null,
    selectedThreadTitle: "选择会话查看单会话速率",
    selectedTokensPerSecond: 0,
    tokensPerSecond: 0,
    totalTokensToday: 0,
    requestsToday: 0,
    maxTokensPerSecond: 200,
    preciseEnabled: false,
    warnings: [],
  };
}

export function pendingRepairSnapshot(): ProviderRepairSnapshot {
  return {
    detectedProvider: "未扫描",
    providerSource: "手动扫描",
    sessionFilesFound: 0,
    inconsistentCount: 0,
    status: "会话修复尚未扫描。需要时点击扫描，应用不会在启动时自动读取修复范围。",
    steps: [
      { label: "扫描", status: "未扫描", done: false, healthy: true },
      { label: "备份", status: "未备份", done: false, healthy: true },
      { label: "修复", status: "未进行修复", done: false, healthy: true },
      { label: "验证", status: "未验证", done: false, healthy: true },
    ],
  };
}

function pendingCodexHomeStatus(): CodexHomeStatus {
  return {
    path: "~/.codex",
    exists: false,
    source: "读取中",
  };
}

function pendingPlatformCapabilities(): PlatformCapabilities {
  return {
    platform: "loading",
    shell: "Tauri desktop",
    floatingWindow: {
      available: false,
      status: "pending",
      label: "悬浮窗",
      note: "正在读取平台能力。",
    },
    floatingTransparency: {
      available: false,
      status: "pending",
      label: "透明悬浮窗",
      note: "正在读取平台能力。",
    },
    floatingDrag: {
      available: false,
      status: "pending",
      label: "拖动悬浮窗",
      note: "正在读取平台能力。",
    },
    floatingLock: {
      available: false,
      status: "pending",
      label: "窗口锁定",
      note: "正在读取平台能力。",
    },
    statusTray: {
      available: false,
      status: "pending",
      label: "状态栏",
      note: "正在读取平台能力。",
    },
    statusTrayLiveText: {
      available: false,
      status: "pending",
      label: "状态栏实时数字",
      note: "正在读取平台能力。",
    },
    autostart: {
      available: false,
      status: "pending",
      label: "开机自启",
      note: "正在读取平台能力。",
    },
    notifications: {
      available: false,
      status: "pending",
      label: "完成提醒",
      note: "正在读取平台能力。",
    },
  };
}

function pendingDashboardSnapshot(): DashboardSnapshot {
  return {
    generatedAt: new Date().toISOString(),
    account: {
      displayName: "读取中",
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
    quota: {
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
    },
    activityDays: pendingActivityDays(),
    recentUsage24h: pendingRecentUsage(),
    cacheHitRanking: [],
    warnings: [],
  };
}

function pendingActivityDays() {
  return Array.from({ length: 365 }, (_, index) => {
    const date = new Date();
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

function pendingRecentUsage() {
  const now = new Date();
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
