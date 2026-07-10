import { useEffect, useState } from "react";
import { recordStartupEvent } from "../api/client";
import { resetLiveRateMonitor } from "../api/liveClient";
import { checkAppUpdate, installAppUpdate, type UpdateAvailability } from "../api/updateClient";
import { SetupGuide } from "../components/SetupGuide";
import { DashboardPage } from "../pages/DashboardPage";
import { useDashboardData } from "../state/useDashboardData";
import { useDashboardShellSettings } from "./useDashboardShellSettings";

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
  useStartupUpdateCheck(setAppUpdateState);

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
    liveRate: readyState.liveRate,
    platform: state.platform,
  });

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
        onCheckForUpdate={() => handleCheckForUpdate(appUpdateState, setAppUpdateState)}
        onToggleAutostart={shellSettings.toggleAutostart}
        refreshing={refreshing}
        appUpdateState={appUpdateState}
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

function useStartupUpdateCheck(setAppUpdateState: (state: AppUpdateState) => void) {
  useEffect(() => {
    let cancelled = false;
    const timer = window.setTimeout(() => {
      void checkAppUpdate()
        .then((result) => {
          if (cancelled || result.status !== "available") {
            return;
          }
          setAppUpdateState({
            kind: "available",
            message: `发现新版本 ${result.version}`,
            update: result,
          });
        })
        .catch(() => {
          // Startup checks stay quiet; the manual button reports detailed failures.
        });
    }, 5_000);

    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
  }, [setAppUpdateState]);
}

async function handleCheckForUpdate(
  appUpdateState: AppUpdateState,
  setAppUpdateState: (state: AppUpdateState) => void,
) {
  if (appUpdateState.kind === "available" && appUpdateState.update) {
    const confirmed = window.confirm(`安装 Codex Token Bar ${appUpdateState.update.version} 更新？安装时应用会自动重启。`);
    if (!confirmed) {
      return;
    }
    await installPendingUpdate(appUpdateState.update, setAppUpdateState);
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
      if (confirmed) {
        await installPendingUpdate(result, setAppUpdateState);
      }
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
      message: updateErrorMessage(error),
      update: null,
    });
  }
}

async function installPendingUpdate(
  update: UpdateAvailability & { status: "available" },
  setAppUpdateState: (state: AppUpdateState) => void,
) {
  setAppUpdateState({
    kind: "installing",
    message: "正在下载更新...",
    update,
  });
  try {
    await installAppUpdate(update.update, (message) => {
      setAppUpdateState({
        kind: "installing",
        message,
        update,
      });
    });
  } catch (error) {
    setAppUpdateState({
      kind: "error",
      message: updateErrorMessage(error),
      update: null,
    });
  }
}

function updateErrorMessage(error: unknown): string {
  if (error instanceof Error && error.message.trim()) {
    return `检查更新失败：${error.message}`;
  }
  if (typeof error === "string" && error.trim()) {
    return `检查更新失败：${error}`;
  }
  return "检查更新失败，请稍后重试。";
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
