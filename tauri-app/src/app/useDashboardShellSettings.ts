import { useCallback, useEffect, useRef, useState } from "react";
import {
  cancelAutoResumeRun,
  listAutoResumeThreads,
  readAppSettings,
  readAutoResumeStatus,
  runAutoResumeNow,
  saveAutoResumeSettings,
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
  AutoResumeRuntimeStatus,
  AutoResumeSettings,
  AutoResumeThreadOption,
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
import {
  DEFAULT_AUTO_RESUME_SETTINGS,
  DEFAULT_AUTO_RESUME_STATUS,
  sanitizeAutoResumeSettings,
} from "../settings/autoResume";
import { useAutostartSettings } from "./useAutostartSettings";
import { useDisplaySurfaceSettings } from "./useDisplaySurfaceSettings";

interface DashboardShellSettingsOptions {
  dashboardHydrated: boolean;
  platform: PlatformCapabilities | null;
}

export interface DashboardShellSettingsState {
  autostartStatus: AutostartStatus;
  autoResumeError: string | null;
  autoResumeCancelling: boolean;
  autoResumeLoading: boolean;
  autoResumeRunning: boolean;
  autoResumeSaving: boolean;
  autoResumeSettings: AutoResumeSettings;
  autoResumeStatus: AutoResumeRuntimeStatus;
  autoResumeThreads: AutoResumeThreadOption[];
  displaySurfaces: DisplaySurfaceSettings;
  floatingSettings: FloatingWindowSettings;
  floatingVisible: boolean;
  customAccountDisplayName: string;
  quotaRefreshIntervalMs: number;
  showSetupGuide: boolean;
  completeSetupGuide: () => Promise<void>;
  cancelAutoResume: () => Promise<void>;
  refreshAutoResume: () => Promise<void>;
  runAutoResume: () => Promise<void>;
  saveAutoResume: (settings: AutoResumeSettings) => Promise<void>;
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
  const [autoResumeSettings, setAutoResumeSettings] = useState(DEFAULT_AUTO_RESUME_SETTINGS);
  const [autoResumeStatus, setAutoResumeStatus] = useState(DEFAULT_AUTO_RESUME_STATUS);
  const [autoResumeThreads, setAutoResumeThreads] = useState<AutoResumeThreadOption[]>([]);
  const [autoResumeLoading, setAutoResumeLoading] = useState(false);
  const [autoResumeCancelling, setAutoResumeCancelling] = useState(false);
  const [autoResumeSaving, setAutoResumeSaving] = useState(false);
  const [autoResumeRunning, setAutoResumeRunning] = useState(false);
  const [autoResumeError, setAutoResumeError] = useState<string | null>(null);
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
      setAutoResumeSettings(sanitizeAutoResumeSettings(settings.autoResume));
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

  const refreshAutoResume = useCallback(async () => {
    setAutoResumeLoading(true);
    const [threadsResult, statusResult] = await Promise.allSettled([
      listAutoResumeThreads(),
      readAutoResumeStatus(),
    ]);
    const failures: string[] = [];
    if (threadsResult.status === "fulfilled") {
      setAutoResumeThreads(threadsResult.value);
    } else {
      failures.push(`读取会话失败：${commandErrorMessage(threadsResult.reason)}`);
    }
    if (statusResult.status === "fulfilled") {
      updateAutoResumeStatus(setAutoResumeStatus, statusResult.value);
    } else {
      failures.push(`读取运行状态失败：${commandErrorMessage(statusResult.reason)}`);
    }
    setAutoResumeError(failures.length > 0 ? failures.join("；") : null);
    setAutoResumeLoading(false);
  }, []);

  useEffect(() => {
    let disposed = false;
    void readAutoResumeStatus().then((status) => {
      if (disposed) return;
      updateAutoResumeStatus(setAutoResumeStatus, status);
      setAutoResumeError(null);
    }).catch((error) => {
      if (!disposed) setAutoResumeError(`读取运行状态失败：${commandErrorMessage(error)}`);
    });
    const poll = window.setInterval(() => {
      void readAutoResumeStatus().then((status) => {
        if (disposed) return;
        updateAutoResumeStatus(setAutoResumeStatus, status);
        setAutoResumeError((current) => current?.startsWith("刷新运行状态失败") ? null : current);
      }).catch((error) => {
        if (!disposed) setAutoResumeError(`刷新运行状态失败：${commandErrorMessage(error)}`);
      });
    }, 10_000);
    return () => {
      disposed = true;
      window.clearInterval(poll);
    };
  }, []);

  useEffect(() => {
    let disposed = false;
    let unlisten: (() => void) | null = null;
    void desktopPlatform.onAppSettingsChanged((settings) => {
      if (!disposed) setAutoResumeSettings(sanitizeAutoResumeSettings(settings.autoResume));
    }).then((listener) => {
      if (disposed) listener();
      else unlisten = listener;
    });
    return () => {
      disposed = true;
      unlisten?.();
    };
  }, []);

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

  async function saveAutoResume(settings: AutoResumeSettings) {
    setAutoResumeSaving(true);
    setAutoResumeError(null);
    try {
      const saved = await saveAutoResumeSettings(sanitizeAutoResumeSettings(settings));
      setAutoResumeSettings(sanitizeAutoResumeSettings(saved.autoResume));
      void desktopPlatform.publishAppSettings(saved);
      void readAutoResumeStatus().then((status) => {
        updateAutoResumeStatus(setAutoResumeStatus, status);
      }).catch(() => {});
    } catch (error) {
      setAutoResumeError(`保存自动续跑失败：${commandErrorMessage(error)}`);
      throw error;
    } finally {
      setAutoResumeSaving(false);
    }
  }

  async function runAutoResume() {
    setAutoResumeRunning(true);
    setAutoResumeError(null);
    try {
      const status = await runAutoResumeNow();
      updateAutoResumeStatus(setAutoResumeStatus, status);
    } catch (error) {
      setAutoResumeError(`立即续跑失败：${commandErrorMessage(error)}`);
      throw error;
    } finally {
      setAutoResumeRunning(false);
    }
  }

  async function cancelAutoResume() {
    setAutoResumeCancelling(true);
    setAutoResumeError(null);
    try {
      const status = await cancelAutoResumeRun();
      updateAutoResumeStatus(setAutoResumeStatus, status);
    } catch (error) {
      setAutoResumeError(`停止本次续跑失败：${commandErrorMessage(error)}`);
      throw error;
    } finally {
      setAutoResumeCancelling(false);
    }
  }

  return {
    autostartStatus,
    autoResumeCancelling,
    autoResumeError,
    autoResumeLoading,
    autoResumeRunning,
    autoResumeSaving,
    autoResumeSettings,
    autoResumeStatus,
    autoResumeThreads,
    displaySurfaces,
    floatingSettings,
    floatingVisible,
    customAccountDisplayName,
    quotaRefreshIntervalMs,
    showSetupGuide,
    completeSetupGuide,
    cancelAutoResume,
    refreshAutoResume,
    runAutoResume,
    saveAutoResume,
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

function updateAutoResumeStatus(
  setStatus: (update: (current: AutoResumeRuntimeStatus) => AutoResumeRuntimeStatus) => void,
  incoming: AutoResumeRuntimeStatus,
) {
  setStatus((current) => incoming.revision >= current.revision ? incoming : current);
}

function commandErrorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (typeof error === "string") return error;
  return "未知错误";
}
