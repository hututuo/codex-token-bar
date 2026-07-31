import {
  startTransition,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { readAppSettings, recordStartupEvent, subscribeCommandDiagnostics } from "../api/client";
import { recordPerformanceEvent } from "../api/startupClient";
import { dashboardDataSource, type DashboardDataSource } from "../data/dashboardDataSource";
import { desktopPlatform } from "../platform/desktop";
import type { EventSubscriptionResult } from "../platform/desktopBridge";
import {
  DEFAULT_QUOTA_REFRESH_INTERVAL_MS,
  sanitizeQuotaRefreshIntervalMs,
} from "../settings/quotaRefreshCadence";
import type {
  AccountQuotaBundle,
  CodexHomeSourceEnvelope,
  DashboardSnapshot,
  LiveRateSnapshot,
  LiveThreadOption,
  UsageCacheStatus,
} from "../types/dashboard";
import {
  disabledLiveRateSnapshot,
  initialDashboardState,
  mergeLiveRate,
  mergeLiveThreadOptions,
  markPreciseRecentUsageStale,
  mergePreciseDashboard,
  mergeQuota,
  pendingLiveRateSnapshot,
  pendingRepairSnapshot,
  visibleDashboardState,
  type DashboardAppState,
} from "./dashboardState";
import {
  applyDashboardRefreshPlan,
  makeDashboardRefreshPlan,
  makeDashboardWakeRefreshContext,
} from "./dashboardRefreshPlan";
import {
  acceptDashboardSourceEnvelope,
  acceptDashboardSourceResponse,
  createDashboardSourceTransition,
  dashboardSourceTokenMatches,
  type DashboardSourceToken,
} from "./dashboardSourceTransition";
import { makeQuotaAutoRefreshPlan } from "./quotaAutoRefreshModel";
import {
  advanceQuotaComparisonObservation,
  alignQuotaComparisonObservation,
  type QuotaComparisonObservationState,
} from "./quotaComparisonObservation";
import { loadInitialDashboardState } from "./loadInitialDashboardState";
import { planPreciseUsageCatchUp } from "./preciseUsageCatchUp";
import { publishPreciseUsageFailure } from "./preciseUsageFailureChannel";
import { useDashboardActions } from "./useDashboardActions";
import { useDeferredDashboardLoads } from "./useDeferredDashboardLoads";
import { useLiveRateFeed } from "./useLiveRateFeed";
import { useRunningThreadSummary } from "./useRunningThreadSummary";
import { nextQuotaResetRefreshDelayMs } from "../utils/quotaRefresh";
import { useWakeRefresh } from "../utils/useWakeRefresh";

const DASHBOARD_VISIBLE_AUTO_REFRESH_INTERVAL_MS = 3 * 60 * 1000;
const DASHBOARD_BACKGROUND_AUTO_REFRESH_INTERVAL_MS = 5 * 60 * 1000;
export const MAIN_SOURCE_RECONCILE_INTERVAL_MS = 30_000;

function scheduleMainSourceReconcile(refresh: () => void, intervalMs: number) {
  const interval = window.setInterval(refresh, intervalMs);
  return () => window.clearInterval(interval);
}

function dashboardIsVisible() {
  if (typeof document === "undefined") {
    return true;
  }
  return document.visibilityState !== "hidden";
}

interface UseDashboardDataOptions {
  liveRateEnabled?: boolean;
  providerRepairVisible?: boolean;
  source?: DashboardDataSource;
  subscribeToSourceChanges?: (
    handler: (envelope: CodexHomeSourceEnvelope) => void,
  ) => Promise<EventSubscriptionResult>;
  scheduleSourceReconcile?: (refresh: () => void, intervalMs: number) => () => void;
}

export function useDashboardData(options: UseDashboardDataOptions = {}) {
  const source = options.source ?? dashboardDataSource;
  const liveRateEnabled = options.liveRateEnabled ?? true;
  const providerRepairVisible = options.providerRepairVisible ?? false;
  const subscribeToSourceChanges = options.subscribeToSourceChanges
    ?? desktopPlatform.onCodexHomeSourceChanged;
  const scheduleSourceReconcile = options.scheduleSourceReconcile ?? scheduleMainSourceReconcile;
  const [state, setState] = useState<DashboardAppState>(initialDashboardState);
  const [fastSnapshotLoaded, setFastSnapshotLoaded] = useState(false);
  const [loadGeneration, setLoadGeneration] = useState(0);
  const [quotaLoadGeneration, setQuotaLoadGeneration] = useState(0);
  const [radarRefreshGeneration, setRadarRefreshGeneration] = useState(0);
  const [liveRateRetryGeneration, setLiveRateRetryGeneration] = useState(0);
  const [forceNextQuotaLoad, setForceNextQuotaLoad] = useState(false);
  const [dashboardVisible, setDashboardVisible] = useState(dashboardIsVisible);
  const [refreshTaskCount, setRefreshTaskCount] = useState(0);
  const [usageCacheInitializing, setUsageCacheInitializing] = useState(false);
  const [quotaRefreshIntervalMs, setQuotaRefreshIntervalMs] = useState(DEFAULT_QUOTA_REFRESH_INTERVAL_MS);
  const [sourceToken, setSourceToken] = useState<DashboardSourceToken | null>(null);
  const [sourceLoadGeneration, setSourceLoadGeneration] = useState(0);
  const [selectedLiveThreadId, setSelectedLiveThreadId] = useState("");
  const sourceTransitionRef = useRef(createDashboardSourceTransition());
  const sourceReconcileRequestRef = useRef(0);
  const sourceReconcileInFlightRef = useRef<Promise<CodexHomeSourceEnvelope | null> | null>(null);
  const quotaComparisonObservationRef = useRef<QuotaComparisonObservationState | null>(null);
  const latestComparisonUpdatedAtRef = useRef<string | null>(null);
  const preciseCatchUpQuotaRef = useRef<string | null>(null);
  const attributionPreciseRefreshRef = useRef<string | null>(null);
  const latestPreciseCoverageRef = useRef<string | null>(null);
  latestPreciseCoverageRef.current = state.dashboard?.preciseRecentUsageCoveredAt ?? null;
  const markRenderCommit = useRenderCommitPerformanceTrace(state.dashboard);

  // 本地命令失败诊断接入 state.diagnostics（订阅即回放当前快照），
  // 否则 recordCommandFailure 记下的失败没有任何消费者、恒不可见。
  useEffect(() => subscribeCommandDiagnostics((diagnostics) => {
    setState((current) => ({ ...current, diagnostics }));
  }), []);

  const captureSourceToken = useCallback(
    () => sourceTransitionRef.current.sourceToken,
    [],
  );
  const isSourceTokenCurrent = useCallback(
    (token: DashboardSourceToken | null) => dashboardSourceTokenMatches(
      sourceTransitionRef.current,
      token,
    ),
    [],
  );
  const acceptSourceEnvelope = useCallback((envelope: CodexHomeSourceEnvelope) => {
    const result = acceptDashboardSourceEnvelope(sourceTransitionRef.current, envelope);
    if (!result.accepted) {
      return false;
    }

    sourceTransitionRef.current = result.transition;
    const acceptedSourceToken = result.transition.sourceToken;
    const startsSourceLoad = result.initialized || result.sourceChanged;
    setState((current) => isSourceTokenCurrent(acceptedSourceToken)
      ? {
          ...current,
          codexHome: envelope.codexHome,
          dashboard: result.sourceChanged ? null : current.dashboard,
          liveRate: result.sourceChanged ? pendingLiveRateSnapshot() : current.liveRate,
          liveThreadOptions: result.sourceChanged ? [] : current.liveThreadOptions,
          repair: result.sourceChanged ? pendingRepairSnapshot() : current.repair,
          loading: startsSourceLoad ? true : current.loading,
        }
      : current);

    if (!startsSourceLoad || acceptedSourceToken === null) {
      return true;
    }

    setSourceToken((current) => isSourceTokenCurrent(acceptedSourceToken)
      ? acceptedSourceToken
      : current);
    setFastSnapshotLoaded(false);
    setSelectedLiveThreadId("");
    setForceNextQuotaLoad(false);
    setRefreshTaskCount(0);
    setUsageCacheInitializing(false);

    if (result.sourceChanged) {
      quotaComparisonObservationRef.current = null;
      latestComparisonUpdatedAtRef.current = null;
      preciseCatchUpQuotaRef.current = null;
      attributionPreciseRefreshRef.current = null;
      setLoadGeneration((current) => current + 1);
      setQuotaLoadGeneration((current) => current + 1);
      setRadarRefreshGeneration((current) => current + 1);
      setLiveRateRetryGeneration((current) => current + 1);
    } else {
      void recordStartupEvent("codex home ready");
    }
    return true;
  }, [isSourceTokenCurrent]);
  const refreshCurrentSource = useCallback((token: DashboardSourceToken) => {
    if (!isSourceTokenCurrent(token)) {
      return;
    }
    setState((current) => isSourceTokenCurrent(token)
      ? { ...current, loading: true }
      : current);
    setSourceLoadGeneration((current) => isSourceTokenCurrent(token) ? current + 1 : current);
  }, [isSourceTokenCurrent]);
  const reconcileCodexHomeSource = useCallback(async () => {
    if (sourceReconcileInFlightRef.current !== null) {
      return sourceReconcileInFlightRef.current;
    }
    const request = sourceReconcileRequestRef.current;
    let pending!: Promise<CodexHomeSourceEnvelope | null>;
    pending = (async () => {
      try {
        const envelope = await source.getCodexHome();
        if (request === sourceReconcileRequestRef.current && envelope !== null) {
          acceptSourceEnvelope(envelope);
        }
        return request === sourceReconcileRequestRef.current ? envelope : null;
      } catch {
        return null;
      } finally {
        if (sourceReconcileInFlightRef.current === pending) {
          sourceReconcileInFlightRef.current = null;
        }
      }
    })();
    sourceReconcileInFlightRef.current = pending;
    return pending;
  }, [acceptSourceEnvelope, source]);

  const {
    reloadAll,
    reloadQuota,
    acknowledgeUnread,
    updateCodexHome,
    restoreAutoCodexHome,
    updateProviderRepair,
  } = useDashboardActions({
    source,
    providerRepairVisible,
    setState,
    setLoadGeneration,
    setQuotaLoadGeneration,
    setRadarRefreshGeneration,
    setForceNextQuotaLoad,
    acceptSourceEnvelope,
    captureSourceToken,
    isSourceTokenCurrent,
    refreshCurrentSource,
    sourceToken,
  });

  const mergePreciseSnapshot = useCallback((precise: DashboardSnapshot) => {
    if (!isSourceTokenCurrent(sourceToken)) {
      return;
    }
    markRenderCommit("frontend precise dashboard");
    startTransition(() => {
      setState((current) => isSourceTokenCurrent(sourceToken)
        ? mergePreciseDashboard(current, precise)
        : current);
    });
    const catchUp = planPreciseUsageCatchUp({
      quotaUpdatedAt: latestComparisonUpdatedAtRef.current,
      preciseCoveredAt: precise.preciseRecentUsageCoveredAt,
      preciseFresh: precise.preciseRecentUsageFresh,
      requestedForQuotaUpdatedAt: preciseCatchUpQuotaRef.current,
    });
    preciseCatchUpQuotaRef.current = catchUp.requestedForQuotaUpdatedAt;
    if (catchUp.shouldSchedule) {
      setLoadGeneration((current) => isSourceTokenCurrent(sourceToken) ? current + 1 : current);
    }
  }, [isSourceTokenCurrent, markRenderCommit, sourceToken]);

  const markPreciseSnapshotStale = useCallback(() => {
    if (!isSourceTokenCurrent(sourceToken)) {
      return;
    }
    setState((current) => isSourceTokenCurrent(sourceToken)
      ? markPreciseRecentUsageStale(current)
      : current);
  }, [isSourceTokenCurrent, sourceToken]);

  const markPreciseSnapshotFailure = useCallback(() => {
    if (!isSourceTokenCurrent(sourceToken) || sourceToken === null) return;
    const sourceHomeIdentity = `${sourceToken.canonicalHomeKey}\u0000${sourceToken.physicalHomeKey}`;
    const coveredAt = latestPreciseCoverageRef.current;
    const coveredAtMillis = coveredAt === null ? Number.NaN : Date.parse(coveredAt);
    publishPreciseUsageFailure(
      sourceHomeIdentity,
      Number.isFinite(coveredAtMillis) ? coveredAtMillis / 1_000 : Date.now() / 1_000,
    );
  }, [isSourceTokenCurrent, sourceToken]);

  const mergeQuotaSnapshot = useCallback((quota: AccountQuotaBundle) => {
    if (!isSourceTokenCurrent(sourceToken)) {
      return;
    }
    markRenderCommit("frontend quota dashboard");
    const comparison = advanceQuotaComparisonObservation(
      quotaComparisonObservationRef.current,
      {
        quotaDataFresh: !quota.diagnostics.some((diagnostic) => (
          diagnostic.staleDataDisplayed || diagnostic.category === "stale_cached_data"
        )),
        updatedAt: quota.updatedAt,
        resetAtUnix: quota.quota.sevenDay.resetsAtUnix,
        usedPercent: quota.quota.sevenDay.usedPercent,
        identity: quota.attributionIdentity,
      },
    );
    quotaComparisonObservationRef.current = comparison.state;
    latestComparisonUpdatedAtRef.current = comparison.state?.comparisonUpdatedAt ?? null;
    startTransition(() => {
      setState((current) => isSourceTokenCurrent(sourceToken)
        ? mergeQuota(current, quota)
        : current);
    });
    // Poll timestamps alone are not a comparison boundary. Exact usage catches
    // up only after a substantive account/reset/used-percent transition.
    if (comparison.shouldRefreshPreciseUsage) {
      attributionPreciseRefreshRef.current = comparison.state?.comparisonUpdatedAt ?? quota.updatedAt;
      setLoadGeneration((current) => isSourceTokenCurrent(sourceToken) ? current + 1 : current);
    }
  }, [isSourceTokenCurrent, markRenderCommit, sourceToken]);

  const refreshAttributionPreciseUsage = useCallback((comparisonUpdatedAt: string) => {
    if (!isSourceTokenCurrent(sourceToken)
      || !Number.isFinite(Date.parse(comparisonUpdatedAt))) {
      return;
    }
    const alreadyRequested = attributionPreciseRefreshRef.current === comparisonUpdatedAt;
    attributionPreciseRefreshRef.current = comparisonUpdatedAt;
    quotaComparisonObservationRef.current = alignQuotaComparisonObservation(
      quotaComparisonObservationRef.current,
      comparisonUpdatedAt,
    );
    const previousMillis = latestComparisonUpdatedAtRef.current === null
      ? Number.NEGATIVE_INFINITY
      : Date.parse(latestComparisonUpdatedAtRef.current);
    if (Date.parse(comparisonUpdatedAt) > previousMillis) {
      latestComparisonUpdatedAtRef.current = comparisonUpdatedAt;
    }
    if (alreadyRequested) return;
    setLoadGeneration((current) => isSourceTokenCurrent(sourceToken) ? current + 1 : current);
  }, [isSourceTokenCurrent, sourceToken]);

  const acknowledgeAttributionSafety = useCallback(async (
    provenanceEpoch: string,
    unsafeID: string,
    throughGeneration: number,
  ) => {
    if (!isSourceTokenCurrent(sourceToken) || sourceToken === null) return false;
    const acknowledged = await source.acknowledgeAttributionSafety(
      sourceToken,
      provenanceEpoch,
      unsafeID,
      throughGeneration,
    );
    if (acknowledged && isSourceTokenCurrent(sourceToken)) {
      // The acknowledgement changes native exact-index state. Only a fresh
      // precise snapshot without the episode token may advance the baseline.
      setLoadGeneration((current) => current + 1);
    }
    return acknowledged;
  }, [isSourceTokenCurrent, source, sourceToken]);

  const refreshAttributionSafety = useCallback(() => {
    if (isSourceTokenCurrent(sourceToken)) {
      setLoadGeneration((current) => current + 1);
    }
  }, [isSourceTokenCurrent, sourceToken]);

  const mergeLiveRateSnapshot = useCallback((liveRate: LiveRateSnapshot) => {
    if (!isSourceTokenCurrent(sourceToken)) {
      return;
    }
    setState((current) => isSourceTokenCurrent(sourceToken)
      ? mergeLiveRate(current, liveRate)
      : current);
  }, [isSourceTokenCurrent, sourceToken]);

  const mergeThreadOptions = useCallback((liveThreadOptions: LiveThreadOption[]) => {
    if (!isSourceTokenCurrent(sourceToken)) {
      return;
    }
    startTransition(() => {
      setState((current) => isSourceTokenCurrent(sourceToken)
        ? mergeLiveThreadOptions(current, liveThreadOptions)
        : current);
    });
  }, [isSourceTokenCurrent, sourceToken]);

  const updateUsageCacheStatus = useCallback((status: UsageCacheStatus) => {
    if (isSourceTokenCurrent(sourceToken)) {
      setUsageCacheInitializing((current) => isSourceTokenCurrent(sourceToken)
        ? !status.initialized
        : current);
    }
  }, [isSourceTokenCurrent, sourceToken]);

  const markUsageCacheInitialized = useCallback(() => {
    if (isSourceTokenCurrent(sourceToken)) {
      setUsageCacheInitializing((current) => isSourceTokenCurrent(sourceToken) ? false : current);
    }
  }, [isSourceTokenCurrent, sourceToken]);

  const retryLiveRateStream = useCallback(() => {
    setLiveRateRetryGeneration((current) => current + 1);
  }, []);

  const consumeForcedQuotaRefresh = useCallback(() => {
    if (isSourceTokenCurrent(sourceToken)) {
      setForceNextQuotaLoad((current) => isSourceTokenCurrent(sourceToken) ? false : current);
    }
  }, [isSourceTokenCurrent, sourceToken]);
  const beginRefreshTask = useCallback(() => {
    if (isSourceTokenCurrent(sourceToken)) {
      setRefreshTaskCount((count) => isSourceTokenCurrent(sourceToken) ? count + 1 : count);
    }
  }, [isSourceTokenCurrent, sourceToken]);
  const endRefreshTask = useCallback(() => {
    if (isSourceTokenCurrent(sourceToken)) {
      setRefreshTaskCount((count) => isSourceTokenCurrent(sourceToken)
        ? Math.max(0, count - 1)
        : count);
    }
  }, [isSourceTokenCurrent, sourceToken]);

  useEffect(() => {
    let cancelled = false;
    let unlisten: (() => void) | null = null;
    let cancelReconcile: (() => void) | null = null;

    void subscribeToSourceChanges((envelope) => {
      if (!cancelled) {
        acceptSourceEnvelope(envelope);
      }
    }).then((subscription) => {
      if (cancelled) {
        if (subscription.ok) {
          subscription.unlisten();
        }
        return;
      }
      if (!subscription.ok) {
        cancelReconcile = scheduleSourceReconcile(() => {
          if (!cancelled) {
            void reconcileCodexHomeSource();
          }
        }, MAIN_SOURCE_RECONCILE_INTERVAL_MS);
        return;
      }
      unlisten = subscription.unlisten;
    }).catch(() => {
      if (!cancelled && cancelReconcile === null) {
        cancelReconcile = scheduleSourceReconcile(() => {
          if (!cancelled) {
            void reconcileCodexHomeSource();
          }
        }, MAIN_SOURCE_RECONCILE_INTERVAL_MS);
      }
    });
    return () => {
      cancelled = true;
      sourceReconcileRequestRef.current += 1;
      sourceReconcileInFlightRef.current = null;
      unlisten?.();
      cancelReconcile?.();
    };
  }, [
    acceptSourceEnvelope,
    reconcileCodexHomeSource,
    scheduleSourceReconcile,
    subscribeToSourceChanges,
  ]);

  useEffect(() => {
    const reconcile = () => {
      void reconcileCodexHomeSource();
    };
    const reconcileWhenVisible = () => {
      if (document.visibilityState !== "hidden") {
        reconcile();
      }
    };
    window.addEventListener("focus", reconcile);
    document.addEventListener("visibilitychange", reconcileWhenVisible);
    return () => {
      window.removeEventListener("focus", reconcile);
      document.removeEventListener("visibilitychange", reconcileWhenVisible);
    };
  }, [reconcileCodexHomeSource]);

  useEffect(() => {
    let cancelled = false;
    void source.getCodexHome().then((envelope) => {
      if (cancelled) {
        return;
      }
      if (envelope !== null) {
        acceptSourceEnvelope(envelope);
        return;
      }

      const unavailable = acceptDashboardSourceResponse(
        sourceTransitionRef.current,
        envelope,
      );
      if (!unavailable.accepted && sourceTransitionRef.current.sourceToken === null) {
        setState((current) => sourceTransitionRef.current.sourceToken === null
          ? {
              ...current,
              codexHome: {
                path: "无法读取 Codex Home",
                exists: false,
                source: "读取失败",
              },
              loading: false,
            }
          : current);
      }
    });
    return () => {
      cancelled = true;
    };
  }, [acceptSourceEnvelope, source]);

  useEffect(() => {
    if (sourceToken === null) {
      return;
    }
    let cancelled = false;
    void loadInitialDashboardState({
      source,
      sourceToken,
      isCancelled: () => cancelled,
      isSourceCurrent: isSourceTokenCurrent,
      setState,
      onFastSnapshotLoaded: () => setFastSnapshotLoaded((current) => (
        isSourceTokenCurrent(sourceToken) ? true : current
      )),
    });
    return () => {
      cancelled = true;
    };
  }, [isSourceTokenCurrent, source, sourceLoadGeneration, sourceToken]);

  const dashboardReady = state.dashboard !== null;

  useEffect(() => {
    let cancelled = false;
    let unlisten: (() => void) | null = null;

    void readAppSettings().then((settings) => {
      if (!cancelled && settings !== null) {
        setQuotaRefreshIntervalMs(sanitizeQuotaRefreshIntervalMs(settings.quotaRefreshIntervalMs));
      }
    }).catch(() => {
      // 保持默认刷新间隔；失败已由命令诊断链路记录并在横幅中展示。
    });

    void desktopPlatform.onAppSettingsChanged((settings) => {
      setQuotaRefreshIntervalMs(sanitizeQuotaRefreshIntervalMs(settings.quotaRefreshIntervalMs));
    }).then((listener) => {
      if (cancelled) {
        listener();
      } else {
        unlisten = listener;
      }
    });

    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, []);

  useEffect(() => {
    if (sourceToken === null) {
      return;
    }
    let cancelled = false;
    let unlisten: (() => void) | null = null;
    void desktopPlatform.onUnreadSummaryChanged((payload) => {
      if (cancelled || !isSourceTokenCurrent(payload.sourceToken)) {
        return;
      }
      setState((current) => isSourceTokenCurrent(payload.sourceToken) && current.liveRate
        ? {
            ...current,
            liveRate: {
              ...current.liveRate,
              unreadSummary: payload.summary,
            },
          }
        : current);
    }).then((listener) => {
      if (cancelled) {
        listener();
      } else {
        unlisten = listener;
      }
    });

    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, [isSourceTokenCurrent, sourceToken]);

  useEffect(() => {
    if (typeof document === "undefined") {
      return;
    }

    const handleVisibilityChange = () => {
      setDashboardVisible(dashboardIsVisible());
    };

    document.addEventListener("visibilitychange", handleVisibilityChange);
    return () => {
      document.removeEventListener("visibilitychange", handleVisibilityChange);
    };
  }, []);

  useEffect(() => {
    if (!fastSnapshotLoaded || !dashboardReady || state.loading) {
      return;
    }

    const baselineIntervalMs = dashboardVisible
      ? DASHBOARD_VISIBLE_AUTO_REFRESH_INTERVAL_MS
      : DASHBOARD_BACKGROUND_AUTO_REFRESH_INTERVAL_MS;
    const interval = window.setInterval(() => {
      setLoadGeneration((current) => current + 1);
    }, baselineIntervalMs);

    return () => {
      window.clearInterval(interval);
    };
  }, [dashboardReady, dashboardVisible, fastSnapshotLoaded, state.loading]);

  const quotaAutoRefreshPlan = useMemo(
    () => makeQuotaAutoRefreshPlan({
      dashboardReady,
      fastSnapshotLoaded,
      intervalMs: quotaRefreshIntervalMs,
      loading: state.loading,
    }),
    [dashboardReady, fastSnapshotLoaded, quotaRefreshIntervalMs, state.loading],
  );

  useEffect(() => {
    if (!quotaAutoRefreshPlan.active || quotaAutoRefreshPlan.intervalMs === null) {
      return;
    }

    const interval = window.setInterval(() => {
      setQuotaLoadGeneration((current) => current + 1);
    }, quotaAutoRefreshPlan.intervalMs);

    return () => {
      window.clearInterval(interval);
    };
  }, [quotaAutoRefreshPlan]);

  useEffect(() => {
    if (!fastSnapshotLoaded || !dashboardReady || state.loading || state.dashboard === null) {
      return;
    }

    const delayMs = nextQuotaResetRefreshDelayMs(state.dashboard.quota);
    if (delayMs === null) {
      return;
    }

    const timer = window.setTimeout(() => {
      setForceNextQuotaLoad(true);
      setQuotaLoadGeneration((current) => current + 1);
    }, delayMs);

    return () => {
      window.clearTimeout(timer);
    };
  }, [
    dashboardReady,
    fastSnapshotLoaded,
    state.dashboard?.quota.fiveHour.resetsAtUnix,
    state.dashboard?.quota.sevenDay.resetsAtUnix,
    state.loading,
  ]);

  const refreshAfterWake = useCallback(() => {
    const context = makeDashboardWakeRefreshContext({
      dashboardGeneratedAt: state.dashboard?.generatedAt ?? null,
      dashboardVisible,
      nowMs: Date.now(),
      visibleRefreshIntervalMs: DASHBOARD_VISIBLE_AUTO_REFRESH_INTERVAL_MS,
    });
    const plan = makeDashboardRefreshPlan("systemWake", context);
    applyDashboardRefreshPlan(plan, {
      refreshPreciseUsage: () => setLoadGeneration((current) => current + 1),
      refreshQuota: () => {
        setForceNextQuotaLoad(true);
        setQuotaLoadGeneration((current) => current + 1);
      },
      refreshRadar: () => setRadarRefreshGeneration((current) => current + 1),
      scanProviders: () => {},
    });
  }, [dashboardVisible, state.dashboard?.generatedAt]);

  useWakeRefresh({
    active: fastSnapshotLoaded && dashboardReady && !state.loading,
    onWake: refreshAfterWake,
  });

  useDeferredDashboardLoads({
    active: fastSnapshotLoaded,
    dashboardReady,
    loading: state.loading,
    generation: loadGeneration,
    quotaGeneration: quotaLoadGeneration,
    forceQuotaRefresh: forceNextQuotaLoad,
    sourceToken,
    source,
    onPreciseDashboard: mergePreciseSnapshot,
    onPreciseDashboardFailure: markPreciseSnapshotFailure,
    onPreciseDashboardStale: markPreciseSnapshotStale,
    onUsageCacheInitialized: markUsageCacheInitialized,
    onUsageCacheStatus: updateUsageCacheStatus,
    onQuota: mergeQuotaSnapshot,
    onLiveThreadOptions: mergeThreadOptions,
    onForceQuotaRefreshConsumed: consumeForcedQuotaRefresh,
    onRefreshTaskStart: beginRefreshTask,
    onRefreshTaskEnd: endRefreshTask,
  });

  useLiveRateFeed({
    active: fastSnapshotLoaded && liveRateEnabled,
    selectedThreadId: selectedLiveThreadId,
    sourceToken,
    onSnapshot: mergeLiveRateSnapshot,
    retryGeneration: liveRateRetryGeneration,
  });

  useEffect(() => {
    if (liveRateEnabled || !isSourceTokenCurrent(sourceToken)) {
      return;
    }
    setState((current) => isSourceTokenCurrent(sourceToken)
      ? mergeLiveRate(current, disabledLiveRateSnapshot(selectedLiveThreadId))
      : current);
  }, [isSourceTokenCurrent, liveRateEnabled, selectedLiveThreadId, sourceToken]);

  const readyState = useMemo(() => visibleDashboardState(state), [state]);
  const providerSourceKey = sourceToken === null
    ? "unavailable"
    : `${sourceToken.transitionGeneration}:${sourceToken.canonicalHomeKey}:${sourceToken.physicalHomeKey}`;
  const runningThreads = useRunningThreadSummary({
    active: sourceToken !== null,
    sourceToken,
  });

  return {
    state,
    readyState,
    refreshing: state.loading || refreshTaskCount > 0,
    usageCacheInitializing,
    radarRefreshGeneration,
    reloadAll,
    reloadQuota,
    refreshAttributionPreciseUsage,
    acknowledgeAttributionSafety,
    refreshAttributionSafety,
    acknowledgeUnread,
    retryLiveRateStream,
    updateCodexHome,
    restoreAutoCodexHome,
    updateProviderRepair,
    providerSourceKey,
    sourceToken,
    runningThreads,
    selectedLiveThreadId,
    setSelectedLiveThreadId,
  };
}

interface PendingRenderCommit {
  label: string;
  startedAt: number;
}

function useRenderCommitPerformanceTrace(dashboard: DashboardSnapshot | null) {
  const pendingCommitRef = useRef<PendingRenderCommit | null>(null);

  useLayoutEffect(() => {
    const pending = pendingCommitRef.current;
    if (pending === null || dashboard === null) {
      return;
    }
    pendingCommitRef.current = null;
    const elapsedMs = Math.round(performance.now() - pending.startedAt);
    void recordPerformanceEvent(`${pending.label} commit ${elapsedMs}ms`);
  }, [dashboard]);

  return useCallback((label: string) => {
    pendingCommitRef.current = {
      label,
      startedAt: performance.now(),
    };
  }, []);
}
