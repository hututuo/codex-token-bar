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
  saveSessionEnhancementSettings,
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
  SessionEnhancementSettings,
  StatusMetricId,
  StatusMetricLabelStyle,
  StatusSummarySectionId,
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
import {
  DEFAULT_SESSION_ENHANCEMENTS,
  sanitizeSessionEnhancements,
} from "../settings/sessionEnhancements";
import {
  createTrailingSettingsPersistence,
  type TrailingSettingsPersistence,
} from "../settings/trailingSettingsPersistence";
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
  sessionEnhancements: SessionEnhancementSettings;
  displaySurfaces: DisplaySurfaceSettings;
  floatingSettings: FloatingWindowSettings;
  floatingVisible: boolean;
  customAccountDisplayName: string;
  quotaRefreshIntervalMs: number;
  settingsError: string | null;
  showSetupGuide: boolean;
  completeSetupGuide: () => Promise<void>;
  cancelAutoResume: () => Promise<void>;
  refreshAutoResume: () => Promise<void>;
  runAutoResume: (taskId: string) => Promise<void>;
  saveAutoResume: (settings: AutoResumeSettings) => Promise<void>;
  saveSessionEnhancements: (settings: SessionEnhancementSettings) => Promise<void>;
  toggleAutostart: () => void;
  toggleLiveRate: () => void;
  toggleFloatingWindow: () => Promise<void>;
  toggleStatusTrayLiveText: () => void;
  updateStatusMetricOrder: (order: StatusMetricId[]) => void;
  updateStatusMetricLabelStyle: (style: StatusMetricLabelStyle) => void;
  updateStatusSummaryOrder: (order: StatusSummarySectionId[]) => void;
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
  const [sessionEnhancements, setSessionEnhancements] = useState(DEFAULT_SESSION_ENHANCEMENTS);
  const [autoResumeStatus, setAutoResumeStatus] = useState(DEFAULT_AUTO_RESUME_STATUS);
  const [autoResumeThreads, setAutoResumeThreads] = useState<AutoResumeThreadOption[]>([]);
  const [autoResumeLoading, setAutoResumeLoading] = useState(false);
  const [autoResumeCancelling, setAutoResumeCancelling] = useState(false);
  const [autoResumeSaving, setAutoResumeSaving] = useState(false);
  const [autoResumeRunning, setAutoResumeRunning] = useState(false);
  const [autoResumeError, setAutoResumeError] = useState<string | null>(null);
  const [customAccountDisplayName, setCustomAccountDisplayName] = useState("");
  const [quotaRefreshIntervalMs, setQuotaRefreshIntervalMs] = useState(DEFAULT_QUOTA_REFRESH_INTERVAL_MS);
  const [settingsError, setSettingsError] = useState<string | null>(null);
  const [showSetupGuide, setShowSetupGuide] = useState(false);
  const floatingSettingsLoaded = useRef(false);
  const floatingSettingsEdits = useRef(0);
  const floatingSettingsRef = useRef(DEFAULT_FLOATING_SETTINGS);
  const floatingPersistenceRef = useRef<TrailingSettingsPersistence<FloatingWindowSettings> | null>(null);
  if (floatingPersistenceRef.current === null) {
    floatingPersistenceRef.current = createTrailingSettingsPersistence(
      saveFloatingSettings,
      {
        equals: sameFloatingSettings,
        persistedValue: (_requested, result) => sanitizeFloatingSettings(result.floatingWindow),
        onLatestPersisted: () => {
          setSettingsError((current) => (
            current?.startsWith("保存悬浮窗设置失败") ? null : current
          ));
        },
        onLatestError: (error) => {
          setSettingsError(
            `保存悬浮窗设置失败：${commandErrorMessage(error)}；当前修改仅本次会话生效。`,
          );
        },
      },
    );
  }
  const { autostartStatus, toggleAutostart } = useAutostartSettings({ dashboardHydrated });
  const reportDisplayPersistenceError = useCallback((error: unknown | null) => {
    if (error === null) {
      setSettingsError((current) => (
        current?.startsWith("保存显示位置设置失败") ? null : current
      ));
      return;
    }
    setSettingsError(
      `保存显示位置设置失败：${commandErrorMessage(error)}；当前修改仅本次会话生效。`,
    );
  }, []);
  const {
    applyDisplaySurfaces,
    displaySurfaces,
    floatingVisible,
    toggleLiveRate: toggleLiveRateSurface,
    toggleFloatingWindow,
    toggleStatusTrayLiveText,
    updateStatusMetricOrder,
    updateStatusMetricLabelStyle,
    updateStatusSummaryOrder,
  } = useDisplaySurfaceSettings({
    onPersistenceError: reportDisplayPersistenceError,
    platform,
  });

  useEffect(() => {
    let cancelled = false;

    void readAppSettings().then((settings) => {
      if (cancelled || settings === null) {
        // null = Missing（非 Tauri 桌面运行环境）：保持默认值即可，不算错误。
        return;
      }
      floatingSettingsLoaded.current = true;
      setCustomAccountDisplayName(settings.customAccountDisplayName.trim());
      setQuotaRefreshIntervalMs(sanitizeQuotaRefreshIntervalMs(settings.quotaRefreshIntervalMs));
      const persistedFloatingSettings = sanitizeFloatingSettings(settings.floatingWindow);
      floatingPersistenceRef.current?.setPersisted(persistedFloatingSettings);
      if (floatingSettingsEdits.current === 0) {
        floatingSettingsRef.current = persistedFloatingSettings;
        setFloatingSettings(persistedFloatingSettings);
        void desktopPlatform.publishFloatingSettings(persistedFloatingSettings);
      } else {
        floatingPersistenceRef.current?.schedule(floatingSettingsRef.current);
      }
      setAutoResumeSettings(sanitizeAutoResumeSettings(settings.autoResume));
      setSessionEnhancements(sanitizeSessionEnhancements(settings.sessionEnhancements));
      applyDisplaySurfaces(settings.displaySurfaces);
      setShowSetupGuide(!settings.setupGuideCompleted);
    }).catch((error) => {
      if (cancelled) return;
      // 读取失败时不把默认值当作已加载：悬浮窗修改只发布不落盘，避免用默认值
      // 覆盖磁盘上可能完好的设置；横幅明确告知后果。
      setSettingsError(
        `读取本地设置失败：${commandErrorMessage(error)}；本次会话使用默认设置，界面上的设置修改可能不会保存。`,
      );
    });

    return () => {
      cancelled = true;
    };
  }, [applyDisplaySurfaces]);

  useEffect(() => {
    const flush = () => {
      void floatingPersistenceRef.current?.flush();
    };
    window.addEventListener("pagehide", flush);
    return () => {
      window.removeEventListener("pagehide", flush);
      flush();
    };
  }, []);

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
      if (!disposed) {
        setAutoResumeSettings(sanitizeAutoResumeSettings(settings.autoResume));
        setSessionEnhancements(sanitizeSessionEnhancements(settings.sessionEnhancements));
      }
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
    updateFloatingSettings({ opacity });
  }

  function updateFloatingScale(scale: number) {
    updateFloatingSettings({ scale });
  }

  function updateTokenRateFullScale(tokenRateFullScale: number) {
    updateFloatingSettings({ tokenRateFullScale });
  }

  function updateFloatingUnreadEffect(unreadEffect: FloatingUnreadEffect) {
    updateFloatingSettings({ unreadEffect });
  }

  function updateFloatingGradient(
    patch: FloatingPalettePatch,
  ) {
    updateFloatingSettings(patch);
  }

  function updateFloatingTextTone(textTone: number) {
    updateFloatingSettings({ textTone });
  }

  function updateFloatingContentVisibility(contentVisibility: FloatingContentVisibility) {
    updateFloatingSettings({ contentVisibility });
  }

  function toggleLiveRate() {
    const nextEnabled = !displaySurfaces.liveRateEnabled;
    toggleLiveRateSurface();
    updateFloatingSettings({
      contentVisibility: {
        ...floatingSettingsRef.current.contentVisibility,
        showRateAndBar: nextEnabled,
      },
    });
  }

  function updateFloatingSettings(patch: Partial<FloatingWindowSettings>) {
    const next = sanitizeFloatingSettings({ ...floatingSettingsRef.current, ...patch });
    if (sameFloatingSettings(next, floatingSettingsRef.current)) {
      return;
    }
    floatingSettingsEdits.current += 1;
    floatingSettingsRef.current = next;
    setFloatingSettings(next);
    void desktopPlatform.publishFloatingSettings(next);
    if (floatingSettingsLoaded.current) {
      floatingPersistenceRef.current?.schedule(next);
    }
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

  async function saveSessionEnhancements(settings: SessionEnhancementSettings) {
    const next = sanitizeSessionEnhancements(settings);
    setSessionEnhancements(next);
    try {
      const saved = await saveSessionEnhancementSettings(next);
      setSessionEnhancements(sanitizeSessionEnhancements(saved.sessionEnhancements));
      void desktopPlatform.publishAppSettings(saved);
    } catch (error) {
      const current = await readAppSettings().catch(() => null);
      if (current) setSessionEnhancements(sanitizeSessionEnhancements(current.sessionEnhancements));
      throw error;
    }
  }

  async function runAutoResume(taskId: string) {
    setAutoResumeRunning(true);
    setAutoResumeError(null);
    try {
      const status = await runAutoResumeNow(taskId);
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
    sessionEnhancements,
    displaySurfaces,
    floatingSettings,
    floatingVisible,
    customAccountDisplayName,
    quotaRefreshIntervalMs,
    settingsError,
    showSetupGuide,
    completeSetupGuide,
    cancelAutoResume,
    refreshAutoResume,
    runAutoResume,
    saveAutoResume,
    saveSessionEnhancements,
    toggleAutostart,
    toggleLiveRate,
    toggleFloatingWindow,
    toggleStatusTrayLiveText,
    updateStatusMetricOrder,
    updateStatusMetricLabelStyle,
    updateStatusSummaryOrder,
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

function sameFloatingSettings(
  left: FloatingWindowSettings,
  right: FloatingWindowSettings,
): boolean {
  return JSON.stringify(left) === JSON.stringify(right);
}
