import {
  useCallback,
  useEffect,
  useMemo,
  useState,
} from "react";
import { dashboardDataSource, type DashboardDataSource } from "../data/dashboardDataSource";
import { useCommandDiagnostics } from "../diagnostics/useCommandDiagnostics";
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
  readyDashboardState,
  type DashboardAppState,
} from "./dashboardState";
import { loadInitialDashboardState } from "./loadInitialDashboardState";
import { useDashboardActions } from "./useDashboardActions";
import { useDeferredDashboardLoads } from "./useDeferredDashboardLoads";
import { useLiveRateFeed } from "./useLiveRateFeed";

export function useDashboardData(source: DashboardDataSource = dashboardDataSource) {
  const [state, setState] = useState<DashboardAppState>(initialDashboardState);
  const [fastSnapshotLoaded, setFastSnapshotLoaded] = useState(false);
  const [loadGeneration, setLoadGeneration] = useState(0);
  const [forceNextQuotaLoad, setForceNextQuotaLoad] = useState(false);
  const commandDiagnostics = useCommandDiagnostics();
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
    setState((current) => ({ ...current, diagnostics: commandDiagnostics }));
  }, [commandDiagnostics]);

  useEffect(() => {
    let cancelled = false;

    setFastSnapshotLoaded(false);
    setLoadGeneration((current) => current + 1);
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

  useDeferredDashboardLoads({
    active: fastSnapshotLoaded,
    dashboardReady: state.dashboard !== null,
    loading: state.loading,
    generation: loadGeneration,
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

  const readyState = useMemo(() => readyDashboardState(state), [state]);

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
