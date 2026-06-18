import { useEffect, useMemo, useRef, useState } from "react";
import {
  readAutostartStatus,
  readAppSettings,
  recordStartupEvent,
  saveDisplaySurfaces,
  saveFloatingSettings,
  saveSetupGuideCompleted,
  setAutostartEnabled,
} from "../api/client";
import { FloatingWindowApp } from "../floating/FloatingWindowApp";
import {
  DEFAULT_FLOATING_SETTINGS,
  sanitizeFloatingSettings,
} from "../floating/floatingSettings";
import { DashboardPage } from "../pages/DashboardPage";
import { SetupGuide } from "../components/SetupGuide";
import { desktopPlatform } from "../platform/desktop";
import {
  canUseFloatingWindow,
  canUseStatusTrayLiveText,
  INACTIVE_DISPLAY_SURFACES,
  sanitizeDisplaySurfaces,
} from "../settings/displaySettings";
import { useDashboardData } from "../state/useDashboardData";
import { StatusPanelApp } from "../status/StatusPanelApp";
import { useStatusTray } from "../tray/useStatusTray";
import type { AutostartStatus } from "../types/dashboard";
import { fallbackAutostartStatus } from "../api/fallback";

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
  const [floatingVisible, setFloatingVisible] = useState(false);
  const [floatingSettings, setFloatingSettings] = useState(DEFAULT_FLOATING_SETTINGS);
  const [displaySurfaces, setDisplaySurfaces] = useState(INACTIVE_DISPLAY_SURFACES);
  const [autostartStatus, setAutostartStatus] = useState<AutostartStatus>(fallbackAutostartStatus);
  const [autostartUpdating, setAutostartUpdating] = useState(false);
  const [showSetupGuide, setShowSetupGuide] = useState(false);
  const floatingSettingsLoaded = useRef(false);
  const displaySettingsLoaded = useRef(false);
  const floatingAvailable = canUseFloatingWindow(state.platform);
  const statusTrayLiveTextAvailable = canUseStatusTrayLiveText(state.platform);
  useStatusTray(
    state.platform,
    displaySurfaces.statusTrayLiveTextEnabled && statusTrayLiveTextAvailable,
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
    if (!dashboardHydrated) {
      return;
    }

    let cancelled = false;
    const timeoutId = window.setTimeout(() => {
      void recordStartupEvent("autostart lazy read requested");
      void readAutostartStatus().then((status) => {
        if (!cancelled) {
          setAutostartStatus(status);
        }
      });
    }, 800);

    return () => {
      cancelled = true;
      window.clearTimeout(timeoutId);
    };
  }, [dashboardHydrated]);

  useEffect(() => {
    let cancelled = false;

    void readAppSettings().then((settings) => {
      if (cancelled || settings === null) {
        return;
      }
      floatingSettingsLoaded.current = true;
      displaySettingsLoaded.current = true;
      setFloatingSettings(sanitizeFloatingSettings(settings.floatingWindow));
      const display = sanitizeDisplaySurfaces(settings.displaySurfaces);
      setDisplaySurfaces(display);
      setShowSetupGuide(!settings.setupGuideCompleted);
    });

    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    if (!displaySettingsLoaded.current) {
      return;
    }

    let cancelled = false;
    const shouldShowFloating = displaySurfaces.floatingWindowEnabled && floatingAvailable;

    async function applyFloatingPreference() {
      const confirmed = shouldShowFloating
        ? await desktopPlatform.showFloatingWindow()
        : await desktopPlatform.hideFloatingWindow();
      if (!cancelled) {
        setFloatingVisible(shouldShowFloating && confirmed);
      }
    }

    void applyFloatingPreference();

    return () => {
      cancelled = true;
    };
  }, [displaySurfaces.floatingWindowEnabled, floatingAvailable]);

  useEffect(() => {
    const sanitized = sanitizeFloatingSettings(floatingSettings);
    void desktopPlatform.publishFloatingSettings(sanitized);
    if (floatingSettingsLoaded.current) {
      void saveFloatingSettings(sanitized).catch(() => {});
    }
  }, [floatingSettings]);

  async function toggleFloatingWindow() {
    const nextVisible = !floatingVisible;
    if (!floatingAvailable) {
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
    if (!statusTrayLiveTextAvailable) {
      return;
    }
    updateDisplaySurfaces({
      statusTrayLiveTextEnabled: !displaySurfaces.statusTrayLiveTextEnabled,
    });
  }

  async function toggleAutostart() {
    if (autostartUpdating || !autostartStatus.available) {
      return;
    }

    setAutostartUpdating(true);
    try {
      const next = await setAutostartEnabled(!autostartStatus.enabled);
      setAutostartStatus(next);
    } catch {
      const refreshed = await readAutostartStatus();
      setAutostartStatus(refreshed);
    } finally {
      setAutostartUpdating(false);
    }
  }

  function updateDisplaySurfaces(next: Partial<typeof displaySurfaces>) {
    setDisplaySurfaces((current) => {
      const sanitized = sanitizeDisplaySurfaces({ ...current, ...next });
      if (displaySettingsLoaded.current) {
        void saveDisplaySurfaces(sanitized).catch(() => {});
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
        <div className="loading-text">正在打开本地面板</div>
      </main>
    );
  }

  return (
    <>
      <DashboardPage
        autostartStatus={autostartStatus}
        codexHome={readyState.codexHome}
        dashboard={readyState.dashboard}
        diagnostics={readyState.diagnostics}
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
        onToggleAutostart={toggleAutostart}
        providerRepair={readyState.repair}
        onProviderRepairChange={updateProviderRepair}
        refreshing={state.loading}
        selectedLiveThreadId={selectedLiveThreadId}
      />
      {showSetupGuide ? (
        <SetupGuide
          codexHome={readyState.codexHome}
          autostartStatus={autostartStatus}
          displaySurfaces={displaySurfaces}
          floatingVisible={floatingVisible}
          platform={readyState.platform}
          statusTrayLiveTextEnabled={displaySurfaces.statusTrayLiveTextEnabled}
          onCodexHomeChange={updateCodexHome}
          onCodexHomeReset={restoreAutoCodexHome}
          onComplete={completeSetupGuide}
          onToggleAutostart={toggleAutostart}
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
