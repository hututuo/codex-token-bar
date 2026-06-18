import { useEffect, useMemo, useRef, useState } from "react";
import { readAppSettings, saveDisplaySurfaces, saveFloatingSettings } from "../api/client";
import { FloatingWindowApp } from "../floating/FloatingWindowApp";
import {
  DEFAULT_FLOATING_SETTINGS,
  sanitizeFloatingSettings,
} from "../floating/floatingSettings";
import { DashboardPage } from "../pages/DashboardPage";
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
  } = useDashboardData();
  const [floatingVisible, setFloatingVisible] = useState(true);
  const [floatingSettings, setFloatingSettings] = useState(DEFAULT_FLOATING_SETTINGS);
  const [displaySurfaces, setDisplaySurfaces] = useState(DEFAULT_DISPLAY_SURFACES);
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

  if (readyState === null) {
    return (
      <main className="app-shell app-shell--loading">
        <div className="loading-mark">CX</div>
        <div className="loading-text">正在读取本地数据</div>
      </main>
    );
  }

  return (
    <DashboardPage
      codexHome={readyState.codexHome}
      dashboard={readyState.dashboard}
      displaySurfaces={displaySurfaces}
      floatingSettings={floatingSettings}
      floatingVisible={floatingVisible}
      liveRate={readyState.liveRate}
      platform={readyState.platform}
      onRefresh={reloadAll}
      onFloatingOpacityChange={updateFloatingOpacity}
      onFloatingScaleChange={updateFloatingScale}
      onFloatingUnreadEffectChange={updateFloatingUnreadEffect}
      onToggleFloating={toggleFloatingWindow}
      onToggleStatusTray={toggleStatusTrayLiveText}
      onCodexHomeChange={updateCodexHome}
      onCodexHomeReset={restoreAutoCodexHome}
      providerRepair={readyState.repair}
      onProviderRepairChange={updateProviderRepair}
      refreshing={state.loading}
    />
  );
}

function getSurfaceMode() {
  return desktopPlatform.getSurfaceMode();
}
