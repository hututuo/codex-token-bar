import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("dashboard header does not render the local diagnostics strip", async () => {
  const header = await readFile(new URL("../components/DashboardHeader.tsx", import.meta.url), "utf8");

  assert.equal(header.includes("DiagnosticStrip"), false);
  assert.equal(header.includes("diagnostic-strip"), false);
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

test("dashboard quota refreshes independently every minute", async () => {
  const dashboardData = await readFile(new URL("../state/useDashboardData.ts", import.meta.url), "utf8");
  const deferredLoads = await readFile(new URL("../state/useDeferredDashboardLoads.ts", import.meta.url), "utf8");
  const quotaLoad = await readFile(new URL("../state/useDeferredQuotaLoad.ts", import.meta.url), "utf8");

  assert.equal(dashboardData.includes("QUOTA_AUTO_REFRESH_INTERVAL_MS = 60 * 1000"), true);
  assert.equal(dashboardData.includes("setQuotaLoadGeneration((current) => current + 1)"), true);
  assert.equal(deferredLoads.includes("quotaGeneration"), true);
  assert.equal(quotaLoad.includes("const isFirstQuotaLoad = quotaGeneration.current === null"), true);
});

test("compact surfaces refresh quota every minute", async () => {
  const compactData = await readFile(new URL("../surfaces/useCompactPanelData.ts", import.meta.url), "utf8");

  assert.equal(compactData.includes("DEFAULT_QUOTA_INTERVAL_MS = 60_000"), true);
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
