import {
  acknowledgeAttributionSafety,
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
  CodexHomeSourceToken,
  DashboardSnapshot,
  LiveRateSnapshot,
  LiveThreadOption,
  PlatformCapabilities,
  ProviderRepairSnapshot,
  UsageCacheStatus,
} from "../types/dashboard";

export interface DashboardDataSource {
  acknowledgeAttributionSafety: (
    sourceToken: CodexHomeSourceToken,
    provenanceEpoch: string,
    unsafeID: string,
    throughGeneration: number,
  ) => Promise<boolean>;
  getCodexHome: () => Promise<CodexHomeSourceEnvelope | null>;
  setCodexHome: (path: string) => Promise<CodexHomeSourceEnvelope>;
  resetCodexHome: () => Promise<CodexHomeSourceEnvelope>;
  readPlatformCapabilities: () => Promise<PlatformCapabilities>;
  readDashboardSnapshot: (sourceToken: CodexHomeSourceToken) => Promise<DashboardSnapshot>;
  readPreciseDashboardSnapshot: (
    sourceToken: CodexHomeSourceToken,
  ) => Promise<DashboardSnapshot | null>;
  readUsageCacheStatus: () => Promise<UsageCacheStatus>;
  readAccountQuota: (
    sourceToken: CodexHomeSourceToken,
    forceRefresh?: boolean,
  ) => Promise<AccountQuotaBundle | null>;
  readLiveRateSnapshot: (selectedThreadId?: string | null) => Promise<LiveRateSnapshot>;
  readLiveThreadOptions: () => Promise<LiveThreadOption[]>;
  acknowledgeUnreadSummary: (
    sourceToken: CodexHomeSourceToken,
  ) => Promise<LiveRateSnapshot["unreadSummary"] | null>;
  scanProviderRepair: () => Promise<ProviderRepairSnapshot>;
}

export const dashboardDataSource: DashboardDataSource = {
  acknowledgeAttributionSafety,
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
