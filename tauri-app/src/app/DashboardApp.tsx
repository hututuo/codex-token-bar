import { useEffect, useState } from "react";
import { recordStartupEvent } from "../api/client";
import { resetLiveRateMonitor } from "../api/liveClient";
import { SetupGuide } from "../components/SetupGuide";
import { DashboardPage } from "../pages/DashboardPage";
import { useDashboardData } from "../state/useDashboardData";
import { useDashboardShellSettings } from "./useDashboardShellSettings";

export function DashboardApp() {
  const [dashboardHydrated, setDashboardHydrated] = useState(false);
  const [liveRateEnabled, setLiveRateEnabled] = useState(true);

  useDashboardHydration(setDashboardHydrated);
  useDashboardScrollReset();

  const {
    state,
    readyState,
    refreshing,
    usageCacheInitializing,
    radarRefreshGeneration,
    reloadAll,
    updateCodexHome,
    restoreAutoCodexHome,
    reloadQuota,
    selectedLiveThreadId,
    setSelectedLiveThreadId,
  } = useDashboardData({ liveRateEnabled });
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
        onLiveThreadSelect={setSelectedLiveThreadId}
        onQuotaRefresh={reloadQuota}
        onToggleLiveRate={shellSettings.toggleLiveRate}
        onToggleFloating={shellSettings.toggleFloatingWindow}
        onToggleStatusTray={shellSettings.toggleStatusTrayLiveText}
        onCodexHomeChange={updateCodexHome}
        onCodexHomeReset={restoreAutoCodexHome}
        onCustomAccountDisplayNameChange={shellSettings.updateCustomAccountDisplayName}
        onToggleAutostart={shellSettings.toggleAutostart}
        refreshing={refreshing}
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
