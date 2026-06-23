import { useEffect, useRef, useState } from "react";
import {
  readAppSettings,
  saveFloatingSettings,
  saveSetupGuideCompleted,
} from "../api/client";
import {
  DEFAULT_FLOATING_SETTINGS,
  sanitizeFloatingSettings,
} from "../floating/floatingSettings";
import { desktopPlatform } from "../platform/desktop";
import type {
  AutostartStatus,
  DisplaySurfaceSettings,
  FloatingUnreadEffect,
  FloatingWindowSettings,
  PlatformCapabilities,
} from "../types/dashboard";
import { useAutostartSettings } from "./useAutostartSettings";
import { useDisplaySurfaceSettings } from "./useDisplaySurfaceSettings";

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
  updateFloatingGradient: (patch: Partial<Pick<FloatingWindowSettings, "gradientStart" | "gradientEnd" | "gradientDirection" | "gradientType">>) => void;
}

export function useDashboardShellSettings({
  dashboardHydrated,
  platform,
}: DashboardShellSettingsOptions): DashboardShellSettingsState {
  const [floatingSettings, setFloatingSettings] = useState(DEFAULT_FLOATING_SETTINGS);
  const [showSetupGuide, setShowSetupGuide] = useState(false);
  const floatingSettingsLoaded = useRef(false);
  const { autostartStatus, toggleAutostart } = useAutostartSettings({ dashboardHydrated });
  const {
    applyDisplaySurfaces,
    displaySurfaces,
    floatingVisible,
    toggleFloatingWindow,
    toggleStatusTrayLiveText,
  } = useDisplaySurfaceSettings({ platform });

  useEffect(() => {
    let cancelled = false;

    void readAppSettings().then((settings) => {
      if (cancelled || settings === null) {
        return;
      }
      floatingSettingsLoaded.current = true;
      setFloatingSettings(sanitizeFloatingSettings(settings.floatingWindow));
      applyDisplaySurfaces(settings.displaySurfaces);
      setShowSetupGuide(!settings.setupGuideCompleted);
    });

    return () => {
      cancelled = true;
    };
  }, [applyDisplaySurfaces]);

  useEffect(() => {
    const sanitized = sanitizeFloatingSettings(floatingSettings);
    void desktopPlatform.publishFloatingSettings(sanitized);
    if (floatingSettingsLoaded.current) {
      void saveFloatingSettings(sanitized).catch(() => {});
    }
  }, [floatingSettings]);

  function updateFloatingOpacity(opacity: number) {
    setFloatingSettings((current) => sanitizeFloatingSettings({ ...current, opacity }));
  }

  function updateFloatingScale(scale: number) {
    setFloatingSettings((current) => sanitizeFloatingSettings({ ...current, scale }));
  }

  function updateFloatingUnreadEffect(unreadEffect: FloatingUnreadEffect) {
    setFloatingSettings((current) => sanitizeFloatingSettings({ ...current, unreadEffect }));
  }

  function updateFloatingGradient(
    patch: Partial<Pick<FloatingWindowSettings, "gradientStart" | "gradientEnd" | "gradientDirection" | "gradientType">>,
  ) {
    setFloatingSettings((current) => sanitizeFloatingSettings({ ...current, ...patch }));
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
    updateFloatingGradient,
  };
}
