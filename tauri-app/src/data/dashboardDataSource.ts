import {
  getCodexHome,
  readAccountQuota,
  readDashboardSnapshot,
  readLiveRateSnapshot,
  readPlatformCapabilities,
  readPreciseDashboardSnapshot,
  resetCodexHome,
  scanProviderRepair,
  setCodexHome,
} from "../api/client";
import type {
  AccountQuotaBundle,
  CodexHomeStatus,
  DashboardSnapshot,
  LiveRateSnapshot,
  PlatformCapabilities,
  ProviderRepairSnapshot,
} from "../types/dashboard";

export interface DashboardDataSource {
  getCodexHome: () => Promise<CodexHomeStatus>;
  setCodexHome: (path: string) => Promise<CodexHomeStatus>;
  resetCodexHome: () => Promise<CodexHomeStatus>;
  readPlatformCapabilities: () => Promise<PlatformCapabilities>;
  readDashboardSnapshot: () => Promise<DashboardSnapshot>;
  readPreciseDashboardSnapshot: () => Promise<DashboardSnapshot>;
  readAccountQuota: () => Promise<AccountQuotaBundle>;
  readLiveRateSnapshot: () => Promise<LiveRateSnapshot>;
  scanProviderRepair: () => Promise<ProviderRepairSnapshot>;
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
  scanProviderRepair,
};
