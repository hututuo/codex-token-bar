import {
  useCallback,
  useState,
  type Dispatch,
  type SetStateAction,
} from "react";
import type { DashboardDataSource } from "../data/dashboardDataSource";
import type { ProviderRepairSnapshot } from "../types/dashboard";
import {
  applyDashboardRefreshPlan,
  applyManualDashboardRefresh,
  makeDashboardRefreshPlan,
} from "./dashboardRefreshPlan";
import type { DashboardAppState } from "./dashboardState";
import { loadInitialDashboardState } from "./loadInitialDashboardState";

interface DashboardActionsOptions {
  source: Pick<
    DashboardDataSource,
    | "setCodexHome"
    | "resetCodexHome"
    | "getCodexHome"
    | "readPlatformCapabilities"
    | "readDashboardSnapshot"
    | "scanProviderRepair"
  >;
  providerRepairVisible: boolean;
  setState: Dispatch<SetStateAction<DashboardAppState>>;
  setFastSnapshotLoaded: Dispatch<SetStateAction<boolean>>;
  setLoadGeneration: Dispatch<SetStateAction<number>>;
  setQuotaLoadGeneration: Dispatch<SetStateAction<number>>;
  setRadarRefreshGeneration: Dispatch<SetStateAction<number>>;
  setForceNextQuotaLoad: Dispatch<SetStateAction<boolean>>;
}

export function useDashboardActions({
  source,
  providerRepairVisible,
  setState,
  setFastSnapshotLoaded,
  setLoadGeneration,
  setQuotaLoadGeneration,
  setRadarRefreshGeneration,
  setForceNextQuotaLoad,
}: DashboardActionsOptions) {
  const [selectedLiveThreadId, setSelectedLiveThreadId] = useState("");

  const reloadInitialSnapshot = useCallback(async () => {
    setFastSnapshotLoaded(false);
    setState((current) => ({ ...current, loading: true }));
    await loadInitialDashboardState({
      source,
      isCancelled: () => false,
      setState,
      onFastSnapshotLoaded: () => setFastSnapshotLoaded(true),
    });
  }, [
    setFastSnapshotLoaded,
    setState,
    source,
  ]);

  const updateProviderRepair = useCallback((repair: ProviderRepairSnapshot) => {
    setState((current) => ({ ...current, repair }));
  }, [setState]);

  const reloadAll = useCallback(async () => {
    applyManualDashboardRefresh({
      providerRepairVisible,
      dispatchers: {
        refreshPreciseUsage: () => setLoadGeneration((current) => current + 1),
        refreshQuota: () => {
          setForceNextQuotaLoad(true);
          setQuotaLoadGeneration((current) => current + 1);
        },
        refreshRadar: () => setRadarRefreshGeneration((current) => current + 1),
        scanProviders: () => {
          void source.scanProviderRepair().then(updateProviderRepair);
        },
      },
    });
  }, [
    providerRepairVisible,
    source,
    setForceNextQuotaLoad,
    setLoadGeneration,
    setQuotaLoadGeneration,
    setRadarRefreshGeneration,
    updateProviderRepair,
  ]);

  const reloadQuota = useCallback(() => {
    const plan = makeDashboardRefreshPlan("quotaRetry", { providerVisible: false });
    applyDashboardRefreshPlan(plan, {
      refreshPreciseUsage: () => {},
      refreshQuota: () => {
        setForceNextQuotaLoad(true);
        setQuotaLoadGeneration((current) => current + 1);
      },
      refreshRadar: () => {},
      scanProviders: () => {},
    });
  }, [
    setForceNextQuotaLoad,
    setQuotaLoadGeneration,
  ]);

  const updateCodexHome = useCallback(async (path: string) => {
    setSelectedLiveThreadId("");
    setState((current) => ({ ...current, loading: true }));
    await source.setCodexHome(path);
    await reloadInitialSnapshot();
  }, [reloadInitialSnapshot, setState, source]);

  const restoreAutoCodexHome = useCallback(async () => {
    setSelectedLiveThreadId("");
    setState((current) => ({ ...current, loading: true }));
    await source.resetCodexHome();
    await reloadInitialSnapshot();
  }, [reloadInitialSnapshot, setState, source]);

  return {
    reloadAll,
    reloadQuota,
    updateCodexHome,
    restoreAutoCodexHome,
    updateProviderRepair,
    selectedLiveThreadId,
    setSelectedLiveThreadId,
  };
}
