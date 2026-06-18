import {
  useCallback,
  useEffect,
  useMemo,
  useState,
  type Dispatch,
  type SetStateAction,
} from "react";
import {
  getCommandDiagnosticsSnapshot,
  recordStartupEvent,
  subscribeCommandDiagnostics,
} from "../api/client";
import { dashboardDataSource, type DashboardDataSource } from "../data/dashboardDataSource";
import type {
  AccountQuotaBundle,
  DashboardSnapshot,
  LiveRateSnapshot,
  LiveThreadOption,
  ProviderRepairSnapshot,
} from "../types/dashboard";
import {
  initialDashboardState,
  mergeLiveRate,
  mergeLiveThreadOptions,
  mergePreciseDashboard,
  mergeQuota,
  pendingLiveRateSnapshot,
  pendingRepairSnapshot,
  readyDashboardState,
  type DashboardAppState,
} from "./dashboardState";
import { useDeferredDashboardLoads } from "./useDeferredDashboardLoads";
import { useLiveRateFeed } from "./useLiveRateFeed";

export function useDashboardData(source: DashboardDataSource = dashboardDataSource) {
  const [state, setState] = useState<DashboardAppState>(initialDashboardState);
  const [fastSnapshotLoaded, setFastSnapshotLoaded] = useState(false);
  const [loadGeneration, setLoadGeneration] = useState(0);
  const [forceNextQuotaLoad, setForceNextQuotaLoad] = useState(false);
  const [selectedLiveThreadId, setSelectedLiveThreadId] = useState("");

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
    return subscribeCommandDiagnostics((diagnostics) => {
      setState((current) => ({ ...current, diagnostics }));
    });
  }, []);

  useEffect(() => {
    let cancelled = false;

    setFastSnapshotLoaded(false);
    setLoadGeneration((current) => current + 1);
    setForceNextQuotaLoad(false);
    void loadInitialAppStateInParts(
      source,
      () => cancelled,
      (update) => setState(update),
      () => setFastSnapshotLoaded(true),
    );

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

  async function reloadAll() {
    setLoadGeneration((current) => current + 1);
    setForceNextQuotaLoad(true);
    setFastSnapshotLoaded(false);
    setState((current) => ({ ...current, loading: true }));
    await loadInitialAppStateInParts(
      source,
      () => false,
      (update) => setState(update),
      () => setFastSnapshotLoaded(true),
    );
  }

  async function updateCodexHome(path: string) {
    setSelectedLiveThreadId("");
    setState((current) => ({ ...current, loading: true }));
    await source.setCodexHome(path);
    await reloadAll();
  }

  async function restoreAutoCodexHome() {
    setSelectedLiveThreadId("");
    setState((current) => ({ ...current, loading: true }));
    await source.resetCodexHome();
    await reloadAll();
  }

  function updateProviderRepair(repair: ProviderRepairSnapshot) {
    setState((current) => ({ ...current, repair }));
  }

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

async function loadInitialAppStateInParts(
  source: DashboardDataSource,
  isCancelled: () => boolean,
  setState: Dispatch<SetStateAction<DashboardAppState>>,
  markFastSnapshotLoaded: () => void,
): Promise<void> {
  void source.getCodexHome().then((codexHome) => {
    if (!isCancelled()) {
      setState((current) => ({ ...current, codexHome }));
      void recordStartupEvent("codex home ready");
    }
  });

  void source.readPlatformCapabilities().then((platform) => {
    if (!isCancelled()) {
      setState((current) => ({ ...current, platform }));
      void recordStartupEvent("platform ready");
    }
  });

  await source.readDashboardSnapshot().then((dashboard) => {
    if (!isCancelled()) {
      setState((current) => ({
        ...current,
        dashboard,
        diagnostics: getCommandDiagnosticsSnapshot(),
        loading: false,
      }));
      markFastSnapshotLoaded();
      void recordStartupEvent("dashboard snapshot ready");
    }
  });
}
