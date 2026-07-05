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
  >;
  setState: Dispatch<SetStateAction<DashboardAppState>>;
  setFastSnapshotLoaded: Dispatch<SetStateAction<boolean>>;
  setLoadGeneration: Dispatch<SetStateAction<number>>;
  setQuotaLoadGeneration: Dispatch<SetStateAction<number>>;
  setRadarRefreshGeneration: Dispatch<SetStateAction<number>>;
  setForceNextQuotaLoad: Dispatch<SetStateAction<boolean>>;
}

export function useDashboardActions({
  source,
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

  const reloadAll = useCallback(async () => {
    const plan = makeDashboardRefreshPlan("manual", { providerVisible: false });
    applyDashboardRefreshPlan(plan, {
      refreshPreciseUsage: () => setLoadGeneration((current) => current + 1),
      refreshQuota: () => {
        setForceNextQuotaLoad(true);
        setQuotaLoadGeneration((current) => current + 1);
      },
      refreshRadar: () => setRadarRefreshGeneration((current) => current + 1),
      scanProviders: () => {},
    });
  }, [
    setForceNextQuotaLoad,
    setLoadGeneration,
    setQuotaLoadGeneration,
    setRadarRefreshGeneration,
  ]);

  const reloadQuota = useCallback(() => {
    setForceNextQuotaLoad(true);
    setQuotaLoadGeneration((current) => current + 1);
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

  const updateProviderRepair = useCallback((repair: ProviderRepairSnapshot) => {
    setState((current) => ({ ...current, repair }));
  }, [setState]);

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
