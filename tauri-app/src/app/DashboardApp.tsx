import { useEffect, useRef, useState } from "react";
import { recordStartupEvent } from "../api/client";
import { resetLiveRateMonitor } from "../api/liveClient";
import {
  checkAppUpdate,
  installAppUpdate,
  listenForAppUpdateState,
  manualUpdateFailureMessage,
  readCachedAppUpdate,
  type UpdateAvailability,
} from "../api/updateClient";
import { SetupGuide } from "../components/SetupGuide";
import { DashboardPage } from "../pages/DashboardPage";
import { useDashboardData } from "../state/useDashboardData";
import { useDashboardShellSettings } from "./useDashboardShellSettings";
import { mountUpdateStateReconciler } from "./updateStateReconciler";
import { useThreadDeleteBridge } from "./useThreadDeleteBridge";

type AppUpdateState =
  | { kind: "idle"; message: string; update: null }
  | { kind: "checking"; message: string; update: null }
  | { kind: "available"; message: string; update: UpdateAvailability & { status: "available" } }
  | { kind: "installing"; message: string; update: UpdateAvailability & { status: "available" } }
  | { kind: "error"; message: string; update: null };

export function DashboardApp() {
  const [dashboardHydrated, setDashboardHydrated] = useState(false);
  const [liveRateEnabled, setLiveRateEnabled] = useState(true);
  const [providerRepairOpen, setProviderRepairOpen] = useState(false);
  const [appUpdateState, setAppUpdateState] = useState<AppUpdateState>({
    kind: "idle",
    message: "",
    update: null,
  });
  useDashboardHydration(setDashboardHydrated);
  useDashboardScrollReset();
  useAppUpdateState(appUpdateState, setAppUpdateState);

  const {
    state,
    readyState,
    refreshing,
    usageCacheInitializing,
    radarRefreshGeneration,
    reloadAll,
    acknowledgeUnread,
    retryLiveRateStream,
    updateCodexHome,
    restoreAutoCodexHome,
    reloadQuota,
    updateProviderRepair,
    providerSourceKey,
    selectedLiveThreadId,
    setSelectedLiveThreadId,
  } = useDashboardData({
    liveRateEnabled,
    providerRepairVisible: providerRepairOpen,
  });
  const shellSettings = useDashboardShellSettings({
    dashboardHydrated,
    platform: state.platform,
  });
  const threadDeleteBridge = useThreadDeleteBridge();

  useEffect(() => {
    setLiveRateEnabled(shellSettings.displaySurfaces.liveRateEnabled);
  }, [shellSettings.displaySurfaces.liveRateEnabled]);

  return (
    <>
      <DashboardPage
        autostartStatus={shellSettings.autostartStatus}
        codexHome={readyState.codexHome}
        dashboard={readyState.dashboard}
        displaySurfaces={shellSettings.displaySurfaces}
        floatingSettings={shellSettings.floatingSettings}
        customAccountDisplayName={shellSettings.customAccountDisplayName}
        quotaRefreshIntervalMs={shellSettings.quotaRefreshIntervalMs}
        liveRate={readyState.liveRate}
        liveThreadOptions={readyState.liveThreadOptions}
        platform={readyState.platform}
        onRefresh={reloadAll}
        usageCacheInitializing={usageCacheInitializing}
        radarRefreshGeneration={radarRefreshGeneration}
        onFloatingOpacityChange={shellSettings.updateFloatingOpacity}
        onFloatingScaleChange={shellSettings.updateFloatingScale}
        onTokenRateFullScaleChange={shellSettings.updateTokenRateFullScale}
        onFloatingUnreadEffectChange={shellSettings.updateFloatingUnreadEffect}
        onFloatingGradientChange={shellSettings.updateFloatingGradient}
        onFloatingTextToneChange={shellSettings.updateFloatingTextTone}
        onFloatingContentVisibilityChange={shellSettings.updateFloatingContentVisibility}
        onLiveRateReset={resetLiveRate}
        onLiveRateRetry={retryLiveRateStream}
        onAcknowledgeUnread={acknowledgeUnread}
        onLiveThreadSelect={setSelectedLiveThreadId}
        onProviderRepairClose={() => setProviderRepairOpen(false)}
        onProviderRepairOpen={() => setProviderRepairOpen(true)}
        onProviderRepairSnapshotChange={updateProviderRepair}
        onQuotaRefresh={reloadQuota}
        onQuotaRefreshIntervalChange={shellSettings.updateQuotaRefreshIntervalMs}
        onToggleLiveRate={shellSettings.toggleLiveRate}
        onToggleFloating={shellSettings.toggleFloatingWindow}
        onToggleStatusTray={shellSettings.toggleStatusTrayLiveText}
        providerRepairOpen={providerRepairOpen}
        providerRepairSnapshot={readyState.repair}
        providerSourceKey={providerSourceKey}
        onCodexHomeChange={updateCodexHome}
        onCodexHomeReset={restoreAutoCodexHome}
        onCustomAccountDisplayNameChange={shellSettings.updateCustomAccountDisplayName}
        onCheckForUpdate={() => handleCheckForUpdate(
          appUpdateState,
          setAppUpdateState,
        )}
        onToggleAutostart={shellSettings.toggleAutostart}
        onReconnectThreadDelete={threadDeleteBridge.activate}
        refreshing={refreshing}
        appUpdateState={appUpdateState}
        threadDeleteBridgeStatus={threadDeleteBridge.status}
        liveRateEnabled={shellSettings.displaySurfaces.liveRateEnabled}
        selectedLiveThreadId={selectedLiveThreadId}
      />
      {shellSettings.showSetupGuide ? (
        <SetupGuide
          codexHome={readyState.codexHome}
          autostartStatus={shellSettings.autostartStatus}
          displaySurfaces={shellSettings.displaySurfaces}
          platform={readyState.platform}
          statusTrayLiveTextEnabled={shellSettings.displaySurfaces.statusTrayLiveTextEnabled}
          onCodexHomeChange={updateCodexHome}
          onCodexHomeReset={restoreAutoCodexHome}
          onComplete={shellSettings.completeSetupGuide}
          onToggleAutostart={shellSettings.toggleAutostart}
          onToggleFloating={shellSettings.toggleFloatingWindow}
          onToggleStatusTray={shellSettings.toggleStatusTrayLiveText}
        />
      ) : null}
    </>
  );
}

async function resetLiveRate() {
  await resetLiveRateMonitor();
}

function useAppUpdateState(
  appUpdateState: AppUpdateState,
  setAppUpdateState: (state: AppUpdateState) => void,
) {
  const phaseRef = useRef(appUpdateState.kind);
  phaseRef.current = appUpdateState.kind;
  useEffect(() => {
    return mountUpdateStateReconciler({
      read: readCachedAppUpdate,
      listen: listenForAppUpdateState,
      phase: () => phaseRef.current,
      publish: result => {
        if (result.status === "available") {
          setAppUpdateState({ kind: "available", message: result.message ?? `发现新版本 ${result.version}`, update: result });
        } else if (result.status === "none") {
          setAppUpdateState({ kind: "idle", message: result.message, update: null });
        }
      },
    });
  }, [setAppUpdateState]);
}

async function handleCheckForUpdate(
  appUpdateState: AppUpdateState,
  setAppUpdateState: (state: AppUpdateState) => void,
) {
  if (appUpdateState.kind === "available" && appUpdateState.update) {
    const confirmed = window.confirm(`安装 Codex Token Bar ${appUpdateState.update.version} 更新？安装时应用会自动重启。`);
    if (confirmed) await installConfirmedUpdate(appUpdateState.update, setAppUpdateState);
    return;
  }

  setAppUpdateState({ kind: "checking", message: "正在检查更新...", update: null });
  try {
    const result = await checkAppUpdate();
    if (result.status === "available") {
      setAppUpdateState({
        kind: "available",
        message: `发现新版本 ${result.version}`,
        update: result,
      });
      const confirmed = window.confirm(`发现 Codex Token Bar ${result.version}。现在下载并安装吗？`);
      if (confirmed) await installConfirmedUpdate(result, setAppUpdateState);
      return;
    }
    setAppUpdateState({
      kind: "idle",
      message: result.message,
      update: null,
    });
  } catch (error) {
    setAppUpdateState({
      kind: "error",
      message: manualUpdateFailureMessage(error),
      update: null,
    });
  }
}

async function installConfirmedUpdate(
  update: Extract<UpdateAvailability, { status: "available" }>,
  setAppUpdateState: (state: AppUpdateState) => void,
) {
  setAppUpdateState({ kind: "installing", message: "正在下载更新...", update });
  try {
    await installAppUpdate(update.version, message => {
      setAppUpdateState({ kind: "installing", message, update });
    });
  } catch {
    setAppUpdateState({ kind: "error", message: "更新未完成，请稍后重试", update: null });
  }
}

function useDashboardHydration(setDashboardHydrated: (hydrated: boolean) => void) {
  useEffect(() => {
    void recordStartupEvent("dashboard mounted");
  }, []);

  useEffect(() => {
    let cancelled = false;

    queueMicrotask(() => {
      if (!cancelled) {
        setDashboardHydrated(true);
        void recordStartupEvent("dashboard hydrate full ui");
      }
    });

    return () => {
      cancelled = true;
    };
  }, [setDashboardHydrated]);
}

function useDashboardScrollReset() {
  useEffect(() => {
    if ("scrollRestoration" in window.history) {
      window.history.scrollRestoration = "manual";
    }

    const scrollToTop = () => window.scrollTo(0, 0);
    scrollToTop();
    window.requestAnimationFrame(scrollToTop);
    const firstTimer = window.setTimeout(scrollToTop, 250);
    const secondTimer = window.setTimeout(scrollToTop, 1_000);

    return () => {
      window.clearTimeout(firstTimer);
      window.clearTimeout(secondTimer);
    };
  }, []);
}
