import {
  getCodexHome,
  readAccountQuota,
  readDashboardSnapshot,
  readLiveRateSnapshot,
  readLiveThreadOptions,
  acknowledgeUnreadSummary,
  readPlatformCapabilities,
  readPreciseDashboardSnapshot,
  readUsageCacheStatus,
  scanProviderRepair,
  resetCodexHome,
  setCodexHome,
} from "../api/client";
import type {
  AccountQuotaBundle,
  CodexHomeSourceEnvelope,
  DashboardSnapshot,
  LiveRateSnapshot,
  LiveThreadOption,
  PlatformCapabilities,
  ProviderRepairSnapshot,
  UsageCacheStatus,
} from "../types/dashboard";

export interface DashboardDataSource {
  getCodexHome: () => Promise<CodexHomeSourceEnvelope>;
  setCodexHome: (path: string) => Promise<CodexHomeSourceEnvelope>;
  resetCodexHome: () => Promise<CodexHomeSourceEnvelope>;
  readPlatformCapabilities: () => Promise<PlatformCapabilities>;
  readDashboardSnapshot: () => Promise<DashboardSnapshot>;
  readPreciseDashboardSnapshot: () => Promise<DashboardSnapshot | null>;
  readUsageCacheStatus: () => Promise<UsageCacheStatus>;
  readAccountQuota: (forceRefresh?: boolean) => Promise<AccountQuotaBundle | null>;
  readLiveRateSnapshot: (selectedThreadId?: string | null) => Promise<LiveRateSnapshot>;
  readLiveThreadOptions: () => Promise<LiveThreadOption[]>;
  acknowledgeUnreadSummary: () => Promise<LiveRateSnapshot["unreadSummary"]>;
  scanProviderRepair: () => Promise<ProviderRepairSnapshot>;
}

export const dashboardDataSource: DashboardDataSource = {
  getCodexHome,
  setCodexHome,
  resetCodexHome,
  readPlatformCapabilities,
  readDashboardSnapshot,
  readPreciseDashboardSnapshot,
  readUsageCacheStatus,
  readAccountQuota,
  readLiveRateSnapshot,
  readLiveThreadOptions,
  acknowledgeUnreadSummary,
  scanProviderRepair,
};
