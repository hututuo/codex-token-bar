import { useEffect, useState } from "react";
import { recordStartupEvent } from "../api/client";
import { SetupGuide } from "../components/SetupGuide";
import { DashboardPage } from "../pages/DashboardPage";
import { useDashboardData } from "../state/useDashboardData";
import { useDashboardShellSettings } from "./useDashboardShellSettings";

export function DashboardApp() {
  const [dashboardHydrated, setDashboardHydrated] = useState(false);

  useDashboardHydration(setDashboardHydrated);
  useDashboardScrollReset();

  const {
    state,
    readyState,
    reloadAll,
    updateCodexHome,
    restoreAutoCodexHome,
    updateProviderRepair,
    selectedLiveThreadId,
    setSelectedLiveThreadId,
  } = useDashboardData();
  const shellSettings = useDashboardShellSettings({
    dashboardHydrated,
    platform: state.platform,
  });

  return (
    <>
      <DashboardPage
        autostartStatus={shellSettings.autostartStatus}
        codexHome={readyState.codexHome}
        dashboard={readyState.dashboard}
        diagnostics={readyState.diagnostics}
        displaySurfaces={shellSettings.displaySurfaces}
        floatingSettings={shellSettings.floatingSettings}
        floatingVisible={shellSettings.floatingVisible}
        liveRate={readyState.liveRate}
        liveThreadOptions={readyState.liveThreadOptions}
        platform={readyState.platform}
        onRefresh={reloadAll}
        onFloatingOpacityChange={shellSettings.updateFloatingOpacity}
        onFloatingScaleChange={shellSettings.updateFloatingScale}
        onFloatingUnreadEffectChange={shellSettings.updateFloatingUnreadEffect}
        onLiveThreadSelect={setSelectedLiveThreadId}
        onToggleFloating={shellSettings.toggleFloatingWindow}
        onToggleStatusTray={shellSettings.toggleStatusTrayLiveText}
        onCodexHomeChange={updateCodexHome}
        onCodexHomeReset={restoreAutoCodexHome}
        onToggleAutostart={shellSettings.toggleAutostart}
        providerRepair={readyState.repair}
        onProviderRepairChange={updateProviderRepair}
        refreshing={state.loading}
        selectedLiveThreadId={selectedLiveThreadId}
      />
      {shellSettings.showSetupGuide ? (
        <SetupGuide
          codexHome={readyState.codexHome}
          autostartStatus={shellSettings.autostartStatus}
          displaySurfaces={shellSettings.displaySurfaces}
          floatingVisible={shellSettings.floatingVisible}
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
