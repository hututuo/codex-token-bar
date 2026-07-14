import { useEffect, useRef, useState } from "react";
import {
  readAppSettings,
  saveCustomAccountDisplayName,
  saveFloatingSettings,
  saveQuotaRefreshIntervalMs,
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
  FloatingContentVisibility,
  FloatingPalettePatch,
  FloatingUnreadEffect,
  FloatingWindowSettings,
  PlatformCapabilities,
} from "../types/dashboard";
import {
  DEFAULT_QUOTA_REFRESH_INTERVAL_MS,
  sanitizeQuotaRefreshIntervalMs,
} from "../settings/quotaRefreshCadence";
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
  customAccountDisplayName: string;
  quotaRefreshIntervalMs: number;
  showSetupGuide: boolean;
  completeSetupGuide: () => Promise<void>;
  toggleAutostart: () => void;
  toggleLiveRate: () => void;
  toggleFloatingWindow: () => Promise<void>;
  toggleStatusTrayLiveText: () => void;
  updateFloatingOpacity: (opacity: number) => void;
  updateFloatingScale: (scale: number) => void;
  updateTokenRateFullScale: (fullScale: number) => void;
  updateFloatingUnreadEffect: (unreadEffect: FloatingUnreadEffect) => void;
  updateFloatingGradient: (patch: FloatingPalettePatch) => void;
  updateFloatingTextTone: (textTone: number) => void;
  updateFloatingContentVisibility: (contentVisibility: FloatingContentVisibility) => void;
  updateCustomAccountDisplayName: (displayName: string) => Promise<void>;
  updateQuotaRefreshIntervalMs: (intervalMs: number) => Promise<void>;
}

export function useDashboardShellSettings({
  dashboardHydrated,
  platform,
}: DashboardShellSettingsOptions): DashboardShellSettingsState {
  const [floatingSettings, setFloatingSettings] = useState(DEFAULT_FLOATING_SETTINGS);
  const [customAccountDisplayName, setCustomAccountDisplayName] = useState("");
  const [quotaRefreshIntervalMs, setQuotaRefreshIntervalMs] = useState(DEFAULT_QUOTA_REFRESH_INTERVAL_MS);
  const [showSetupGuide, setShowSetupGuide] = useState(false);
  const floatingSettingsLoaded = useRef(false);
  const { autostartStatus, toggleAutostart } = useAutostartSettings({ dashboardHydrated });
  const {
    applyDisplaySurfaces,
    displaySurfaces,
    floatingVisible,
    toggleLiveRate: toggleLiveRateSurface,
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
      setCustomAccountDisplayName(settings.customAccountDisplayName.trim());
      setQuotaRefreshIntervalMs(sanitizeQuotaRefreshIntervalMs(settings.quotaRefreshIntervalMs));
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

  function updateTokenRateFullScale(tokenRateFullScale: number) {
    setFloatingSettings((current) => sanitizeFloatingSettings({ ...current, tokenRateFullScale }));
  }

  function updateFloatingUnreadEffect(unreadEffect: FloatingUnreadEffect) {
    setFloatingSettings((current) => sanitizeFloatingSettings({ ...current, unreadEffect }));
  }

  function updateFloatingGradient(
    patch: FloatingPalettePatch,
  ) {
    setFloatingSettings((current) => sanitizeFloatingSettings({ ...current, ...patch }));
  }

  function updateFloatingTextTone(textTone: number) {
    setFloatingSettings((current) => sanitizeFloatingSettings({ ...current, textTone }));
  }

  function updateFloatingContentVisibility(contentVisibility: FloatingContentVisibility) {
    setFloatingSettings((current) => sanitizeFloatingSettings({ ...current, contentVisibility }));
  }

  function toggleLiveRate() {
    const nextEnabled = !displaySurfaces.liveRateEnabled;
    toggleLiveRateSurface();
    setFloatingSettings((current) => sanitizeFloatingSettings({
      ...current,
      contentVisibility: {
        ...current.contentVisibility,
        showRateAndBar: nextEnabled,
      },
    }));
  }

  async function updateCustomAccountDisplayName(displayName: string) {
    const nextName = displayName.trim();
    setCustomAccountDisplayName(nextName);
    const settings = await saveCustomAccountDisplayName(nextName);
    setCustomAccountDisplayName(settings.customAccountDisplayName.trim());
  }

  async function updateQuotaRefreshIntervalMs(intervalMs: number) {
    const nextIntervalMs = sanitizeQuotaRefreshIntervalMs(intervalMs);
    setQuotaRefreshIntervalMs(nextIntervalMs);
    const settings = await saveQuotaRefreshIntervalMs(nextIntervalMs);
    setQuotaRefreshIntervalMs(sanitizeQuotaRefreshIntervalMs(settings.quotaRefreshIntervalMs));
    void desktopPlatform.publishAppSettings(settings);
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
    customAccountDisplayName,
    quotaRefreshIntervalMs,
    showSetupGuide,
    completeSetupGuide,
    toggleAutostart,
    toggleLiveRate,
    toggleFloatingWindow,
    toggleStatusTrayLiveText,
    updateFloatingOpacity,
    updateFloatingScale,
    updateTokenRateFullScale,
    updateFloatingUnreadEffect,
    updateFloatingGradient,
    updateFloatingTextTone,
    updateFloatingContentVisibility,
    updateCustomAccountDisplayName,
    updateQuotaRefreshIntervalMs,
  };
}
