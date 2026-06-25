import {
  useCallback,
  useEffect,
  useMemo,
  useState,
} from "react";
import { dashboardDataSource, type DashboardDataSource } from "../data/dashboardDataSource";
import type {
  AccountQuotaBundle,
  DashboardSnapshot,
  LiveRateSnapshot,
  LiveThreadOption,
} from "../types/dashboard";
import {
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

const DASHBOARD_VISIBLE_AUTO_REFRESH_INTERVAL_MS = 3 * 60 * 1000;
const DASHBOARD_BACKGROUND_AUTO_REFRESH_INTERVAL_MS = 5 * 60 * 1000;
const QUOTA_AUTO_REFRESH_INTERVAL_MS = 5 * 60 * 1000;

function dashboardIsVisible() {
  if (typeof document === "undefined") {
    return true;
  }
  return document.visibilityState !== "hidden";
}

export function useDashboardData(source: DashboardDataSource = dashboardDataSource) {
  const [state, setState] = useState<DashboardAppState>(initialDashboardState);
  const [fastSnapshotLoaded, setFastSnapshotLoaded] = useState(false);
  const [loadGeneration, setLoadGeneration] = useState(0);
  const [quotaLoadGeneration, setQuotaLoadGeneration] = useState(0);
  const [forceNextQuotaLoad, setForceNextQuotaLoad] = useState(false);
  const [dashboardVisible, setDashboardVisible] = useState(dashboardIsVisible);
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
    setForceNextQuotaLoad,
  });

  const mergePreciseSnapshot = useCallback((precise: DashboardSnapshot) => {
    setState((current) => mergePreciseDashboard(current, precise));
  }, []);

  const mergeQuotaSnapshot = useCallback((quota: AccountQuotaBundle) => {
    setState((current) => mergeQuota(current, quota));
  }, []);

  const mergeLiveRateSnapshot = useCallback((liveRate: LiveRateSnapshot) => {
    setState((current) => mergeLiveRate(current, liveRate));
  }, []);

  const mergeThreadOptions = useCallback((liveThreadOptions: LiveThreadOption[]) => {
    setState((current) => mergeLiveThreadOptions(current, liveThreadOptions));
  }, []);

  const consumeForcedQuotaRefresh = useCallback(() => {
    setForceNextQuotaLoad(false);
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

  useDeferredDashboardLoads({
    active: fastSnapshotLoaded,
    dashboardReady,
    loading: state.loading,
    generation: loadGeneration,
    quotaGeneration: quotaLoadGeneration,
    forceQuotaRefresh: forceNextQuotaLoad,
    source,
    onPreciseDashboard: mergePreciseSnapshot,
    onQuota: mergeQuotaSnapshot,
    onLiveThreadOptions: mergeThreadOptions,
    onForceQuotaRefreshConsumed: consumeForcedQuotaRefresh,
  });

  useLiveRateFeed({
    active: fastSnapshotLoaded,
    selectedThreadId: selectedLiveThreadId,
    source,
    onSnapshot: mergeLiveRateSnapshot,
  });

  const readyState = useMemo(() => visibleDashboardState(state), [state]);

  return {
    state,
    readyState,
    reloadAll,
    updateCodexHome,
    restoreAutoCodexHome,
    updateProviderRepair,
    selectedLiveThreadId,
    setSelectedLiveThreadId,
  };
}
