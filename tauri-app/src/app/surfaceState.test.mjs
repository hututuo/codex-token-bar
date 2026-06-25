import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("dashboard header does not render the local diagnostics strip", async () => {
  const header = await readFile(new URL("../components/DashboardHeader.tsx", import.meta.url), "utf8");

  assert.equal(header.includes("DiagnosticStrip"), false);
  assert.equal(header.includes("diagnostic-strip"), false);
});

test("dashboard header supports Swift-style editable account display name", async () => {
  const header = await readFile(new URL("../components/DashboardHeader.tsx", import.meta.url), "utf8");
  const shellSettings = await readFile(new URL("./useDashboardShellSettings.ts", import.meta.url), "utf8");
  const settingsClient = await readFile(new URL("../api/settingsClient.ts", import.meta.url), "utf8");

  assert.equal(header.includes("customAccountDisplayName"), true);
  assert.equal(header.includes("onCustomAccountDisplayNameChange"), true);
  assert.equal(header.includes("account-name-edit"), true);
  assert.equal(header.includes("onBlur={commitDisplayName}"), true);
  assert.equal(header.includes("onKeyDown={handleDisplayNameKeyDown}"), true);
  assert.equal(header.includes("✎"), true);
  assert.equal(shellSettings.includes("saveCustomAccountDisplayName"), true);
  assert.equal(settingsClient.includes("save_custom_account_display_name"), true);
});

test("floating toggle follows saved preference instead of transient visibility", async () => {
  const hook = await readFile(new URL("./useFloatingWindowSurface.ts", import.meta.url), "utf8");
  const toggleBody = hook.slice(hook.indexOf("const toggleFloatingWindow"));

  assert.equal(toggleBody.includes("const nextEnabled = !enabled"), true);
  assert.equal(toggleBody.includes("const nextVisible = !floatingVisible"), false);
  assert.equal(toggleBody.includes("onPreferenceConfirmed(nextEnabled)"), false);
  assert.equal(toggleBody.includes("setFloatingVisible(nextEnabled)"), false);
  assert.equal(toggleBody.includes("onPreferenceConfirmed(nextVisible)"), true);
  assert.equal(toggleBody.includes("setFloatingVisible(nextVisible)"), true);
});

test("floating hidden event also turns off saved preference", async () => {
  const hook = await readFile(new URL("./useFloatingWindowSurface.ts", import.meta.url), "utf8");
  const hiddenHandler = hook.slice(
    hook.indexOf("desktopPlatform.onFloatingWindowHidden"),
    hook.indexOf("}).then((listener)"),
  );

  assert.equal(hiddenHandler.includes("setFloatingVisible(false)"), true);
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
    hiddenHandler.includes("if (!settingsReadyRef.current || !enabledPreferenceRef.current)"),
    true,
  );
});

test("startup floating apply does not rewrite saved preference when show returns false", async () => {
  const hook = await readFile(new URL("./useFloatingWindowSurface.ts", import.meta.url), "utf8");
  const applyEffect = hook.slice(
    hook.indexOf("async function applyFloatingPreference"),
    hook.indexOf("const toggleFloatingWindow"),
  );

  assert.equal(applyEffect.includes("setFloatingVisible(nextVisible)"), true);
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

test("dashboard quota refreshes independently every five minutes", async () => {
  const dashboardData = await readFile(new URL("../state/useDashboardData.ts", import.meta.url), "utf8");
  const deferredLoads = await readFile(new URL("../state/useDeferredDashboardLoads.ts", import.meta.url), "utf8");
  const quotaLoad = await readFile(new URL("../state/useDeferredQuotaLoad.ts", import.meta.url), "utf8");

  assert.equal(dashboardData.includes("QUOTA_AUTO_REFRESH_INTERVAL_MS = 5 * 60 * 1000"), true);
  assert.equal(dashboardData.includes("setQuotaLoadGeneration((current) => current + 1)"), true);
  assert.equal(deferredLoads.includes("quotaGeneration"), true);
  assert.equal(quotaLoad.includes("const isFirstQuotaLoad = quotaGeneration.current === null"), true);
});

test("compact surfaces refresh quota every minute", async () => {
  const compactData = await readFile(new URL("../surfaces/useCompactPanelData.ts", import.meta.url), "utf8");

  assert.equal(compactData.includes("DEFAULT_QUOTA_INTERVAL_MS = 60_000"), true);
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

test("live polling follows Swift fast-active idle cadence", async () => {
  const liveFeed = await readFile(new URL("../state/useLiveRateFeed.ts", import.meta.url), "utf8");
  const compactSnapshot = await readFile(new URL("../surfaces/useCompactPanelSnapshot.ts", import.meta.url), "utf8");

  for (const source of [liveFeed, compactSnapshot]) {
    assert.equal(source.includes("FAST_LIVE_POLL_INTERVAL_MS = 250"), true);
    assert.equal(source.includes("IDLE_LIVE_POLL_INTERVAL_MS = 1_000"), true);
    assert.equal(source.includes("nextLivePollInterval"), true);
    assert.equal(source.includes("window.setTimeout"), true);
    assert.equal(source.includes("window.setInterval"), false);
  }
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

  assert.equal(reloadAll.includes("setLoadGeneration((current) => current + 1)"), true);
  assert.equal(reloadAll.includes("setQuotaLoadGeneration((current) => current + 1)"), true);
  assert.equal(reloadAll.includes("setForceNextQuotaLoad(true)"), true);
  assert.equal(reloadAll.includes("setFastSnapshotLoaded(false)"), false);
  assert.equal(reloadAll.includes("loading: true"), false);
  assert.equal(reloadAll.includes("loadInitialDashboardState"), false);
  assert.equal(reloadInitialSnapshot.includes("setFastSnapshotLoaded(false)"), true);
  assert.equal(reloadInitialSnapshot.includes("loadInitialDashboardState"), true);
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
