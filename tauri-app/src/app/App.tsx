import { useEffect, useMemo, useRef, useState } from "react";
import {
  readAppSettings,
  saveDisplaySurfaces,
  saveFloatingSettings,
  saveSetupGuideCompleted,
} from "../api/client";
import { FloatingWindowApp } from "../floating/FloatingWindowApp";
import {
  DEFAULT_FLOATING_SETTINGS,
  sanitizeFloatingSettings,
} from "../floating/floatingSettings";
import { DashboardPage } from "../pages/DashboardPage";
import { SetupGuide } from "../components/SetupGuide";
import { desktopPlatform } from "../platform/desktop";
import { DEFAULT_DISPLAY_SURFACES, sanitizeDisplaySurfaces } from "../settings/displaySettings";
import { useDashboardData } from "../state/useDashboardData";
import { StatusPanelApp } from "../status/StatusPanelApp";
import { useStatusTray } from "../tray/useStatusTray";

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
  const [floatingVisible, setFloatingVisible] = useState(true);
  const [floatingSettings, setFloatingSettings] = useState(DEFAULT_FLOATING_SETTINGS);
  const [displaySurfaces, setDisplaySurfaces] = useState(DEFAULT_DISPLAY_SURFACES);
  const [showSetupGuide, setShowSetupGuide] = useState(false);
  const floatingSettingsLoaded = useRef(false);
  const displaySettingsLoaded = useRef(false);
  useStatusTray(
    state.liveRate,
    state.platform,
    displaySurfaces.statusTrayLiveTextEnabled,
  );

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

  useEffect(() => {
    let disposed = false;
    let unlisten: (() => void) | null = null;

    void desktopPlatform.onFloatingWindowHidden(() => {
      setFloatingVisible(false);
    }).then((listener) => {
      if (disposed) {
        listener();
      } else {
        unlisten = listener;
      }
    });

    return () => {
      disposed = true;
      unlisten?.();
    };
  }, []);

  useEffect(() => {
    let cancelled = false;

    void readAppSettings().then((settings) => {
      if (cancelled) {
        return;
      }
      floatingSettingsLoaded.current = true;
      displaySettingsLoaded.current = true;
      setFloatingSettings(sanitizeFloatingSettings(settings.floatingWindow));
      const display = sanitizeDisplaySurfaces(settings.displaySurfaces);
      setDisplaySurfaces(display);
      setShowSetupGuide(!settings.setupGuideCompleted);
      setFloatingVisible(display.floatingWindowEnabled);
      if (display.floatingWindowEnabled) {
        void desktopPlatform.showFloatingWindow();
      } else {
        void desktopPlatform.hideFloatingWindow();
      }
    });

    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    const sanitized = sanitizeFloatingSettings(floatingSettings);
    void desktopPlatform.publishFloatingSettings(sanitized);
    if (floatingSettingsLoaded.current) {
      void saveFloatingSettings(sanitized);
    }
  }, [floatingSettings]);

  async function toggleFloatingWindow() {
    const nextVisible = !floatingVisible;
    if (readyState !== null && !readyState.platform.floatingWindow.available) {
      setFloatingVisible(false);
      return;
    }
    setFloatingVisible(nextVisible);
    const confirmed = nextVisible
      ? await desktopPlatform.showFloatingWindow()
      : await desktopPlatform.hideFloatingWindow();
    setFloatingVisible(confirmed);
    updateDisplaySurfaces({ floatingWindowEnabled: confirmed });
  }

  function toggleStatusTrayLiveText() {
    updateDisplaySurfaces({
      statusTrayLiveTextEnabled: !displaySurfaces.statusTrayLiveTextEnabled,
    });
  }

  function updateDisplaySurfaces(next: Partial<typeof displaySurfaces>) {
    setDisplaySurfaces((current) => {
      const sanitized = sanitizeDisplaySurfaces({ ...current, ...next });
      if (displaySettingsLoaded.current) {
        void saveDisplaySurfaces(sanitized);
      }
      return sanitized;
    });
  }

  function updateFloatingOpacity(opacity: number) {
    setFloatingSettings((current) => sanitizeFloatingSettings({ ...current, opacity }));
  }

  function updateFloatingScale(scale: number) {
    setFloatingSettings((current) => sanitizeFloatingSettings({ ...current, scale }));
  }

  function updateFloatingUnreadEffect(unreadEffect: typeof floatingSettings.unreadEffect) {
    setFloatingSettings((current) => sanitizeFloatingSettings({ ...current, unreadEffect }));
  }

  async function completeSetupGuide() {
    const settings = await saveSetupGuideCompleted(true);
    if (!settings.setupGuideCompleted) {
      throw new Error("首次设置状态没有写入本地设置文件。");
    }
    setShowSetupGuide(false);
  }

  if (readyState === null) {
    return (
      <main className="app-shell app-shell--loading">
        <div className="loading-mark">CX</div>
        <div className="loading-text">正在读取本地数据</div>
      </main>
    );
  }

  return (
    <>
      <DashboardPage
        codexHome={readyState.codexHome}
        dashboard={readyState.dashboard}
        displaySurfaces={displaySurfaces}
        floatingSettings={floatingSettings}
        floatingVisible={floatingVisible}
        liveRate={readyState.liveRate}
        liveThreadOptions={readyState.liveThreadOptions}
        platform={readyState.platform}
        onRefresh={reloadAll}
        onFloatingOpacityChange={updateFloatingOpacity}
        onFloatingScaleChange={updateFloatingScale}
        onFloatingUnreadEffectChange={updateFloatingUnreadEffect}
        onLiveThreadSelect={setSelectedLiveThreadId}
        onToggleFloating={toggleFloatingWindow}
        onToggleStatusTray={toggleStatusTrayLiveText}
        onCodexHomeChange={updateCodexHome}
        onCodexHomeReset={restoreAutoCodexHome}
        providerRepair={readyState.repair}
        onProviderRepairChange={updateProviderRepair}
        refreshing={state.loading}
        selectedLiveThreadId={selectedLiveThreadId}
      />
      {showSetupGuide ? (
        <SetupGuide
          codexHome={readyState.codexHome}
          displaySurfaces={displaySurfaces}
          floatingVisible={floatingVisible}
          platform={readyState.platform}
          statusTrayLiveTextEnabled={displaySurfaces.statusTrayLiveTextEnabled}
          onCodexHomeChange={updateCodexHome}
          onCodexHomeReset={restoreAutoCodexHome}
          onComplete={completeSetupGuide}
          onToggleFloating={toggleFloatingWindow}
          onToggleStatusTray={toggleStatusTrayLiveText}
        />
      ) : null}
    </>
  );
}

function getSurfaceMode() {
  return desktopPlatform.getSurfaceMode();
}
