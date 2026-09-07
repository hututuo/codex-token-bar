import { FloatingEdgeQuotaStrip } from "./FloatingPanelPreview";
import { useFloatingEdgeDock } from "./useFloatingEdgeDock";
import { type CSSProperties, type MouseEvent, useCallback, useEffect, useLayoutEffect, useMemo, useReducer, useRef, useState } from "react";
import { flushSync } from "react-dom";
import { currentMonitor, getCurrentWindow } from "@tauri-apps/api/window";
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
import {
  embedsRunningThreadsInMetricsRow,
  floatingContentHeight,
  hasRunningThreadDetailsTarget,
  layoutFloatingContentRows,
  pagedFloatingRowCenterYs,
  runningThreadsFloatingRowCenterY,
  usageStatusFloatingRowCenterY,
} from "./floatingContent";
import {
  CURRENT_FLOATING_PAGING_GUIDE_REVISION,
  FLOATING_BASE_WIDTH,
  FLOATING_PAGING_LEARNED_REVISION,
  FLOATING_PAGING_GUIDE_HEIGHT,
  FLOATING_PAGING_GUIDE_WIDTH,
  FLOATING_RUNNING_MODEL_DETAILS_MIN_HEIGHT,
  DEFAULT_FLOATING_SETTINGS,
  floatingGuidePages,
  floatingSettingsCompletingPagingGuide,
  sanitizeFloatingSettings,
  shouldPresentFloatingPagingGuide,
  type FloatingWindowSettings,
} from "./floatingSettings";
import { floatingPanelAppearance } from "./floatingPresentation";
import { FloatingPanelSurface } from "./FloatingPanelPreview";
import { FloatingPagingGuide } from "./FloatingPagingGuide";
import {
  FloatingRunningThreadModelDetails,
  floatingRunningThreadSummaryForPresentation,
} from "./FloatingRunningThreadModelDetails";
import { useFloatingCrowdRadar, useFloatingRadar } from "./useFloatingRadar";
import {
  floatingDockShellMetrics,
  resolveFloatingDetailsDrawer,
  type FloatingRunningModelDetailsPlacement,
} from "./floatingWindowPlacement";
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
    backgroundAggregateEnabled: true,
    quotaInitialDelayMs: 0,
    quotaIntervalMs: quotaRefreshIntervalMs,
    quotaSource: "direct",
    sourceToken,
  });
  const [settings, setSettings] = useState<FloatingWindowSettings>(DEFAULT_FLOATING_SETTINGS);
  const [settingsLoaded, setSettingsLoaded] = useState(false);
  const [setupGuideCompleted, setSetupGuideCompleted] = useState(false);
  const [pagingGuideShowsArrowGlyphs, setPagingGuideShowsArrowGlyphs] = useState(false);
  const [pagingGuidePageIndex, setPagingGuidePageIndex] = useState(0);
  const [pagingGuideDismissed, setPagingGuideDismissed] = useState(false);
  const [pagingGuideSaving, setPagingGuideSaving] = useState(false);
  const [pagingGuideError, setPagingGuideError] = useState<string | null>(null);
  const [runningModelDetailsExpanded, setRunningModelDetailsExpanded] = useState(false);
  const [runningModelDetailsSide, setRunningModelDetailsSide] = useState<FloatingRunningModelDetailsPlacement>("below");
  const [drawerMetrics, setDrawerMetrics] = useState({ height: 96, offset: 0 });
  const [runningModelDetailsHeight, setRunningModelDetailsHeight] = useState(
    FLOATING_RUNNING_MODEL_DETAILS_MIN_HEIGHT,
  );
  const runningModelDetailsBasePositionRef = useRef<{ x: number; y: number } | null>(null);
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

  const contentHasPagedRows = layoutFloatingContentRows(settings.contentVisibility)
    .some((row) => row.groups.length > 1);
  const contentHasRunningThreadDetailsTarget = hasRunningThreadDetailsTarget(
    settings.contentVisibility,
  );
  const pagingGuidePages = floatingGuidePages({
    pagingGuideRevision: settings.pagingGuideRevision,
    hasPagedRows: contentHasPagedRows,
    hasRunningThreadDetailsTarget: contentHasRunningThreadDetailsTarget,
  });
  const pagingGuidePresented = shouldPresentFloatingPagingGuide({
    settingsLoaded,
    setupGuideCompleted,
    pagingGuideDismissed,
    pagingGuideRevision: settings.pagingGuideRevision,
    hasPagedRows: contentHasPagedRows,
    hasRunningThreadDetailsTarget: contentHasRunningThreadDetailsTarget,
  });
  const safePagingGuidePageIndex = Math.min(
    Math.max(0, pagingGuidePageIndex),
    Math.max(0, pagingGuidePages.length - 1),
  );
  const activePagingGuidePage = pagingGuidePages[safePagingGuidePageIndex] ?? "runningModels";
  const effectiveRunningModelDetailsExpanded = runningModelDetailsExpanded
    && !pagingGuidePresented
    && contentHasRunningThreadDetailsTarget;
  const edgeDock = useFloatingEdgeDock(
    settingsLoaded,
    pagingGuidePresented || !surfaceLifecycle.active,
    effectiveRunningModelDetailsExpanded,
  );
  const dock = edgeDock.presentation;
  const dockAnchor = dock.anchor;
  const dockShellRef = useRef<HTMLDivElement | null>(null);
  const previousDockAnchor = useRef(dockAnchor);
  useLayoutEffect(() => {
    const shell = dockShellRef.current;
    const previous = previousDockAnchor.current;
    previousDockAnchor.current = dockAnchor;
    if (previous && dockAnchor) {
      const extra = (dockAnchor.frame.height - previous.frame.height) / dockAnchor.scaleFactor;
      const host = shell?.parentElement;
      if (extra > 1 && effectiveRunningModelDetailsExpanded && host && !window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
        const inset = runningModelDetailsSide === "above" ? `${extra}px 0 0 0` : `0 0 ${extra}px 0`;
        const animation = host.animate([{ clipPath: `inset(${inset})` }, { clipPath: "inset(0px)" }],
          { duration: 220, easing: "cubic-bezier(.25,.46,.3,1)" });
        return () => animation.cancel();
      }
      return;
    }
    if (!dockAnchor || !shell || typeof shell.animate !== "function"
      || window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const { frame, lip, edge } = dockAnchor;
    const centered = edge === "top" || edge === "bottom" ? "translateX(-50%) " : "";
    // Only initial attachment uses a keyframe. Reversing an in-flight hover
    // transition keeps the browser's current interpolated transform instead.
    const animation = shell.animate([
      { transform: `${centered}scale(${lip.width / frame.width}, ${lip.height / frame.height})` },
      { transform: centered || "none" },
    ], { duration: 260, easing: "cubic-bezier(.25, .46, .3, 1)" });
    return () => animation.cancel();
  }, [dockAnchor]);
  const dockScale = dockAnchor?.scaleFactor ?? 1;
  const dockWidth = (dockAnchor?.frame.width ?? 1) / dockScale;
  const dockHeight = (dockAnchor?.frame.height ?? 1) / dockScale;
  const presentedRunningThreads = floatingRunningThreadSummaryForPresentation(
    runningThreads,
    pagingGuidePresented,
    activePagingGuidePage,
  );
  const presentedSettings = useMemo(
    () => pagingGuidePresented
      ? floatingSettingsWithPagingGuideChoice(settings, pagingGuideShowsArrowGlyphs)
      : settings,
    [pagingGuidePresented, pagingGuideShowsArrowGlyphs, settings],
  );

  useEffect(() => {
    if (pagingGuidePresented) {
      setRunningModelDetailsExpanded(false);
    }
  }, [pagingGuidePresented]);

  useEffect(() => {
    if (!contentHasRunningThreadDetailsTarget) {
      setRunningModelDetailsExpanded(false);
    }
  }, [contentHasRunningThreadDetailsTarget]);

  const handleRunningModelDetailsHeightChange = useCallback((height: number) => {
    const next = Math.max(1, Math.ceil(height));
    setRunningModelDetailsHeight((current) => current === next ? current : next);
  }, []);

  useEffect(() => {
    if (!effectiveRunningModelDetailsExpanded) {
      return undefined;
    }
    function closeForWindowBlur() {
      setRunningModelDetailsExpanded(false);
    }
    const closeForEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); setRunningModelDetailsExpanded(false); }
    };
    window.addEventListener("blur", closeForWindowBlur);
    window.addEventListener("keydown", closeForEscape);
    return () => { window.removeEventListener("blur", closeForWindowBlur); window.removeEventListener("keydown", closeForEscape); };
  }, [effectiveRunningModelDetailsExpanded]);

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
    let cancelled = false;
    const scale = presentedSettings.scale;
    const targetWidth = Math.max(FLOATING_BASE_WIDTH, pagingGuidePresented ? FLOATING_PAGING_GUIDE_WIDTH : 0) * scale;
    const mainHeight = floatingContentHeight(presentedSettings.contentVisibility) * scale;
    const surfaceHeight = pagingGuidePresented ? mainHeight
      : floatingDockShellMetrics({ width: targetWidth, mainHeight, scale }).height;

    const reconcileWindowGeometry = async () => {
      const appWindow = getCurrentWindow();
      let basePosition = runningModelDetailsBasePositionRef.current;
      let targetPosition = basePosition ?? undefined;
      let targetHeight = Math.max(surfaceHeight, pagingGuidePresented ? FLOATING_PAGING_GUIDE_HEIGHT * scale : 0);
      let placement: FloatingRunningModelDetailsPlacement = "below";
      let nextMetrics = { height: FLOATING_RUNNING_MODEL_DETAILS_MIN_HEIGHT * scale, offset: 0 };
      if (effectiveRunningModelDetailsExpanded) {
        const [monitor, factor, position] = await Promise.all([
          currentMonitor(), appWindow.scaleFactor(), appWindow.outerPosition(),
        ]);
        const dockFrame = edgeDock.expandedFrame();
        basePosition ??= { x: dockFrame?.x ?? position.x, y: dockFrame?.y ?? position.y };
        const base = { ...basePosition, width: targetWidth * factor, height: surfaceHeight * factor };
        const workArea = monitor ? {
          x: monitor.workArea.position.x, y: monitor.workArea.position.y,
          width: monitor.workArea.size.width, height: monitor.workArea.size.height,
        } : { x: base.x, y: base.y, width: base.width, height: base.height + 332 * scale * factor };
        const drawer = resolveFloatingDetailsDrawer({ base, workArea,
          detailsHeight: Math.min(320 * scale, Math.max(FLOATING_RUNNING_MODEL_DETAILS_MIN_HEIGHT * scale, runningModelDetailsHeight)) * factor,
          gap: 8 * scale * factor, inset: 4 * scale * factor, minimumDetailsHeight: 96 * scale * factor,
        });
        placement = drawer.placement;
        targetHeight = drawer.frame.height / factor;
        targetPosition = { x: drawer.frame.x, y: drawer.frame.y };
        nextMetrics = { height: drawer.detailsHeight / factor, offset: drawer.surfaceOffsetY / factor };
      }
      if (cancelled) return;
      if (effectiveRunningModelDetailsExpanded) runningModelDetailsBasePositionRef.current = basePosition;
      // Keep the same attachment edge until the native close resize finishes.
      if (effectiveRunningModelDetailsExpanded) setRunningModelDetailsSide(placement);
      setDrawerMetrics(current => current.height === nextMetrics.height && current.offset === nextMetrics.offset ? current : nextMetrics);
      const resized = await desktopPlatform.resizeFloatingWindow(targetWidth, targetHeight, { targetPosition });
      if (!resized && effectiveRunningModelDetailsExpanded && !cancelled) setRunningModelDetailsExpanded(false);
      if (!effectiveRunningModelDetailsExpanded && !cancelled) {
        runningModelDetailsBasePositionRef.current = null;
        setRunningModelDetailsSide("below");
      }
    };
    void reconcileWindowGeometry().catch(error => console.warn("Floating details layout failed", error));
    return () => { cancelled = true; };
  }, [
    effectiveRunningModelDetailsExpanded,
    pagingGuidePresented,
    presentedSettings.contentVisibility,
    presentedSettings.scale,
    runningModelDetailsHeight,
  ]);

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
    edgeDock.startDrag();
  }

  function dismissRunningModelDetailsForOutsidePointer(event: MouseEvent<HTMLElement>) {
    if (!effectiveRunningModelDetailsExpanded) {
      return;
    }
    const target = event.target as HTMLElement | null;
    if (target?.closest?.(".floating-running-model-details, .floating-running-model-trigger")) {
      return;
    }
    setRunningModelDetailsExpanded(false);
  }

  async function completePagingGuide() {
    if (!pagingGuidePresented || pagingGuideSaving) {
      return;
    }
    const completedRevision = pagingGuidePages.includes("runningModels")
      ? CURRENT_FLOATING_PAGING_GUIDE_REVISION
      : FLOATING_PAGING_LEARNED_REVISION;
    const previousSettings = settings;
    const immediatelyAppliedSettings = floatingSettingsCompletingPagingGuide(
      previousSettings,
      pagingGuideShowsArrowGlyphs,
      completedRevision,
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
        completedRevision,
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
    setPagingGuidePageIndex(0);
  }

  function advancePagingGuide() {
    if (safePagingGuidePageIndex + 1 < pagingGuidePages.length) {
      setPagingGuidePageIndex(safePagingGuidePageIndex + 1);
      return;
    }
    void completePagingGuide();
  }

  const mainCardHeight = floatingContentHeight(presentedSettings.contentVisibility) * presentedSettings.scale;
  const dockShellMetrics = floatingDockShellMetrics({ width: dockWidth, mainHeight: mainCardHeight, scale: presentedSettings.scale });
  const dockStyle = dockAnchor ? {
    "--dock-width": `${dockWidth}px`,
    "--dock-height": `${dockHeight}px`,
    "--dock-lip-width": `${dockAnchor.lip.width / dockScale}px`,
    "--dock-lip-height": `${dockAnchor.lip.height / dockScale}px`,
    "--dock-lip-x": `${(dockAnchor.lip.x - dockAnchor.frame.x) / dockScale}px`,
    "--dock-lip-y": `${(dockAnchor.lip.y - dockAnchor.frame.y) / dockScale}px`,
    "--dock-lip-scale-x": dockAnchor.lip.width / dockAnchor.frame.width,
    "--dock-lip-scale-y": dockAnchor.lip.height / dockAnchor.frame.height,
    "--dock-content-scale": dockShellMetrics.contentScale,
    "--dock-content-offset-y": `${runningModelDetailsSide === "above" ? -dockShellMetrics.contentOffsetY : dockShellMetrics.contentOffsetY}px`,
    "--dock-radius-x": `${dockShellMetrics.radiusX}px`,
    "--dock-radius-y": `${dockShellMetrics.radiusY}px`,
    "--dock-content-origin": runningModelDetailsSide === "above" ? "center bottom" : "center top",
    "--dock-travel-x": `${dockAnchor.edge === "left" ? -dockWidth : dockAnchor.edge === "right" ? dockWidth : 0}px`,
    "--dock-travel-y": `${dockAnchor.edge === "top" ? -dockHeight : dockAnchor.edge === "bottom" ? dockHeight : 0}px`,
  } as CSSProperties : undefined;
  const { style: appearanceStyle } = floatingPanelAppearance(presentedSettings);
  const shellStyle = {
    ...appearanceStyle,
    "--floating-shell-padding-y": `${pagingGuidePresented ? 0 : 6 * presentedSettings.scale}px`,
    "--floating-drawer-height": `${drawerMetrics.height}px`,
    "--floating-drawer-offset": `${drawerMetrics.offset}px`,
  } as CSSProperties;
  const guideScale = presentedSettings.scale;
  const pagingGuideTargetYs = pagedFloatingRowCenterYs(presentedSettings.contentVisibility)
    .slice(0, 2)
    .map((value) => value * guideScale);
  const safePagingGuideTargetYs = pagingGuideTargetYs.length > 0 ? pagingGuideTargetYs : [60 * guideScale];
  const pagingGuideTargetY = safePagingGuideTargetYs[0];
  const pagingGuidePointerY = pagingGuideTargetY + 5 * guideScale;
  const pagingGuidePointerYs = safePagingGuideTargetYs.map((value) => value + 5 * guideScale);
  const pagingGuideCalloutY = Math.max(
    6 * guideScale,
    (usageStatusFloatingRowCenterY(presentedSettings.contentVisibility) ?? 60) * guideScale - 5 * guideScale,
  );
  const calloutImageWidth = Math.max(0, (220 - 14) * guideScale);
  const calloutCardHeight = calloutImageWidth * (2 / 3) + 16 * guideScale;
  const calloutSafeInset = 6 * guideScale;
  const calloutCardMinimumY = calloutCardHeight / 2 + calloutSafeInset;
  const calloutCardMaximumY = Math.max(
    calloutCardMinimumY,
    FLOATING_PAGING_GUIDE_HEIGHT * guideScale - calloutCardHeight / 2 - calloutSafeInset,
  );
  const pagingGuideCalloutCardY = Math.min(
    Math.max(pagingGuideCalloutY, calloutCardMinimumY),
    calloutCardMaximumY,
  );
  const runningModelsEmbedded = embedsRunningThreadsInMetricsRow(
    presentedSettings.contentVisibility,
  );
  const runningModelsTargetX = (runningModelsEmbedded
    ? FLOATING_BASE_WIDTH - 41
    : FLOATING_BASE_WIDTH / 2) * guideScale;
  const runningModelsTargetWidth = (runningModelsEmbedded
    ? 70
    : FLOATING_BASE_WIDTH - 20) * guideScale;
  const runningModelsTargetY = (
    runningThreadsFloatingRowCenterY(presentedSettings.contentVisibility)
      ?? floatingContentHeight(presentedSettings.contentVisibility) / 2
  ) * guideScale;

  return (
    <div className="floating-edge-host"
      data-edge={dockAnchor?.edge ?? "free"}
      data-collapsed={dock.collapsed}
      data-compact={dock.compact}
      data-rail-ready={dock.railReady}
      data-motion={dock.motion}
      onMouseEnter={() => edgeDock.hover(true)}
      onMouseLeave={() => edgeDock.hover(false)}
      style={dockStyle}
    >
    {dockAnchor ? <div className="floating-edge-base" aria-hidden="true" /> : null}
    <div ref={dockShellRef} className="floating-edge-shell" aria-hidden="true" />
    <div className="floating-edge-content" inert={dock.collapsed} aria-hidden={dock.collapsed || undefined}>
    <main
      className={`floating-window-shell${pagingGuidePresented ? " floating-window-shell--guide" : ""}${effectiveRunningModelDetailsExpanded ? " floating-window-shell--running-model-details" : ""}${runningModelDetailsSide === "above" ? " floating-window-shell--running-model-details-above" : ""}`}
      onMouseDownCapture={dismissRunningModelDetailsForOutsidePointer}
      style={shellStyle}
    >
      <FloatingPanelSurface
        settings={presentedSettings}
        snapshot={snapshot}
        radarSnapshot={radarSnapshot}
        crowdRadarSnapshot={crowdRadarSnapshot}
        runningThreads={presentedRunningThreads}
        unreadEffect={dock.collapsed ? "off" : presentedSettings.unreadEffect}
        priceModel={attributionSettings.priceModel}
        onClose={closeFloatingWindow}
        onDragStart={effectiveRunningModelDetailsExpanded ? undefined : startWindowDrag}
        onOpenDashboard={effectiveRunningModelDetailsExpanded ? undefined : openDashboardWindow}
        runningModelDetailsExpanded={effectiveRunningModelDetailsExpanded}
        runningModelDetailsSide={runningModelDetailsSide}
        onRunningThreadsActivate={pagingGuidePresented ? undefined : () => {
          setRunningModelDetailsExpanded((expanded) => !expanded);
        }}
        guideMode={pagingGuidePresented && activePagingGuidePage === "paging"}
        guideOverlayVisible={pagingGuidePresented}
        overlay={pagingGuidePresented ? (
          <FloatingPagingGuide
            page={activePagingGuidePage}
            isLastPage={safePagingGuidePageIndex === pagingGuidePages.length - 1}
            error={pagingGuideError}
            saving={pagingGuideSaving}
            showsArrowGlyphs={pagingGuideShowsArrowGlyphs}
            targetX={(FLOATING_BASE_WIDTH / 2 - 24) * guideScale}
            targetY={pagingGuideTargetY}
            pointerY={pagingGuidePointerY}
            targetYs={safePagingGuideTargetYs}
            pointerYs={pagingGuidePointerYs}
            calloutY={pagingGuideCalloutY}
            calloutCardY={pagingGuideCalloutCardY}
            showDemoModelUsage={snapshot.todayModelBreakdowns.length === 0}
            modelTargetX={runningModelsTargetX}
            modelTargetY={runningModelsTargetY}
            modelTargetWidth={runningModelsTargetWidth}
            onArrowVisibilityChange={setPagingGuideShowsArrowGlyphs}
            onAdvance={advancePagingGuide}
          />
        ) : effectiveRunningModelDetailsExpanded ? (
          <FloatingRunningThreadModelDetails
            onClose={() => setRunningModelDetailsExpanded(false)}
            onHeightChange={handleRunningModelDetailsHeightChange}
            summary={runningThreads}
          />
        ) : null}
      />
    </main>
    </div>
    {dockAnchor ? <button className="floating-edge-reveal" onClick={edgeDock.reveal}
      aria-label="展开边缘悬浮窗" type="button" disabled={!dock.collapsed} aria-hidden={!dock.collapsed} tabIndex={dock.collapsed ? 0 : -1}>
      <FloatingEdgeQuotaStrip snapshot={snapshot} settings={presentedSettings} />
    </button> : null}
    </div>
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
