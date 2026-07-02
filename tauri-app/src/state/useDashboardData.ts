import {
  startTransition,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { recordPerformanceEvent } from "../api/startupClient";
import { dashboardDataSource, type DashboardDataSource } from "../data/dashboardDataSource";
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
import { loadInitialDashboardState } from "./loadInitialDashboardState";
import { useDashboardActions } from "./useDashboardActions";
import { useDeferredDashboardLoads } from "./useDeferredDashboardLoads";
import { useLiveRateFeed } from "./useLiveRateFeed";
import { nextQuotaResetRefreshDelayMs } from "../utils/quotaRefresh";
import { useWakeRefresh } from "../utils/useWakeRefresh";

const DASHBOARD_VISIBLE_AUTO_REFRESH_INTERVAL_MS = 3 * 60 * 1000;
const DASHBOARD_BACKGROUND_AUTO_REFRESH_INTERVAL_MS = 5 * 60 * 1000;
const QUOTA_AUTO_REFRESH_INTERVAL_MS = 5 * 60 * 1000;

function dashboardIsVisible() {
  if (typeof document === "undefined") {
    return true;
  }
  return document.visibilityState !== "hidden";
}

interface UseDashboardDataOptions {
  liveRateEnabled?: boolean;
  source?: DashboardDataSource;
}

export function useDashboardData(options: UseDashboardDataOptions = {}) {
  const source = options.source ?? dashboardDataSource;
  const liveRateEnabled = options.liveRateEnabled ?? true;
  const [state, setState] = useState<DashboardAppState>(initialDashboardState);
  const [fastSnapshotLoaded, setFastSnapshotLoaded] = useState(false);
  const [loadGeneration, setLoadGeneration] = useState(0);
  const [quotaLoadGeneration, setQuotaLoadGeneration] = useState(0);
  const [radarRefreshGeneration, setRadarRefreshGeneration] = useState(0);
  const [forceNextQuotaLoad, setForceNextQuotaLoad] = useState(false);
  const [dashboardVisible, setDashboardVisible] = useState(dashboardIsVisible);
  const [refreshTaskCount, setRefreshTaskCount] = useState(0);
  const [usageCacheInitializing, setUsageCacheInitializing] = useState(false);
  const markRenderCommit = useRenderCommitPerformanceTrace(state.dashboard);
  const {
    reloadAll,
    updateCodexHome,
    restoreAutoCodexHome,
    updateProviderRepair,
    selectedLiveThreadId,
    setSelectedLiveThreadId,
  } = useDashboardActions({
    source,
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

  const mergeLiveRateSnapshot = useCallback((liveRate: LiveRateSnapshot) => {
    setState((current) => mergeLiveRate(current, liveRate));
  }, []);

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

    const intervalMs = dashboardVisible
      ? DASHBOARD_VISIBLE_AUTO_REFRESH_INTERVAL_MS
      : DASHBOARD_BACKGROUND_AUTO_REFRESH_INTERVAL_MS;
    const interval = window.setInterval(() => {
      setLoadGeneration((current) => current + 1);
    }, intervalMs);

    return () => {
      window.clearInterval(interval);
    };
  }, [dashboardReady, dashboardVisible, fastSnapshotLoaded, state.loading]);

  useEffect(() => {
    if (!fastSnapshotLoaded || !dashboardReady || state.loading) {
      return;
    }

    const interval = window.setInterval(() => {
      setQuotaLoadGeneration((current) => current + 1);
    }, QUOTA_AUTO_REFRESH_INTERVAL_MS);

    return () => {
      window.clearInterval(interval);
    };
  }, [dashboardReady, fastSnapshotLoaded, state.loading]);

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

  const refreshQuotaAfterWake = useCallback(() => {
    setForceNextQuotaLoad(true);
    setQuotaLoadGeneration((current) => current + 1);
  }, []);

  useWakeRefresh({
    active: fastSnapshotLoaded && dashboardReady && !state.loading,
    onWake: refreshQuotaAfterWake,
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
  });

  useEffect(() => {
    if (liveRateEnabled) {
      return;
    }
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
