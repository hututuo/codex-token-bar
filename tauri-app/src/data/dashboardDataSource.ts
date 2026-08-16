import {
  acknowledgeAttributionSafety,
  getCodexHome,
  readAccountQuota,
  readAccountResetCredits,
  readDashboardSnapshot,
  readLiveRateSnapshot,
  readLiveThreadOptions,
  acknowledgeUnreadSummary,
  readPlatformCapabilities,
  readPreciseDashboardSnapshot,
  readPreciseDashboardProgress,
  readPreciseDashboardSourceProbe,
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
  PreciseDashboardRefreshReason,
  PreciseDashboardProgress,
  PreciseDashboardSourceProbe,
  PlatformCapabilities,
  ProviderRepairSnapshot,
  UsageCacheStatus,
} from "../types/dashboard";
import type { ResetCreditBundle } from "../types/quota";

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
    requestReason?: PreciseDashboardRefreshReason,
  ) => Promise<DashboardSnapshot | null>;
  readPreciseDashboardProgress?: (
    sourceToken: CodexHomeSourceToken,
  ) => Promise<PreciseDashboardProgress | null>;
  readPreciseDashboardSourceProbe: (
    sourceToken: CodexHomeSourceToken,
  ) => Promise<PreciseDashboardSourceProbe | null>;
  readUsageCacheStatus: () => Promise<UsageCacheStatus>;
  readAccountQuota: (
    sourceToken: CodexHomeSourceToken,
    forceRefresh?: boolean,
  ) => Promise<AccountQuotaBundle | null>;
  readAccountResetCredits: (
    sourceToken: CodexHomeSourceToken,
    forceRefresh?: boolean,
  ) => Promise<ResetCreditBundle | null>;
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
  readPreciseDashboardProgress,
  readPreciseDashboardSourceProbe,
  readUsageCacheStatus,
  readAccountQuota,
  readAccountResetCredits,
  readLiveRateSnapshot,
  readLiveThreadOptions,
  acknowledgeUnreadSummary,
  scanProviderRepair,
};
