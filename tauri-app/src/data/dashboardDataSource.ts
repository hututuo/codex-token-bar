import {
  getCodexHome,
  readAccountQuota,
  readDashboardSnapshot,
  readLiveRateSnapshot,
  readLiveThreadOptions,
  readPlatformCapabilities,
  readPreciseDashboardSnapshot,
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
} from "../types/dashboard";

export interface DashboardDataSource {
  getCodexHome: () => Promise<CodexHomeStatus>;
  setCodexHome: (path: string) => Promise<CodexHomeStatus>;
  resetCodexHome: () => Promise<CodexHomeStatus>;
  readPlatformCapabilities: () => Promise<PlatformCapabilities>;
  readDashboardSnapshot: () => Promise<DashboardSnapshot>;
  readPreciseDashboardSnapshot: () => Promise<DashboardSnapshot>;
  readAccountQuota: (forceRefresh?: boolean) => Promise<AccountQuotaBundle>;
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
  readAccountQuota,
  readLiveRateSnapshot,
  readLiveThreadOptions,
};
