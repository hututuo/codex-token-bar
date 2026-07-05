import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("custom account display-name persistence remains wired through shell settings", async () => {
  const dashboardApp = await readFile(new URL("./DashboardApp.tsx", import.meta.url), "utf8");
  const shellSettings = await readFile(new URL("./useDashboardShellSettings.ts", import.meta.url), "utf8");
  const settingsClient = await readFile(new URL("../api/settingsClient.ts", import.meta.url), "utf8");

  assert.equal(dashboardApp.includes("customAccountDisplayName={shellSettings.customAccountDisplayName}"), true);
  assert.equal(
    dashboardApp.includes("onCustomAccountDisplayNameChange={shellSettings.updateCustomAccountDisplayName}"),
    true,
  );
  assert.equal(shellSettings.includes("saveCustomAccountDisplayName"), true);
  assert.equal(settingsClient.includes("save_custom_account_display_name"), true);
});

test("floating toggle follows saved preference instead of transient visibility", async () => {
  const hook = await readFile(new URL("./useFloatingWindowSurface.ts", import.meta.url), "utf8");
  const model = await readFile(new URL("./floatingWindowSurfaceModel.ts", import.meta.url), "utf8");
  const toggleBody = hook.slice(hook.indexOf("const toggleFloatingWindow"));

  assert.equal(toggleBody.includes("const nextEnabled = !enabled"), true);
  assert.equal(toggleBody.includes("const nextVisible = !floatingVisible"), false);
  assert.equal(toggleBody.includes("onPreferenceConfirmed(nextEnabled)"), false);
  assert.equal(toggleBody.includes("setFloatingVisible(nextEnabled)"), false);
  assert.equal(toggleBody.includes("floatingCommandPreferenceConfirmation(result)"), true);
  assert.equal(toggleBody.includes("confirmedPreference !== null"), true);
  assert.equal(toggleBody.includes("floatingCommandVisibleState(result"), true);
  assert.equal(model.includes("return result.ok ? result.value : null"), true);
  assert.equal(model.includes("return result.ok ? result.value : currentVisible"), true);
});

test("floating hidden event also turns off saved preference", async () => {
  const hook = await readFile(new URL("./useFloatingWindowSurface.ts", import.meta.url), "utf8");
  const hiddenHandler = hook.slice(
    hook.indexOf("desktopPlatform.onFloatingWindowHidden"),
    hook.indexOf("}).then((listener)"),
  );

  assert.equal(hiddenHandler.includes("updateFloatingVisible(false)"), true);
  assert.equal(hiddenHandler.includes("onPreferenceConfirmed(false)"), true);
});

test("floating hidden event cannot overwrite first-launch default before settings load", async () => {
  const hook = await readFile(new URL("./useFloatingWindowSurface.ts", import.meta.url), "utf8");
  const hiddenHandler = hook.slice(
    hook.indexOf("desktopPlatform.onFloatingWindowHidden"),
    hook.indexOf("}).then((listener)"),
  );

  assert.equal(hiddenHandler.includes("settingsReadyRef.current"), true);
  assert.equal(hiddenHandler.includes("enabledPreferenceRef.current"), true);
  assert.equal(
    hiddenHandler.includes("shouldConfirmFloatingHiddenEvent(settingsReadyRef.current, enabledPreferenceRef.current)"),
    true,
  );
});

test("startup floating apply does not rewrite saved preference when show returns false", async () => {
  const hook = await readFile(new URL("./useFloatingWindowSurface.ts", import.meta.url), "utf8");
  const applyEffect = hook.slice(
    hook.indexOf("async function applyFloatingPreference"),
    hook.indexOf("const toggleFloatingWindow"),
  );

  assert.equal(applyEffect.includes("updateFloatingVisible(floatingCommandVisibleState(result"), true);
  assert.equal(applyEffect.includes("onPreferenceConfirmed(nextVisible)"), false);
  assert.equal(applyEffect.includes("onPreferenceConfirmed(false)"), false);
});

test("setup guide renders floating toggle from saved preference", async () => {
  const setupGuide = await readFile(new URL("../components/SetupGuide.tsx", import.meta.url), "utf8");

  assert.equal(setupGuide.includes("active={floatingVisible}"), false);
  assert.equal(setupGuide.includes("active={displaySurfaces.floatingWindowEnabled}"), true);
});

test("dashboard data no longer subscribes command diagnostics into product state", async () => {
  const dashboardData = await readFile(new URL("../state/useDashboardData.ts", import.meta.url), "utf8");
  const initialLoad = await readFile(new URL("../state/loadInitialDashboardState.ts", import.meta.url), "utf8");

  assert.equal(dashboardData.includes("useCommandDiagnostics"), false);
  assert.equal(initialLoad.includes("getCommandDiagnosticsSnapshot"), false);
});

test("dashboard precise data refreshes every three minutes when visible and five minutes in background", async () => {
  const dashboardData = await readFile(new URL("../state/useDashboardData.ts", import.meta.url), "utf8");

  assert.equal(dashboardData.includes("DASHBOARD_VISIBLE_AUTO_REFRESH_INTERVAL_MS = 3 * 60 * 1000"), true);
  assert.equal(dashboardData.includes("DASHBOARD_BACKGROUND_AUTO_REFRESH_INTERVAL_MS = 5 * 60 * 1000"), true);
  assert.equal(dashboardData.includes("document.visibilityState"), true);
  assert.equal(dashboardData.includes("window.setInterval"), true);
  assert.equal(dashboardData.includes("setLoadGeneration((current) => current + 1)"), true);
});

test("live activity temporarily accelerates usage refresh cadence", async () => {
  const dashboardData = await readFile(new URL("../state/useDashboardData.ts", import.meta.url), "utf8");
  const compactSnapshot = await readFile(new URL("../surfaces/useCompactPanelSnapshot.ts", import.meta.url), "utf8");
  const cadence = await readFile(new URL("../utils/usageRefreshCadence.ts", import.meta.url), "utf8");

  assert.equal(cadence.includes("ACTIVE_USAGE_REFRESH_INTERVAL_MS = 30_000"), true);
  assert.equal(cadence.includes("LIVE_USAGE_ACTIVITY_HOLD_MS = 31_000"), true);
  assert.equal(cadence.includes("liveRateHasUsageRefreshActivity"), true);
  assert.equal(cadence.includes("usageRefreshIntervalMs"), true);
  assert.equal(dashboardData.includes("markLiveUsageActivity(liveRate)"), true);
  assert.equal(dashboardData.includes("usageRefreshIntervalMs({"), true);
  assert.equal(compactSnapshot.includes("markLiveUsageActivity(liveRate)"), true);
  assert.equal(compactSnapshot.includes("usageRefreshIntervalMs({"), true);
});

test("dashboard quota refreshes independently every five minutes", async () => {
  const dashboardData = await readFile(new URL("../state/useDashboardData.ts", import.meta.url), "utf8");
  const dashboardClient = await readFile(new URL("../api/dashboardClient.ts", import.meta.url), "utf8");
  const deferredLoads = await readFile(new URL("../state/useDeferredDashboardLoads.ts", import.meta.url), "utf8");
  const quotaLoad = await readFile(new URL("../state/useDeferredQuotaLoad.ts", import.meta.url), "utf8");

  assert.equal(dashboardData.includes("QUOTA_AUTO_REFRESH_INTERVAL_MS = 5 * 60 * 1000"), true);
  assert.equal(dashboardData.includes("setQuotaLoadGeneration((current) => current + 1)"), true);
  assert.equal(dashboardData.includes("nextQuotaResetRefreshDelayMs(state.dashboard.quota)"), true);
  assert.equal(dashboardData.includes("setForceNextQuotaLoad(true)"), true);
  assert.equal(dashboardClient.includes("90_000"), true);
  assert.equal(deferredLoads.includes("quotaGeneration"), true);
  assert.equal(quotaLoad.includes("const isFirstQuotaLoad = quotaGeneration.current === null"), true);
});

test("quota warning retry affordance remains wired to the dashboard quota action", async () => {
  const dashboardApp = await readFile(new URL("./DashboardApp.tsx", import.meta.url), "utf8");
  const dashboardPage = await readFile(new URL("../pages/DashboardPage.tsx", import.meta.url), "utf8");
  const summary = await readFile(new URL("../pages/dashboard/DashboardSummarySection.tsx", import.meta.url), "utf8");
  const quotaStrip = await readFile(new URL("../components/QuotaStrip.tsx", import.meta.url), "utf8");

  assert.equal(dashboardApp.includes("onQuotaRefresh={reloadQuota}"), true);
  assert.equal(dashboardPage.includes("onQuotaRefresh={onQuotaRefresh}"), true);
  assert.equal(summary.includes("onRetryQuotaRefresh={onQuotaRefresh}"), true);
  assert.equal(quotaStrip.includes("aria-label=\"只刷新额度\""), true);
});

test("usage cache initialization shows inline notice without blocking dashboard", async () => {
  const dashboardClient = await readFile(new URL("../api/dashboardClient.ts", import.meta.url), "utf8");
  const dataSource = await readFile(new URL("../data/dashboardDataSource.ts", import.meta.url), "utf8");
  const preciseLoad = await readFile(new URL("../state/usePreciseDashboardLoad.ts", import.meta.url), "utf8");
  const dashboardData = await readFile(new URL("../state/useDashboardData.ts", import.meta.url), "utf8");
  const dashboardApp = await readFile(new URL("./DashboardApp.tsx", import.meta.url), "utf8");
  const dashboardPage = await readFile(new URL("../pages/DashboardPage.tsx", import.meta.url), "utf8");
  const styles = await readFile(new URL("../styles/global.css", import.meta.url), "utf8");
  const lib = await readFile(new URL("../../src-tauri/src/lib.rs", import.meta.url), "utf8");

  assert.equal(dashboardClient.includes("read_usage_cache_status"), true);
  assert.equal(dashboardClient.includes("tauri-usage-cache-2026-07-v5"), true);
  assert.equal(dashboardClient.includes("tauri-usage-cache-2026-07-v4"), false);
  assert.equal(dataSource.includes("readUsageCacheStatus"), true);
  assert.equal(preciseLoad.includes("source.readUsageCacheStatus()"), true);
  assert.equal(preciseLoad.includes("onUsageCacheStatus?.(cacheStatus)"), true);
  assert.equal(preciseLoad.includes("onUsageCacheInitialized?.()"), true);
  assert.equal(dashboardData.includes("const [usageCacheInitializing, setUsageCacheInitializing] = useState(false)"), true);
  assert.equal(dashboardData.includes("setUsageCacheInitializing(!status.initialized)"), true);
  assert.equal(dashboardData.includes("usageCacheInitializing,"), true);
  assert.equal(dashboardApp.includes("usageCacheInitializing={usageCacheInitializing}"), true);
  assert.equal(dashboardPage.includes("UsageCacheInitializationNotice"), true);
  assert.equal(dashboardPage.includes("正在初始化本地统计缓存"), true);
  assert.equal(dashboardPage.includes("首次打开或更新后可能需要一点时间，只读取本机 Codex 记录，不上传数据。"), true);
  assert.equal(styles.includes(".usage-cache-notice"), true);
  assert.equal(lib.includes("commands::dashboard::read_usage_cache_status"), true);
});

test("cache hit ranking exposes latest sort affordance", async () => {
  const ranking = await readFile(new URL("../components/CacheHitRanking.tsx", import.meta.url), "utf8");
  const model = await readFile(new URL("../components/cacheHitRanking/model.ts", import.meta.url), "utf8");

  assert.equal(model.includes('sortOrder: CacheRankingSortOrder'), true);
  assert.equal(model.includes('"latest"'), true);
  assert.equal(ranking.includes("setSortOrder"), true);
  assert.equal(ranking.includes("最新"), true);
  assert.equal(ranking.includes("低命中"), true);
});

test("compact surfaces refresh quota every minute", async () => {
  const compactData = await readFile(new URL("../surfaces/useCompactPanelData.ts", import.meta.url), "utf8");
  const compactQuota = await readFile(new URL("../surfaces/useCompactPanelQuota.ts", import.meta.url), "utf8");

  assert.equal(compactData.includes("DEFAULT_QUOTA_INTERVAL_MS = 60_000"), true);
  assert.equal(compactQuota.includes("nextQuotaResetRefreshDelayMs(quota.quota)"), true);
  assert.equal(compactQuota.includes("refreshQuota(true)"), true);
});

test("dashboard and compact quota force refresh after system wake", async () => {
  const dashboardData = await readFile(new URL("../state/useDashboardData.ts", import.meta.url), "utf8");
  const compactQuota = await readFile(new URL("../surfaces/useCompactPanelQuota.ts", import.meta.url), "utf8");
  const wakeRefresh = await readFile(new URL("../utils/useWakeRefresh.ts", import.meta.url), "utf8");

  assert.equal(wakeRefresh.includes("WAKE_REFRESH_GAP_MS = 2 * 60 * 1000"), true);
  assert.equal(wakeRefresh.includes("window.addEventListener(\"focus\", handleWakeCheck)"), true);
  assert.equal(wakeRefresh.includes("document.addEventListener(\"visibilitychange\", handleWakeCheck)"), true);
  assert.equal(dashboardData.includes("useWakeRefresh({"), true);
  assert.equal(dashboardData.includes("makeDashboardWakeRefreshContext({"), true);
  assert.equal(dashboardData.includes("makeDashboardRefreshPlan(\"systemWake\", context)"), true);
  assert.equal(compactQuota.includes("useWakeRefresh({"), true);
  assert.equal(compactQuota.includes("void refreshQuota(true)"), true);
});

test("hidden status panel starts inactive and verifies window visibility before polling", async () => {
  const statusPanel = await readFile(new URL("../status/StatusPanelApp.tsx", import.meta.url), "utf8");

  assert.equal(statusPanel.includes("useState(false)"), true);
  assert.equal(statusPanel.includes("appWindow.isVisible()"), true);
  assert.equal(statusPanel.includes("document.hasFocus()"), true);
  assert.equal(statusPanel.includes("setActive(Boolean(visible) && document.hasFocus())"), true);
});

test("status panel hides itself when focus leaves", async () => {
  const statusPanel = await readFile(new URL("../status/StatusPanelApp.tsx", import.meta.url), "utf8");

  assert.equal(statusPanel.includes("const hideWhenBlurred = () => {"), true);
  assert.equal(statusPanel.includes("setActive(false);"), true);
  assert.equal(statusPanel.includes("desktopPlatform.hideStatusPanelWindow()"), true);
  assert.equal(statusPanel.includes('window.addEventListener("blur", hideWhenBlurred)'), true);
  assert.equal(statusPanel.includes('window.removeEventListener("blur", hideWhenBlurred)'), true);
});

test("status panel controls keep comfortable hit targets", async () => {
  const css = await readFile(new URL("../styles/global.css", import.meta.url), "utf8");
  const closeButton = css.slice(
    css.indexOf(".status-panel-rate-unit button {"),
    css.indexOf(".status-panel-meter {"),
  );
  const actionButton = css.slice(
    css.indexOf(".status-panel-actions button {"),
    css.indexOf("@media (max-width: 960px)"),
  );

  assert.equal(closeButton.includes("width: 28px;"), true);
  assert.equal(closeButton.includes("height: 28px;"), true);
  assert.equal(actionButton.includes("min-height: 34px;"), true);
});

test("status tray live text reuses dashboard live rate instead of polling compact data", async () => {
  const tray = await readFile(new URL("../tray/useStatusTray.ts", import.meta.url), "utf8");
  const displaySettings = await readFile(new URL("./useDisplaySurfaceSettings.ts", import.meta.url), "utf8");
  const shellSettings = await readFile(new URL("./useDashboardShellSettings.ts", import.meta.url), "utf8");
  const dashboardApp = await readFile(new URL("./DashboardApp.tsx", import.meta.url), "utf8");

  assert.equal(tray.includes("useCompactPanelData"), false);
  assert.equal(tray.includes("LiveRateSnapshot"), true);
  assert.equal(displaySettings.includes("liveRate: LiveRateSnapshot"), true);
  assert.equal(displaySettings.includes("useStatusTray("), true);
  assert.equal(displaySettings.includes("liveRate,"), true);
  assert.equal(shellSettings.includes("liveRate: LiveRateSnapshot"), true);
  assert.equal(shellSettings.includes("useDisplaySurfaceSettings({ platform, liveRate })"), true);
  assert.equal(dashboardApp.includes("liveRate: readyState.liveRate"), true);
});

test("live rate switch stops the shared stream and preserves other refreshes", async () => {
  const apiClient = await readFile(new URL("../api/client.ts", import.meta.url), "utf8");
  const dashboardClient = await readFile(new URL("../api/dashboardClient.ts", import.meta.url), "utf8");
  const displaySettings = await readFile(new URL("../settings/displaySettings.ts", import.meta.url), "utf8");
  const dashboardData = await readFile(new URL("../state/useDashboardData.ts", import.meta.url), "utf8");
  const liveFeed = await readFile(new URL("../state/useLiveRateFeed.ts", import.meta.url), "utf8");
  const compactData = await readFile(new URL("../surfaces/useCompactPanelData.ts", import.meta.url), "utf8");
  const compactSnapshot = await readFile(new URL("../surfaces/useCompactPanelSnapshot.ts", import.meta.url), "utf8");
  const floatingWindow = await readFile(new URL("../floating/FloatingWindowApp.tsx", import.meta.url), "utf8");
  const statusPanel = await readFile(new URL("../status/StatusPanelApp.tsx", import.meta.url), "utf8");
  const card = await readFile(new URL("../components/LiveRateCard.tsx", import.meta.url), "utf8");
  const shellSettings = await readFile(new URL("./useDashboardShellSettings.ts", import.meta.url), "utf8");
  const styles = await readFile(new URL("../styles/global.css", import.meta.url), "utf8");

  assert.equal(displaySettings.includes("liveRateEnabled: true"), true);
  assert.equal(dashboardData.includes("active: fastSnapshotLoaded && liveRateEnabled"), true);
  assert.equal(dashboardData.includes("disabledLiveRateSnapshot(selectedLiveThreadId)"), true);
  assert.equal(apiClient.includes("readUsageSummarySnapshot"), true);
  assert.equal(dashboardClient.includes("read_usage_summary_snapshot"), true);
  assert.equal(liveFeed.includes("stopLiveRateStream"), true);
  assert.equal(liveFeed.includes("resetLiveRateMonitor"), true);
  assert.equal(compactData.includes("active,"), true);
  assert.equal(compactData.includes("liveRateEnabled,"), true);
  assert.equal(compactData.includes("active: active && liveRateEnabled"), false);
  assert.equal(compactSnapshot.includes("readUsageSummarySnapshot"), true);
  assert.equal(compactSnapshot.includes("mergeFloatingUsageSummary"), true);
  assert.equal(floatingWindow.includes("onDisplaySurfacesChanged"), true);
  assert.equal(statusPanel.includes("onDisplaySurfacesChanged"), true);
  assert.equal(card.includes("实时速率已关闭"), true);
  assert.equal(card.includes("is-live-disabled"), true);
  assert.equal(card.includes("官方为减少磁盘写入关闭了部分流式日志"), true);
  assert.equal(card.includes("<LiveRateSessionRow"), false);
  assert.equal(card.includes("LiveRateSessionRow"), false);
  assert.equal(card.includes("live-heading-line"), true);
  assert.equal(shellSettings.includes("showRateAndBar: nextEnabled"), true);
  assert.match(styles, /\.live-left\.is-live-disabled::after\s*{[\s\S]*?content: "实时速率已关闭";[\s\S]*?pointer-events: none;/);
  assert.match(styles, /\.live-heading-line\s*{[\s\S]*?display: flex;[\s\S]*?align-items: center;/);
});

test("live rate surfaces subscribe to the shared stream instead of polling snapshots", async () => {
  const liveFeed = await readFile(new URL("../state/useLiveRateFeed.ts", import.meta.url), "utf8");
  const compactSnapshot = await readFile(new URL("../surfaces/useCompactPanelSnapshot.ts", import.meta.url), "utf8");
  const surfaceCommands = await readFile(new URL("../platform/surfaceCommands.ts", import.meta.url), "utf8");

  for (const source of [liveFeed, compactSnapshot, surfaceCommands]) {
    assert.equal(source.includes("startLiveRateStream"), true);
  }

  for (const source of [liveFeed, compactSnapshot]) {
    assert.equal(source.includes("onLiveRateSnapshot"), true);
    assert.equal(source.includes("window.setTimeout"), false);
    assert.equal(source.includes("window.setInterval"), false);
  }

  assert.equal(compactSnapshot.includes("readFloatingPanelSnapshot"), false);
  assert.equal(surfaceCommands.includes("controlsSelectedThread"), true);
});

test("live rate card exposes Swift-style reset action", async () => {
  const liveClient = await readFile(new URL("../api/liveClient.ts", import.meta.url), "utf8");
  const apiClient = await readFile(new URL("../api/client.ts", import.meta.url), "utf8");
  const dashboardApp = await readFile(new URL("./DashboardApp.tsx", import.meta.url), "utf8");
  const dashboardPage = await readFile(new URL("../pages/DashboardPage.tsx", import.meta.url), "utf8");
  const card = await readFile(new URL("../components/LiveRateCard.tsx", import.meta.url), "utf8");

  assert.equal(liveClient.includes("resetLiveRateMonitor"), true);
  assert.equal(liveClient.includes('"reset_live_rate_monitor"'), true);
  assert.equal(apiClient.includes("resetLiveRateMonitor"), true);
  assert.equal(dashboardApp.includes("onLiveRateReset={resetLiveRate}"), true);
  assert.equal(dashboardPage.includes("onLiveRateReset"), true);
  assert.equal(card.includes("重置整体速率"), true);
});

test("manual dashboard refresh keeps the current snapshot visible", async () => {
  const actions = await readFile(new URL("../state/useDashboardActions.ts", import.meta.url), "utf8");
  const reloadAll = actions.slice(
    actions.indexOf("const reloadAll ="),
    actions.indexOf("const updateCodexHome ="),
  );
  const reloadInitialSnapshot = actions.slice(
    actions.indexOf("const reloadInitialSnapshot ="),
    actions.indexOf("const reloadAll ="),
  );

  assert.equal(reloadAll.includes("makeDashboardRefreshPlan(\"manual\""), true);
  assert.equal(reloadAll.includes("applyDashboardRefreshPlan(plan"), true);
  assert.equal(reloadAll.includes("setFastSnapshotLoaded(false)"), false);
  assert.equal(reloadAll.includes("loading: true"), false);
  assert.equal(reloadAll.includes("loadInitialDashboardState"), false);
  assert.equal(reloadInitialSnapshot.includes("setFastSnapshotLoaded(false)"), true);
  assert.equal(reloadInitialSnapshot.includes("loadInitialDashboardState"), true);
});

test("codex radar refresh generation remains wired to the summary strip", async () => {
  const dashboardApp = await readFile(new URL("./DashboardApp.tsx", import.meta.url), "utf8");
  const dashboardPage = await readFile(new URL("../pages/DashboardPage.tsx", import.meta.url), "utf8");
  const summarySection = await readFile(new URL("../pages/dashboard/DashboardSummarySection.tsx", import.meta.url), "utf8");
  const radarStrip = await readFile(new URL("../components/CodexRadarStrip.tsx", import.meta.url), "utf8");

  assert.equal(dashboardApp.includes("radarRefreshGeneration={radarRefreshGeneration}"), true);
  assert.equal(dashboardPage.includes("radarRefreshGeneration: number"), true);
  assert.equal(summarySection.includes("<CodexRadarStrip refreshGeneration={radarRefreshGeneration} />"), true);
  assert.equal(radarStrip.includes("interface CodexRadarStripProps"), true);
  assert.equal(radarStrip.includes("readCodexRadarSnapshot({ force })"), true);
  assert.equal(radarStrip.includes("void refresh(true)"), true);
});

test("windows updater lane uses signed Tauri metadata and a dashboard entry", async () => {
  const packageJson = await readFile(new URL("../../package.json", import.meta.url), "utf8");
  const cargoToml = await readFile(new URL("../../src-tauri/Cargo.toml", import.meta.url), "utf8");
  const tauriConfig = await readFile(new URL("../../src-tauri/tauri.conf.json", import.meta.url), "utf8");
  const lib = await readFile(new URL("../../src-tauri/src/lib.rs", import.meta.url), "utf8");
  const capability = await readFile(new URL("../../src-tauri/capabilities/default.json", import.meta.url), "utf8");
  const updateClient = await readFile(new URL("../api/updateClient.ts", import.meta.url), "utf8");
  const dashboardApp = await readFile(new URL("./DashboardApp.tsx", import.meta.url), "utf8");
  const dashboardPage = await readFile(new URL("../pages/DashboardPage.tsx", import.meta.url), "utf8");
  const header = await readFile(new URL("../components/DashboardHeader.tsx", import.meta.url), "utf8");
  const buildScript = await readFile(new URL("../../../scripts/build_tauri_windows_release.ps1", import.meta.url), "utf8");

  assert.equal(packageJson.includes('"@tauri-apps/plugin-updater"'), true);
  assert.equal(packageJson.includes('"@tauri-apps/plugin-process"'), true);
  assert.equal(cargoToml.includes("tauri-plugin-updater"), true);
  assert.equal(cargoToml.includes("tauri-plugin-process"), true);
  assert.equal(tauriConfig.includes('"createUpdaterArtifacts": true'), true);
  assert.equal(tauriConfig.includes("latest-windows.json"), true);
  assert.equal(tauriConfig.includes('"installMode": "passive"'), true);
  assert.equal(lib.includes("tauri_plugin_updater::Builder::new().build()"), true);
  assert.equal(lib.includes("tauri_plugin_process::init()"), true);
  assert.equal(capability.includes("updater:default"), true);
  assert.equal(capability.includes("process:allow-restart"), true);
  assert.equal(updateClient.includes("checkAppUpdate"), true);
  assert.equal(updateClient.includes("installAppUpdate"), true);
  assert.equal(updateClient.includes("downloadAndInstall"), true);
  assert.equal(updateClient.includes("relaunch()"), true);
  assert.equal(dashboardApp.includes("useStartupUpdateCheck"), true);
  assert.equal(dashboardPage.includes("onCheckForUpdate"), true);
  assert.equal(header.includes("检查更新"), true);
  assert.equal(header.includes("安装更新"), true);
  assert.equal(buildScript.includes("TAURI_SIGNING_PRIVATE_KEY_PATH"), true);
  assert.equal(buildScript.includes(".sig"), true);
  assert.equal(buildScript.includes("latest-windows.json"), true);
  assert.equal(buildScript.includes("windows-x86_64"), true);
  assert.equal(buildScript.includes("windows-aarch64"), true);
});

test("live rate updates do not force heavy analytics rerenders", async () => {
  const analyticsSection = await readFile(
    new URL("../pages/dashboard/DashboardAnalyticsSection.tsx", import.meta.url),
    "utf8",
  );
  const dashboardData = await readFile(new URL("../state/useDashboardData.ts", import.meta.url), "utf8");

  assert.equal(analyticsSection.includes("memo("), true);
  assert.equal(analyticsSection.includes("DashboardAnalyticsSectionView"), true);
  assert.equal(dashboardData.includes("startTransition"), true);
  assert.equal(dashboardData.includes("mergePreciseDashboard(current, precise)"), true);
  assert.equal(dashboardData.includes("mergeQuota(current, quota)"), true);
});

test("dashboard records frontend commit cost for refresh payloads", async () => {
  const dashboardData = await readFile(new URL("../state/useDashboardData.ts", import.meta.url), "utf8");
  const startupClient = await readFile(new URL("../api/startupClient.ts", import.meta.url), "utf8");
  const startupCommand = await readFile(
    new URL("../../src-tauri/src/commands/startup.rs", import.meta.url),
    "utf8",
  );
  const lib = await readFile(new URL("../../src-tauri/src/lib.rs", import.meta.url), "utf8");

  assert.equal(startupClient.includes("recordPerformanceEvent"), true);
  assert.equal(startupCommand.includes("record_performance_event"), true);
  assert.equal(startupCommand.includes("startup_trace::mark_performance"), true);
  assert.equal(lib.includes("commands::startup::record_performance_event"), true);
  assert.equal(dashboardData.includes("useRenderCommitPerformanceTrace"), true);
  assert.equal(dashboardData.includes('"frontend precise dashboard"'), true);
  assert.equal(dashboardData.includes('"frontend quota dashboard"'), true);
  assert.equal(dashboardData.includes("recordPerformanceEvent(`${pending.label} commit ${elapsedMs}ms`)"), true);
});

test("debug launcher stages a runnable app and stops stale debug instances", async () => {
  const script = await readFile(
    new URL("../../../scripts/open_tauri_debug_app.sh", import.meta.url),
    "utf8",
  );

  assert.equal(script.includes("stop_other_debug_apps"), true);
  assert.equal(script.includes("wait_for_debug_apps_to_stop"), true);
  assert.match(script, /stop_other_debug_apps\s*\n\s*wait_for_debug_apps_to_stop/);
  assert.equal(script.includes("stage_runnable_app"), true);
  assert.equal(script.includes("target/debug/run-bundle"), true);
});

test("compact floating data shows quota pace label instead of generic output status", async () => {
  const compactData = await readFile(new URL("../surfaces/useCompactPanelData.ts", import.meta.url), "utf8");
  const liveRate = await readFile(new URL("../../src-tauri/src/core/live_rate.rs", import.meta.url), "utf8");

  assert.equal(compactData.includes("quota.quota.paceLabel"), true);
  assert.equal(compactData.includes("trendLabel: compactPaceLabel"), true);
  assert.equal(liveRate.includes("输出中"), false);
});

test("dark dashboard stats follow Swift dark panel instead of white gradient", async () => {
  const css = await readFile(new URL("../styles/global.css", import.meta.url), "utf8");
  const statsBlock = css.slice(css.indexOf(".stats-strip {"), css.indexOf(".stats-cell {"));

  assert.equal(statsBlock.includes("rgba(255, 255, 255, 0.78)"), false);
  assert.equal(statsBlock.includes("background: var(--panel);"), true);
  assert.equal(css.includes("html:not(.floating-document):not(.status-document) .app-shell"), true);
});
