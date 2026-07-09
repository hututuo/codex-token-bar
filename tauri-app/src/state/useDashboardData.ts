import {
  startTransition,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { readAppSettings } from "../api/client";
import { recordPerformanceEvent } from "../api/startupClient";
import { dashboardDataSource, type DashboardDataSource } from "../data/dashboardDataSource";
import { desktopPlatform } from "../platform/desktop";
import {
  DEFAULT_QUOTA_REFRESH_INTERVAL_MS,
  sanitizeQuotaRefreshIntervalMs,
} from "../settings/quotaRefreshCadence";
import type {
  AccountQuotaBundle,
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
  mergePreciseDashboard,
  mergeQuota,
  visibleDashboardState,
  type DashboardAppState,
} from "./dashboardState";
import {
  applyDashboardRefreshPlan,
  makeDashboardRefreshPlan,
  makeDashboardWakeRefreshContext,
} from "./dashboardRefreshPlan";
import { makeQuotaAutoRefreshPlan } from "./quotaAutoRefreshModel";
import { loadInitialDashboardState } from "./loadInitialDashboardState";
import { useDashboardActions } from "./useDashboardActions";
import { useDeferredDashboardLoads } from "./useDeferredDashboardLoads";
import { useLiveRateFeed } from "./useLiveRateFeed";
import { nextQuotaResetRefreshDelayMs } from "../utils/quotaRefresh";
import {
  LIVE_USAGE_ACTIVITY_HOLD_MS,
  liveRateHasUsageRefreshActivity,
  usageRefreshIntervalMs,
} from "../utils/usageRefreshCadence";
import { useWakeRefresh } from "../utils/useWakeRefresh";

const DASHBOARD_VISIBLE_AUTO_REFRESH_INTERVAL_MS = 3 * 60 * 1000;
const DASHBOARD_BACKGROUND_AUTO_REFRESH_INTERVAL_MS = 5 * 60 * 1000;

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
}

export function useDashboardData(options: UseDashboardDataOptions = {}) {
  const source = options.source ?? dashboardDataSource;
  const liveRateEnabled = options.liveRateEnabled ?? true;
  const providerRepairVisible = options.providerRepairVisible ?? false;
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
  const [lastLiveActivityAtMs, setLastLiveActivityAtMs] = useState(0);
  const [quotaRefreshIntervalMs, setQuotaRefreshIntervalMs] = useState(DEFAULT_QUOTA_REFRESH_INTERVAL_MS);
  const lastLiveActivityAtMsRef = useRef(0);
  const markRenderCommit = useRenderCommitPerformanceTrace(state.dashboard);
  const {
    reloadAll,
    reloadQuota,
    acknowledgeUnread,
    updateCodexHome,
    restoreAutoCodexHome,
    updateProviderRepair,
    selectedLiveThreadId,
    setSelectedLiveThreadId,
  } = useDashboardActions({
    source,
    providerRepairVisible,
    setState,
    setFastSnapshotLoaded,
    setLoadGeneration,
    setQuotaLoadGeneration,
    setRadarRefreshGeneration,
    setForceNextQuotaLoad,
  });

  const mergePreciseSnapshot = useCallback((precise: DashboardSnapshot) => {
    markRenderCommit("frontend precise dashboard");
    startTransition(() => {
      setState((current) => mergePreciseDashboard(current, precise));
    });
  }, [markRenderCommit]);

  const mergeQuotaSnapshot = useCallback((quota: AccountQuotaBundle) => {
    markRenderCommit("frontend quota dashboard");
    startTransition(() => {
      setState((current) => mergeQuota(current, quota));
    });
  }, [markRenderCommit]);

  const markLiveUsageActivity = useCallback((liveRate: LiveRateSnapshot) => {
    if (!liveRateHasUsageRefreshActivity(liveRate)) {
      return;
    }

    const nowMs = Date.now();
    lastLiveActivityAtMsRef.current = nowMs;
    setLastLiveActivityAtMs((current) => {
      if (current > 0 && nowMs - current < LIVE_USAGE_ACTIVITY_HOLD_MS) {
        return current;
      }
      return nowMs;
    });
  }, []);

  const mergeLiveRateSnapshot = useCallback((liveRate: LiveRateSnapshot) => {
    markLiveUsageActivity(liveRate);
    setState((current) => mergeLiveRate(current, liveRate));
  }, [markLiveUsageActivity]);

  const mergeThreadOptions = useCallback((liveThreadOptions: LiveThreadOption[]) => {
    startTransition(() => {
      setState((current) => mergeLiveThreadOptions(current, liveThreadOptions));
    });
  }, []);

  const updateUsageCacheStatus = useCallback((status: UsageCacheStatus) => {
    setUsageCacheInitializing(!status.initialized);
  }, []);

  const markUsageCacheInitialized = useCallback(() => {
    setUsageCacheInitializing(false);
  }, []);

  const retryLiveRateStream = useCallback(() => {
    setLiveRateRetryGeneration((current) => current + 1);
  }, []);

  const consumeForcedQuotaRefresh = useCallback(() => {
    setForceNextQuotaLoad(false);
  }, []);
  const beginRefreshTask = useCallback(() => {
    setRefreshTaskCount((count) => count + 1);
  }, []);
  const endRefreshTask = useCallback(() => {
    setRefreshTaskCount((count) => Math.max(0, count - 1));
  }, []);

  useEffect(() => {
    let cancelled = false;

    setFastSnapshotLoaded(false);
    setLoadGeneration((current) => current + 1);
    setQuotaLoadGeneration((current) => current + 1);
    setForceNextQuotaLoad(false);
    void loadInitialDashboardState({
      source,
      isCancelled: () => cancelled,
      setState,
      onFastSnapshotLoaded: () => setFastSnapshotLoaded(true),
    });

    return () => {
      cancelled = true;
    };
  }, [source]);

  const dashboardReady = state.dashboard !== null;

  useEffect(() => {
    let cancelled = false;
    let unlisten: (() => void) | null = null;

    void readAppSettings().then((settings) => {
      if (!cancelled && settings !== null) {
        setQuotaRefreshIntervalMs(sanitizeQuotaRefreshIntervalMs(settings.quotaRefreshIntervalMs));
      }
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
    let cancelled = false;
    let unlisten: (() => void) | null = null;

    void desktopPlatform.onUnreadSummaryChanged((unreadSummary) => {
      if (cancelled) {
        return;
      }
      setState((current) => current.liveRate
        ? {
            ...current,
            liveRate: {
              ...current.liveRate,
              unreadSummary,
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
  }, []);

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
    const intervalMs = usageRefreshIntervalMs({
      baselineIntervalMs,
      lastLiveActivityAtMs,
    });
    const interval = window.setInterval(() => {
      setLoadGeneration((current) => current + 1);
    }, intervalMs);

    return () => {
      window.clearInterval(interval);
    };
  }, [dashboardReady, dashboardVisible, fastSnapshotLoaded, lastLiveActivityAtMs, state.loading]);

  useEffect(() => {
    if (lastLiveActivityAtMs <= 0) {
      return;
    }

    const timer = window.setTimeout(() => {
      const latestActivityAtMs = lastLiveActivityAtMsRef.current;
      if (
        latestActivityAtMs > 0
        && Date.now() - latestActivityAtMs < LIVE_USAGE_ACTIVITY_HOLD_MS
      ) {
        setLastLiveActivityAtMs(latestActivityAtMs);
        return;
      }

      lastLiveActivityAtMsRef.current = 0;
      setLastLiveActivityAtMs(0);
    }, LIVE_USAGE_ACTIVITY_HOLD_MS);

    return () => {
      window.clearTimeout(timer);
    };
  }, [lastLiveActivityAtMs]);

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
    source,
    onPreciseDashboard: mergePreciseSnapshot,
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
    source,
    onSnapshot: mergeLiveRateSnapshot,
    retryGeneration: liveRateRetryGeneration,
  });

  useEffect(() => {
    if (liveRateEnabled) {
      return;
    }
    lastLiveActivityAtMsRef.current = 0;
    setLastLiveActivityAtMs(0);
    setState((current) => mergeLiveRate(current, disabledLiveRateSnapshot(selectedLiveThreadId)));
  }, [liveRateEnabled, selectedLiveThreadId]);

  const readyState = useMemo(() => visibleDashboardState(state), [state]);

  return {
    state,
    readyState,
    refreshing: state.loading || refreshTaskCount > 0,
    usageCacheInitializing,
    radarRefreshGeneration,
    reloadAll,
    reloadQuota,
    acknowledgeUnread,
    retryLiveRateStream,
    updateCodexHome,
    restoreAutoCodexHome,
    updateProviderRepair,
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
