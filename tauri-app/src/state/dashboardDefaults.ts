import type {
  LiveRateSnapshot,
  ProviderRepairSnapshot,
} from "../types/dashboard";
import {
  emptyDashboardSnapshot,
  emptyLiveRateSnapshot,
  fallbackCodexHome,
  fallbackPlatformCapabilities,
  fallbackProviderRepairSnapshot,
} from "../api/fallback";
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
    ...emptyLiveRateSnapshot(),
    threadTitle: "实时速率正在连接",
  };
}

export function disabledLiveRateSnapshot(selectedThreadId?: string | null): LiveRateSnapshot {
  return {
    ...emptyLiveRateSnapshot(selectedThreadId),
    scopeLabel: "实时速率",
    threadTitle: "实时速率已关闭",
    selectedThreadTitle: selectedThreadId ? "实时速率已关闭" : "选择会话查看单会话速率",
    warnings: [],
  };
}

export function pendingRepairSnapshot(): ProviderRepairSnapshot {
  return {
    ...fallbackProviderRepairSnapshot,
    detectedProvider: "未扫描",
    providerSource: "手动扫描",
    status: "会话修复尚未扫描。需要时点击扫描，应用不会在启动时自动读取修复范围。",
  };
}

function pendingCodexHomeStatus() {
  return {
    ...fallbackCodexHome,
    source: "读取中",
  };
}

function pendingPlatformCapabilities() {
  return {
    ...fallbackPlatformCapabilities,
    platform: "loading",
  };
}

function pendingDashboardSnapshot() {
  const snapshot = emptyDashboardSnapshot();
  return {
    ...snapshot,
    account: {
      ...snapshot.account,
      displayName: "读取中",
    },
  };
}
