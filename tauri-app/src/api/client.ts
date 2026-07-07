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
  listProviderBackups,
  rollbackProviderBackup,
  scanProviderRepair,
  syncProviderHistory,
  verifyProviderRepair,
} from "./providerRepairClient";

export { recordPerformanceEvent, recordStartupEvent } from "./startupClient";
