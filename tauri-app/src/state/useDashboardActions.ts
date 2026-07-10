import {
  useCallback,
  type Dispatch,
  type SetStateAction,
} from "react";
import type { DashboardDataSource } from "../data/dashboardDataSource";
import { desktopPlatform } from "../platform/desktop";
import type { CodexHomeSourceEnvelope, ProviderRepairSnapshot } from "../types/dashboard";
import {
  applyDashboardRefreshPlan,
  applyManualDashboardRefresh,
  makeDashboardRefreshPlan,
} from "./dashboardRefreshPlan";
import type { DashboardAppState } from "./dashboardState";
import {
  dashboardSourceTokenFromEnvelope,
  type DashboardSourceToken,
} from "./dashboardSourceTransition";

interface DashboardActionsOptions {
  source: Pick<
    DashboardDataSource,
    | "setCodexHome"
    | "resetCodexHome"
    | "acknowledgeUnreadSummary"
    | "scanProviderRepair"
  >;
  providerRepairVisible: boolean;
  setState: Dispatch<SetStateAction<DashboardAppState>>;
  setLoadGeneration: Dispatch<SetStateAction<number>>;
  setQuotaLoadGeneration: Dispatch<SetStateAction<number>>;
  setRadarRefreshGeneration: Dispatch<SetStateAction<number>>;
  setForceNextQuotaLoad: Dispatch<SetStateAction<boolean>>;
  acceptSourceEnvelope: (envelope: CodexHomeSourceEnvelope) => boolean;
  captureSourceToken: () => DashboardSourceToken | null;
  isSourceTokenCurrent: (token: DashboardSourceToken | null) => boolean;
  refreshCurrentSource: (token: DashboardSourceToken) => void;
  sourceToken: DashboardSourceToken | null;
}

export function useDashboardActions({
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
}: DashboardActionsOptions) {
  const updateProviderRepair = useCallback((repair: ProviderRepairSnapshot) => {
    if (isSourceTokenCurrent(sourceToken)) {
      setState((current) => isSourceTokenCurrent(sourceToken)
        ? { ...current, repair }
        : current);
    }
  }, [isSourceTokenCurrent, setState, sourceToken]);

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
          const sourceToken = captureSourceToken();
          void source.scanProviderRepair().then((repair) => {
            if (isSourceTokenCurrent(sourceToken)) {
              updateProviderRepair(repair);
            }
          });
        },
      },
    });
  }, [
    providerRepairVisible,
    captureSourceToken,
    isSourceTokenCurrent,
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

  const acknowledgeUnread = useCallback(async () => {
    const sourceToken = captureSourceToken();
    const unreadSummary = await source.acknowledgeUnreadSummary();
    if (!isSourceTokenCurrent(sourceToken)) {
      return;
    }
    setState((current) => isSourceTokenCurrent(sourceToken) && current.liveRate
      ? {
          ...current,
          liveRate: {
            ...current.liveRate,
            unreadSummary,
          },
        }
      : current);
    void desktopPlatform.publishUnreadSummaryChanged(unreadSummary);
  }, [captureSourceToken, isSourceTokenCurrent, setState, source]);

  const applyCommittedSourceEnvelope = useCallback((
    envelope: CodexHomeSourceEnvelope,
    sourceTokenBeforeSave: DashboardSourceToken | null,
  ) => {
    const committedSourceToken = dashboardSourceTokenFromEnvelope(envelope);
    const sourceWasUnchanged = sourceTokenBeforeSave !== null
      && sourceTokenBeforeSave.transitionGeneration === committedSourceToken.transitionGeneration
      && sourceTokenBeforeSave.canonicalHomeKey === committedSourceToken.canonicalHomeKey;
    if (
      acceptSourceEnvelope(envelope)
      && sourceWasUnchanged
      && isSourceTokenCurrent(committedSourceToken)
    ) {
      refreshCurrentSource(committedSourceToken);
    }
  }, [acceptSourceEnvelope, isSourceTokenCurrent, refreshCurrentSource]);

  const updateCodexHome = useCallback(async (path: string) => {
    const sourceTokenBeforeSave = captureSourceToken();
    const envelope = await source.setCodexHome(path);
    applyCommittedSourceEnvelope(envelope, sourceTokenBeforeSave);
  }, [applyCommittedSourceEnvelope, captureSourceToken, source]);

  const restoreAutoCodexHome = useCallback(async () => {
    const sourceTokenBeforeSave = captureSourceToken();
    const envelope = await source.resetCodexHome();
    applyCommittedSourceEnvelope(envelope, sourceTokenBeforeSave);
  }, [applyCommittedSourceEnvelope, captureSourceToken, source]);

  return {
    reloadAll,
    reloadQuota,
    acknowledgeUnread,
    updateCodexHome,
    restoreAutoCodexHome,
    updateProviderRepair,
  };
}
