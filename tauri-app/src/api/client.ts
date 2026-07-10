export {
  getCommandDiagnosticsSnapshot,
  subscribeCommandDiagnostics,
  type CommandFailureDiagnostic,
} from "./command";

export {
  getCodexHome,
  readAccountQuota,
  readDashboardSnapshot,
  readPlatformCapabilities,
  readPreciseDashboardSnapshot,
  readUsageCacheStatus,
  readUsageSummarySnapshot,
  resetCodexHome,
  setCodexHome,
} from "./dashboardClient";

export {
  readFloatingPanelSnapshot,
  readLiveRateSnapshot,
  readLiveThreadOptions,
  readUnreadSummary,
  acknowledgeUnreadSummary,
  resetLiveRateMonitor,
} from "./liveClient";

export {
  readAppSettings,
  readAutostartStatus,
  saveCustomAccountDisplayName,
  saveDisplaySurfaces,
  saveFloatingPosition,
  saveFloatingSettings,
  saveQuotaRefreshIntervalMs,
  saveSetupGuideCompleted,
  setAutostartEnabled,
} from "./settingsClient";

export {
  createProviderBackup,
  discoverProviderOperationOwnership,
  listProviderBackups,
  readProviderOperationStatus,
  rollbackProviderBackup,
  scanProviderRepair,
  syncProviderHistory,
  verifyProviderRepair,
} from "./providerRepairClient";

export { recordPerformanceEvent, recordStartupEvent } from "./startupClient";
