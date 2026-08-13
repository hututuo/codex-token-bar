import { type CSSProperties, type MouseEvent, useEffect, useMemo, useReducer, useRef, useState } from "react";
import { flushSync } from "react-dom";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { completeFloatingPagingGuide, readAppSettings, recordStartupEvent } from "../api/client";
import { desktopPlatform } from "../platform/desktop";
import { DEFAULT_QUOTA_REFRESH_INTERVAL_MS, sanitizeQuotaRefreshIntervalMs } from "../settings/quotaRefreshCadence";
import { useSharedAccountAttributionSettings } from "../settings/useSharedAccountAttributionSettings";
import {
  INITIAL_FLOATING_SURFACE_LIFECYCLE,
  observeFloatingSurfaceVisibility,
  reduceFloatingSurfaceLifecycle,
} from "../surfaces/surfaceLifecycle";
import { useCompactPanelData } from "../surfaces/useCompactPanelData";
import { useCompactPanelSource } from "../surfaces/useCompactPanelSource";
import { firstPagedFloatingRowCenterY, floatingContentHeight, layoutFloatingContentRows } from "./floatingContent";
import {
  CURRENT_FLOATING_PAGING_GUIDE_REVISION,
  FLOATING_BASE_WIDTH,
  DEFAULT_FLOATING_SETTINGS,
  floatingGradientBackground,
  floatingSettingsCompletingPagingGuide,
  sanitizeFloatingSettings,
  shouldPresentFloatingPagingGuide,
  type FloatingWindowSettings,
} from "./floatingSettings";
import { FloatingPanelSurface } from "./FloatingPanelPreview";
import { FloatingPagingGuide } from "./FloatingPagingGuide";
import { useFloatingCrowdRadar, useFloatingRadar } from "./useFloatingRadar";
import { useFloatingWindowPlacement } from "./useFloatingWindowPlacement";

export function FloatingWindowApp() {
  const [surfaceLifecycle, dispatchSurfaceLifecycle] = useReducer(
    reduceFloatingSurfaceLifecycle,
    INITIAL_FLOATING_SURFACE_LIFECYCLE,
  );
  const [liveRateEnabled, setLiveRateEnabled] = useState(true);
  const [quotaRefreshIntervalMs, setQuotaRefreshIntervalMs] = useState(DEFAULT_QUOTA_REFRESH_INTERVAL_MS);
  const { sourceReady, sourceToken } = useCompactPanelSource(surfaceLifecycle.active);
  const { runningThreads, snapshot } = useCompactPanelData({
    active: surfaceLifecycle.active && sourceReady,
    liveRateEnabled,
    liveRateOwnerToken: "floating-live-rate",
    quotaInitialDelayMs: 0,
    quotaIntervalMs: quotaRefreshIntervalMs,
    sourceToken,
  });
  const [settings, setSettings] = useState<FloatingWindowSettings>(DEFAULT_FLOATING_SETTINGS);
  const [settingsLoaded, setSettingsLoaded] = useState(false);
  const [setupGuideCompleted, setSetupGuideCompleted] = useState(false);
  const [pagingGuideShowsArrowGlyphs, setPagingGuideShowsArrowGlyphs] = useState(false);
  const [pagingGuideDismissed, setPagingGuideDismissed] = useState(false);
  const [pagingGuideSaving, setPagingGuideSaving] = useState(false);
  const [pagingGuideError, setPagingGuideError] = useState<string | null>(null);
  const settingsEventGenerationRef = useRef(0);
  const displaySettingsEventGenerationRef = useRef(0);
  const appSettingsEventGenerationRef = useRef(0);
  const { settings: attributionSettings } = useSharedAccountAttributionSettings();
  const radarSnapshot = useFloatingRadar(surfaceLifecycle.active && sourceReady);
  const crowdRadarSnapshot = useFloatingCrowdRadar(surfaceLifecycle.active && sourceReady);
  useFloatingWindowPlacement();

  useEffect(() => {
    document.documentElement.classList.add("floating-document");
    return () => document.documentElement.classList.remove("floating-document");
  }, []);

  useEffect(() => {
    let cancelled = false;
    const appWindow = getCurrentWindow();

    const recordLayout = async () => {
      await new Promise<void>((resolve) => {
        window.requestAnimationFrame(() => resolve());
      });
      if (cancelled) {
        return;
      }

      const surface = document.querySelector<HTMLElement>(".floating-panel-surface");
      const close = document.querySelector<HTMLElement>(".floating-close-button");
      const surfaceRect = surface?.getBoundingClientRect();
      const closeRect = close?.getBoundingClientRect();
      const [decorated, innerSize, outerSize, title] = await Promise.allSettled([
        appWindow.isDecorated(),
        appWindow.innerSize(),
        appWindow.outerSize(),
        appWindow.title(),
      ]);
      const label = [
        "floating runtime",
        `href=${window.location.href}`,
        `decorated=${settledValue(decorated)}`,
        `inner=${formatSize(settledValue(innerSize))}`,
        `outer=${formatSize(settledValue(outerSize))}`,
        `title=${String(settledValue(title))}`,
        `viewport=${Math.round(window.innerWidth)}x${Math.round(window.innerHeight)}`,
        `surface=${formatRect(surfaceRect)}`,
        `close=${formatRect(closeRect)}`,
      ].join(" ");
      void recordStartupEvent(label);
    };

    void recordLayout().catch((error) => {
      void recordStartupEvent(`floating runtime failed ${String(error)}`);
    });

    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    let disposed = false;
    let unlisten: (() => void) | null = null;
    let unlistenDisplay: (() => void) | null = null;
    let unlistenAppSettings: (() => void) | null = null;

    void desktopPlatform.onFloatingSettingsChanged((payload) => {
      settingsEventGenerationRef.current += 1;
      setSettings(sanitizeFloatingSettings(payload));
    }).then((listener) => {
      if (disposed) {
        listener();
      } else {
        unlisten = listener;
      }
    });

    void desktopPlatform.onDisplaySurfacesChanged((payload) => {
      displaySettingsEventGenerationRef.current += 1;
      setLiveRateEnabled(payload.liveRateEnabled);
      dispatchSurfaceLifecycle({ type: "enabled", value: payload.floatingWindowEnabled });
    }).then((listener) => {
      if (disposed) {
        listener();
      } else {
        unlistenDisplay = listener;
      }
    });

    void desktopPlatform.onAppSettingsChanged((payload) => {
      settingsEventGenerationRef.current += 1;
      displaySettingsEventGenerationRef.current += 1;
      appSettingsEventGenerationRef.current += 1;
      setSettings(sanitizeFloatingSettings(payload.floatingWindow));
      setSettingsLoaded(true);
      setSetupGuideCompleted(payload.setupGuideCompleted);
      setLiveRateEnabled(payload.displaySurfaces.liveRateEnabled);
      setQuotaRefreshIntervalMs(sanitizeQuotaRefreshIntervalMs(payload.quotaRefreshIntervalMs));
      dispatchSurfaceLifecycle({
        type: "enabled",
        value: payload.displaySurfaces.floatingWindowEnabled,
      });
    }).then((listener) => {
      if (disposed) {
        listener();
      } else {
        unlistenAppSettings = listener;
      }
    });

    return () => {
      disposed = true;
      unlisten?.();
      unlistenDisplay?.();
      unlistenAppSettings?.();
    };
  }, []);

  useEffect(() => {
    let cancelled = false;
    const startingSettingsGeneration = settingsEventGenerationRef.current;
    const startingDisplaySettingsGeneration = displaySettingsEventGenerationRef.current;
    const startingAppSettingsGeneration = appSettingsEventGenerationRef.current;

    void readAppSettings().then((settings) => {
      if (!cancelled && settings !== null) {
        if (startingSettingsGeneration === 0 && settingsEventGenerationRef.current === 0) {
          setSettings(sanitizeFloatingSettings(settings.floatingWindow));
        }
        if (
          startingAppSettingsGeneration === 0
          && appSettingsEventGenerationRef.current === 0
        ) {
          setSettingsLoaded(true);
          setSetupGuideCompleted(settings.setupGuideCompleted);
          setQuotaRefreshIntervalMs(sanitizeQuotaRefreshIntervalMs(settings.quotaRefreshIntervalMs));
        }
        if (
          startingDisplaySettingsGeneration === 0
          && displaySettingsEventGenerationRef.current === 0
        ) {
          setLiveRateEnabled(settings.displaySurfaces.liveRateEnabled);
          dispatchSurfaceLifecycle({
            type: "enabled",
            value: settings.displaySurfaces.floatingWindowEnabled,
          });
        }
      }
    }).catch(() => {
      // 保持默认悬浮窗设置；失败已由命令诊断链路记录。
    });

    return () => {
      cancelled = true;
    };
  }, []);

  const pagingGuidePresented = shouldPresentFloatingPagingGuide({
    settingsLoaded,
    setupGuideCompleted,
    pagingGuideDismissed,
    pagingGuideRevision: settings.pagingGuideRevision,
    hasPagedRows: layoutFloatingContentRows(settings.contentVisibility)
      .some((row) => row.groups.length > 1),
  });
  const presentedSettings = useMemo(
    () => pagingGuidePresented
      ? floatingSettingsWithPagingGuideChoice(settings, pagingGuideShowsArrowGlyphs)
      : settings,
    [pagingGuidePresented, pagingGuideShowsArrowGlyphs, settings],
  );

  useEffect(() => {
    return observeFloatingSurfaceVisibility({
      onVisible(visible) {
        dispatchSurfaceLifecycle({ type: "visible", value: Boolean(visible) });
      },
      readVisible: () => getCurrentWindow().isVisible(),
      subscribe: desktopPlatform.onFloatingWindowVisibilityChanged,
    });
  }, []);

  useEffect(() => {
    const height = floatingContentHeight(presentedSettings.contentVisibility);
    void desktopPlatform.resizeFloatingWindow(
      FLOATING_BASE_WIDTH * presentedSettings.scale,
      height * presentedSettings.scale,
    );
  }, [presentedSettings.contentVisibility, presentedSettings.scale]);

  function closeFloatingWindow() {
    void desktopPlatform.hideFloatingWindow().then((visible) => {
      if (!visible) {
        void desktopPlatform.notifyFloatingWindowHidden();
      }
    });
  }

  function openDashboardWindow() {
    void desktopPlatform.showDashboardWindow();
  }

  function startWindowDrag(event: MouseEvent<HTMLElement>) {
    if (event.button !== 0 || event.detail >= 2) {
      event.preventDefault();
      return;
    }
    void desktopPlatform.startFloatingWindowDrag();
  }

  async function completePagingGuide() {
    if (!pagingGuidePresented || pagingGuideSaving) {
      return;
    }
    const previousSettings = settings;
    const immediatelyAppliedSettings = floatingSettingsCompletingPagingGuide(
      previousSettings,
      pagingGuideShowsArrowGlyphs,
    );
    flushSync(() => {
      setSettings(immediatelyAppliedSettings);
      setPagingGuideDismissed(true);
      setPagingGuideSaving(true);
      setPagingGuideError(null);
    });
    try {
      const saved = await completeFloatingPagingGuide(
        pagingGuideShowsArrowGlyphs,
        CURRENT_FLOATING_PAGING_GUIDE_REVISION,
      );
      const next = sanitizeFloatingSettings(saved.floatingWindow);
      setSettings(next);
      void desktopPlatform.publishFloatingSettings(next);
      void desktopPlatform.publishFloatingPagingGuideCompleted({
        pagingGuideRevision: next.pagingGuideRevision,
        showPageNavigationArrows: next.contentVisibility.showPageNavigationArrows,
      });
    } catch (error) {
      flushSync(() => {
        setSettings(previousSettings);
        setPagingGuideDismissed(false);
        setPagingGuideSaving(false);
        setPagingGuideError(`保存失败：${error instanceof Error ? error.message : String(error)}`);
      });
      return;
    }
    setPagingGuideSaving(false);
  }

  const gradientBackground = floatingGradientBackground(presentedSettings);
  const effectColor = effectColorFromGradient(presentedSettings.gradientStart, presentedSettings.gradientEnd);
  const shellStyle = {
    "--floating-card-opacity": presentedSettings.opacity.toFixed(2),
    "--floating-scale": presentedSettings.scale.toFixed(2),
    "--floating-gradient-background": gradientBackground,
    "--floating-effect-color": effectColor.hex,
    "--floating-effect-rgb": effectColor.rgb,
  } as CSSProperties;

  return (
    <main className="floating-window-shell" style={shellStyle}>
      <FloatingPanelSurface
        settings={presentedSettings}
        snapshot={snapshot}
        radarSnapshot={radarSnapshot}
        crowdRadarSnapshot={crowdRadarSnapshot}
        runningThreads={runningThreads}
        unreadEffect={presentedSettings.unreadEffect}
        priceModel={attributionSettings.priceModel}
        onClose={closeFloatingWindow}
        onDragStart={startWindowDrag}
        onOpenDashboard={openDashboardWindow}
        onPageNavigation={() => {
          void completePagingGuide();
        }}
        overlay={pagingGuidePresented ? (
          <FloatingPagingGuide
            error={pagingGuideError}
            saving={pagingGuideSaving}
            showsArrowGlyphs={pagingGuideShowsArrowGlyphs}
            targetX={(FLOATING_BASE_WIDTH / 2 - 24) * presentedSettings.scale}
            targetY={(firstPagedFloatingRowCenterY(presentedSettings.contentVisibility) ?? 60) * presentedSettings.scale}
            onArrowVisibilityChange={setPagingGuideShowsArrowGlyphs}
            onComplete={() => {
              void completePagingGuide();
            }}
          />
        ) : null}
      />
    </main>
  );
}

export function floatingSettingsWithPagingGuideChoice(
  settings: FloatingWindowSettings,
  showPageNavigationArrows: boolean,
): FloatingWindowSettings {
  return sanitizeFloatingSettings({
    ...settings,
    contentVisibility: {
      ...settings.contentVisibility,
      showPageNavigationArrows,
    },
  });
}

function effectColorFromGradient(start: string, end: string): { hex: string; rgb: string } {
  const mixed = mixRgb(parseHexColor(start), parseHexColor(end), 0.58);
  const accent = {
    r: Math.max(0, Math.round(mixed.r * 0.72)),
    g: Math.max(0, Math.round(mixed.g * 0.82)),
    b: Math.min(255, Math.round(mixed.b * 1.08 + 18)),
  };
  return {
    hex: rgbToHex(accent),
    rgb: `${accent.r}, ${accent.g}, ${accent.b}`,
  };
}

function parseHexColor(value: string): { r: number; g: number; b: number } {
  const match = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(value.trim());
  if (!match) {
    return { r: 31, g: 110, b: 210 };
  }
  return {
    r: Number.parseInt(match[1], 16),
    g: Number.parseInt(match[2], 16),
    b: Number.parseInt(match[3], 16),
  };
}

function mixRgb(
  start: { r: number; g: number; b: number },
  end: { r: number; g: number; b: number },
  endWeight: number,
) {
  const startWeight = 1 - endWeight;
  return {
    r: start.r * startWeight + end.r * endWeight,
    g: start.g * startWeight + end.g * endWeight,
    b: start.b * startWeight + end.b * endWeight,
  };
}

function rgbToHex(color: { r: number; g: number; b: number }): string {
  return `#${[color.r, color.g, color.b].map((channel) => channel.toString(16).padStart(2, "0")).join("")}`;
}

function settledValue<T>(result: PromiseSettledResult<T>): T | string {
  if (result.status === "fulfilled") {
    return result.value;
  }
  return `error:${String(result.reason)}`;
}

function formatSize(value: unknown): string {
  if (typeof value === "object" && value !== null && "width" in value && "height" in value) {
    const size = value as { width: number; height: number };
    return `${Math.round(size.width)}x${Math.round(size.height)}`;
  }
  return String(value);
}

function formatRect(rect: DOMRect | undefined): string {
  if (!rect) {
    return "missing";
  }
  return `${Math.round(rect.x)},${Math.round(rect.y)},${Math.round(rect.width)}x${Math.round(rect.height)}`;
}
