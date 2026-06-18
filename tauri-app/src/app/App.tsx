import { useEffect, useMemo, useState } from "react";
import { FloatingWindowApp } from "../floating/FloatingWindowApp";
import {
  readFloatingSettings,
  sanitizeFloatingSettings,
  writeFloatingSettings,
} from "../floating/floatingSettings";
import { DashboardPage } from "../pages/DashboardPage";
import { desktopPlatform } from "../platform/desktop";
import { useDashboardData } from "../state/useDashboardData";
import { useStatusTray } from "../tray/useStatusTray";

export function App() {
  const surface = useMemo(getSurfaceMode, []);
  if (surface === "floating") {
    return <FloatingWindowApp />;
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
  const [floatingSettings, setFloatingSettings] = useState(readFloatingSettings);
  useStatusTray(state.liveRate, state.platform);

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
    const sanitized = sanitizeFloatingSettings(floatingSettings);
    writeFloatingSettings(sanitized);
    void desktopPlatform.publishFloatingSettings(sanitized);
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
  }

  function updateFloatingOpacity(opacity: number) {
    setFloatingSettings((current) => sanitizeFloatingSettings({ ...current, opacity }));
  }

  function updateFloatingScale(scale: number) {
    setFloatingSettings((current) => sanitizeFloatingSettings({ ...current, scale }));
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
      floatingSettings={floatingSettings}
      floatingVisible={floatingVisible}
      liveRate={readyState.liveRate}
      platform={readyState.platform}
      onRefresh={reloadAll}
      onFloatingOpacityChange={updateFloatingOpacity}
      onFloatingScaleChange={updateFloatingScale}
      onToggleFloating={toggleFloatingWindow}
      onCodexHomeChange={updateCodexHome}
      onCodexHomeReset={restoreAutoCodexHome}
      providerRepair={readyState.repair}
      onProviderRepairChange={updateProviderRepair}
      refreshing={state.loading}
    />
  );
}

function getSurfaceMode(): "dashboard" | "floating" {
  return desktopPlatform.getSurfaceMode();
}
