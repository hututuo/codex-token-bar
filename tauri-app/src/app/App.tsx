import { useEffect, useMemo, useState } from "react";
import { recordStartupEvent } from "../api/client";
import { FloatingWindowApp } from "../floating/FloatingWindowApp";
import { DashboardPage } from "../pages/DashboardPage";
import { SetupGuide } from "../components/SetupGuide";
import { desktopPlatform } from "../platform/desktop";
import { useDashboardData } from "../state/useDashboardData";
import { StatusPanelApp } from "../status/StatusPanelApp";
import { useDashboardShellSettings } from "./useDashboardShellSettings";

export function App() {
  const surface = useMemo(getSurfaceMode, []);
  if (surface === "floating") {
    return <FloatingWindowApp />;
  }
  if (surface === "status") {
    return <StatusPanelApp />;
  }

  return <DashboardApp />;
}

function DashboardApp() {
  const [dashboardHydrated, setDashboardHydrated] = useState(false);

  useEffect(() => {
    void recordStartupEvent("dashboard mounted");
  }, []);

  useEffect(() => {
    let timeoutId = 0;
    const frameId = window.requestAnimationFrame(() => {
      timeoutId = window.setTimeout(() => {
        setDashboardHydrated(true);
        void recordStartupEvent("dashboard hydrate full ui");
      }, 0);
    });

    return () => {
      window.cancelAnimationFrame(frameId);
      window.clearTimeout(timeoutId);
    };
  }, []);

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

  if (readyState === null) {
    return (
      <main className="app-shell app-shell--loading">
        <div className="loading-mark">CX</div>
        <div className="loading-text">正在打开本地面板</div>
      </main>
    );
  }

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

function getSurfaceMode() {
  return desktopPlatform.getSurfaceMode();
}
