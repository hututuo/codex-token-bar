import { useEffect, useRef, useState } from "react";
import {
  readAppSettings,
  saveDisplaySurfaces,
  saveFloatingSettings,
  saveSetupGuideCompleted,
} from "../api/client";
import {
  DEFAULT_FLOATING_SETTINGS,
  sanitizeFloatingSettings,
} from "../floating/floatingSettings";
import { desktopPlatform } from "../platform/desktop";
import {
  canUseFloatingWindow,
  canUseStatusTrayLiveText,
  INACTIVE_DISPLAY_SURFACES,
  sanitizeDisplaySurfaces,
} from "../settings/displaySettings";
import { useStatusTray } from "../tray/useStatusTray";
import type {
  AutostartStatus,
  DisplaySurfaceSettings,
  FloatingUnreadEffect,
  FloatingWindowSettings,
  PlatformCapabilities,
} from "../types/dashboard";
import { useAutostartSettings } from "./useAutostartSettings";

interface DashboardShellSettingsOptions {
  dashboardHydrated: boolean;
  platform: PlatformCapabilities | null;
}

export interface DashboardShellSettingsState {
  autostartStatus: AutostartStatus;
  displaySurfaces: DisplaySurfaceSettings;
  floatingSettings: FloatingWindowSettings;
  floatingVisible: boolean;
  showSetupGuide: boolean;
  completeSetupGuide: () => Promise<void>;
  toggleAutostart: () => void;
  toggleFloatingWindow: () => Promise<void>;
  toggleStatusTrayLiveText: () => void;
  updateFloatingOpacity: (opacity: number) => void;
  updateFloatingScale: (scale: number) => void;
  updateFloatingUnreadEffect: (unreadEffect: FloatingUnreadEffect) => void;
}

export function useDashboardShellSettings({
  dashboardHydrated,
  platform,
}: DashboardShellSettingsOptions): DashboardShellSettingsState {
  const [floatingVisible, setFloatingVisible] = useState(false);
  const [floatingSettings, setFloatingSettings] = useState(DEFAULT_FLOATING_SETTINGS);
  const [displaySurfaces, setDisplaySurfaces] = useState(INACTIVE_DISPLAY_SURFACES);
  const [showSetupGuide, setShowSetupGuide] = useState(false);
  const floatingSettingsLoaded = useRef(false);
  const displaySettingsLoaded = useRef(false);
  const floatingAvailable = canUseFloatingWindow(platform);
  const statusTrayLiveTextAvailable = canUseStatusTrayLiveText(platform);
  const { autostartStatus, toggleAutostart } = useAutostartSettings({ dashboardHydrated });

  useStatusTray(
    platform,
    displaySurfaces.statusTrayLiveTextEnabled && statusTrayLiveTextAvailable,
  );

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
      if (cancelled || settings === null) {
        return;
      }
      floatingSettingsLoaded.current = true;
      displaySettingsLoaded.current = true;
      setFloatingSettings(sanitizeFloatingSettings(settings.floatingWindow));
      setDisplaySurfaces(sanitizeDisplaySurfaces(settings.displaySurfaces));
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

  function updateDisplaySurfaces(next: Partial<DisplaySurfaceSettings>) {
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

  function updateFloatingUnreadEffect(unreadEffect: FloatingUnreadEffect) {
    setFloatingSettings((current) => sanitizeFloatingSettings({ ...current, unreadEffect }));
  }

  async function completeSetupGuide() {
    const settings = await saveSetupGuideCompleted(true);
    if (!settings.setupGuideCompleted) {
      throw new Error("首次设置状态没有写入本地设置文件。");
    }
    setShowSetupGuide(false);
  }

  return {
    autostartStatus,
    displaySurfaces,
    floatingSettings,
    floatingVisible,
    showSetupGuide,
    completeSetupGuide,
    toggleAutostart,
    toggleFloatingWindow,
    toggleStatusTrayLiveText,
    updateFloatingOpacity,
    updateFloatingScale,
    updateFloatingUnreadEffect,
  };
}
