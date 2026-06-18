import type {
  AccountQuotaBundle,
  CodexHomeStatus,
  DashboardSnapshot,
  LocalDataWarning,
  LiveRateSnapshot,
  LiveThreadOption,
  PlatformCapabilities,
  ProviderRepairSnapshot,
  RecentUsagePoint,
} from "../types/dashboard";
import type { CommandFailureDiagnostic } from "../api/client";

export interface DashboardAppState {
  codexHome: CodexHomeStatus | null;
  platform: PlatformCapabilities | null;
  dashboard: DashboardSnapshot | null;
  liveRate: LiveRateSnapshot | null;
  liveThreadOptions: LiveThreadOption[];
  repair: ProviderRepairSnapshot | null;
  diagnostics: CommandFailureDiagnostic[];
  loading: boolean;
}

export interface DashboardReadyState {
  codexHome: CodexHomeStatus;
  platform: PlatformCapabilities;
  dashboard: DashboardSnapshot;
  liveRate: LiveRateSnapshot;
  liveThreadOptions: LiveThreadOption[];
  repair: ProviderRepairSnapshot;
  diagnostics: CommandFailureDiagnostic[];
}

export const initialDashboardState: DashboardAppState = {
  codexHome: pendingCodexHomeStatus(),
  platform: pendingPlatformCapabilities(),
  dashboard: pendingDashboardSnapshot(),
  liveRate: pendingLiveRateSnapshot(),
  liveThreadOptions: [],
  repair: pendingRepairSnapshot(),
  diagnostics: [],
  loading: true,
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

export function readyDashboardState(state: DashboardAppState): DashboardReadyState | null {
  if (
    state.codexHome === null ||
    state.platform === null ||
    state.dashboard === null ||
    state.liveRate === null ||
    state.repair === null
  ) {
    return null;
  }

  return {
    codexHome: state.codexHome,
    platform: state.platform,
    dashboard: state.dashboard,
    liveRate: state.liveRate,
    liveThreadOptions: state.liveThreadOptions,
    repair: state.repair,
    diagnostics: mergeWarningDiagnostics(state.diagnostics, state.dashboard.warnings, state.dashboard.generatedAt),
  };
}

export function mergePreciseDashboard(
  state: DashboardAppState,
  precise: DashboardSnapshot,
): DashboardAppState {
  return {
    ...state,
    dashboard:
      state.dashboard === null
        ? precise
        : {
            ...precise,
            account: state.dashboard.account,
            quota: state.dashboard.quota,
            warnings: mergeWarnings(state.dashboard.warnings, precise.warnings),
          },
  };
}

export function mergeQuota(state: DashboardAppState, quota: AccountQuotaBundle): DashboardAppState {
  const dashboard =
    state.dashboard === null
      ? null
      : {
          ...state.dashboard,
          account: quota.account,
          quota: quota.quota,
          recentUsage24h: mergeQuotaHistory(state.dashboard.recentUsage24h, quota),
          warnings: mergeWarnings(state.dashboard.warnings, quota.warnings),
        };
  return {
    ...state,
    dashboard,
  };
}

export function mergeLiveRate(
  state: DashboardAppState,
  liveRate: LiveRateSnapshot,
): DashboardAppState {
  return {
    ...state,
    liveRate,
  };
}

export function mergeLiveThreadOptions(
  state: DashboardAppState,
  liveThreadOptions: LiveThreadOption[],
): DashboardAppState {
  return {
    ...state,
    liveThreadOptions,
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
      planLabel: "Pro",
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

function mergeQuotaHistory(points: RecentUsagePoint[], quota: AccountQuotaBundle): RecentUsagePoint[] {
  if (quota.quotaHistory24h.length === 0) {
    return points;
  }

  return points.map((point, index) => {
    const history = quota.quotaHistory24h[index];
    if (history === undefined) {
      return point;
    }
    return {
      ...point,
      fiveHourRemainingPercent: history.fiveHourRemainingPercent,
      sevenDayRemainingPercent: history.sevenDayRemainingPercent,
    };
  });
}

function mergeWarnings(left: LocalDataWarning[], right: LocalDataWarning[]): LocalDataWarning[] {
  const byKey = new Map<string, LocalDataWarning>();
  [...left, ...right].forEach((warning) => {
    const key = `${warning.source}:${warning.message}`;
    byKey.set(key, warning);
  });
  return Array.from(byKey.values());
}

function mergeWarningDiagnostics(
  diagnostics: CommandFailureDiagnostic[],
  warnings: LocalDataWarning[],
  generatedAt: string,
): CommandFailureDiagnostic[] {
  if (warnings.length === 0) {
    return diagnostics;
  }
  const warningDiagnostics = warnings.map((warning) => ({
    command: `local:${warning.source}`,
    message: warning.message,
    occurredAt: generatedAt,
    count: 1,
  }));
  return [...warningDiagnostics, ...diagnostics];
}
