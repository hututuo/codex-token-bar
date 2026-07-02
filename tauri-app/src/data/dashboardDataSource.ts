import {
  getCodexHome,
  readAccountQuota,
  readDashboardSnapshot,
  readLiveRateSnapshot,
  readLiveThreadOptions,
  readPlatformCapabilities,
  readPreciseDashboardSnapshot,
  readUsageCacheStatus,
  resetCodexHome,
  setCodexHome,
} from "../api/client";
import type {
  AccountQuotaBundle,
  CodexHomeStatus,
  DashboardSnapshot,
  LiveRateSnapshot,
  LiveThreadOption,
  PlatformCapabilities,
  UsageCacheStatus,
} from "../types/dashboard";

export interface DashboardDataSource {
  getCodexHome: () => Promise<CodexHomeStatus>;
  setCodexHome: (path: string) => Promise<CodexHomeStatus>;
  resetCodexHome: () => Promise<CodexHomeStatus>;
  readPlatformCapabilities: () => Promise<PlatformCapabilities>;
  readDashboardSnapshot: () => Promise<DashboardSnapshot>;
  readPreciseDashboardSnapshot: () => Promise<DashboardSnapshot | null>;
  readUsageCacheStatus: () => Promise<UsageCacheStatus>;
  readAccountQuota: (forceRefresh?: boolean) => Promise<AccountQuotaBundle | null>;
  readLiveRateSnapshot: (selectedThreadId?: string | null) => Promise<LiveRateSnapshot>;
  readLiveThreadOptions: () => Promise<LiveThreadOption[]>;
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
};
