import {
  startTransition,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { readAppSettings, recordStartupEvent } from "../api/client";
import { recordPerformanceEvent } from "../api/startupClient";
import { dashboardDataSource, type DashboardDataSource } from "../data/dashboardDataSource";
import { desktopPlatform } from "../platform/desktop";
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
  const [sourceToken, setSourceToken] = useState<DashboardSourceToken | null>(null);
  const [sourceLoadGeneration, setSourceLoadGeneration] = useState(0);
  const [selectedLiveThreadId, setSelectedLiveThreadId] = useState("");
  const sourceTransitionRef = useRef(createDashboardSourceTransition());
  const lastLiveActivityAtMsRef = useRef(0);
  const markRenderCommit = useRenderCommitPerformanceTrace(state.dashboard);

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
    lastLiveActivityAtMsRef.current = 0;
    setLastLiveActivityAtMs(0);

    if (result.sourceChanged) {
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
  }, [isSourceTokenCurrent, markRenderCommit, sourceToken]);

  const mergeQuotaSnapshot = useCallback((quota: AccountQuotaBundle) => {
    if (!isSourceTokenCurrent(sourceToken)) {
      return;
    }
    markRenderCommit("frontend quota dashboard");
    startTransition(() => {
      setState((current) => isSourceTokenCurrent(sourceToken)
        ? mergeQuota(current, quota)
        : current);
    });
  }, [isSourceTokenCurrent, markRenderCommit, sourceToken]);

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
    if (!isSourceTokenCurrent(sourceToken)) {
      return;
    }
    markLiveUsageActivity(liveRate);
    setState((current) => isSourceTokenCurrent(sourceToken)
      ? mergeLiveRate(current, liveRate)
      : current);
  }, [isSourceTokenCurrent, markLiveUsageActivity, sourceToken]);

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

    void desktopPlatform.onCodexHomeSourceChanged((envelope) => {
      if (!cancelled) {
        acceptSourceEnvelope(envelope);
      }
    }).then((subscription) => {
      if (!subscription.ok) {
        return;
      }
      if (cancelled) {
        subscription.unlisten();
      } else {
        unlisten = subscription.unlisten;
      }
    });
    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, [acceptSourceEnvelope]);

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
    sourceToken,
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
    sourceToken,
    onSnapshot: mergeLiveRateSnapshot,
    retryGeneration: liveRateRetryGeneration,
  });

  useEffect(() => {
    if (liveRateEnabled || !isSourceTokenCurrent(sourceToken)) {
      return;
    }
    lastLiveActivityAtMsRef.current = 0;
    setLastLiveActivityAtMs(0);
    setState((current) => isSourceTokenCurrent(sourceToken)
      ? mergeLiveRate(current, disabledLiveRateSnapshot(selectedLiveThreadId))
      : current);
  }, [isSourceTokenCurrent, liveRateEnabled, selectedLiveThreadId, sourceToken]);

  const readyState = useMemo(() => visibleDashboardState(state), [state]);
  const providerSourceKey = sourceToken === null
    ? "unavailable"
    : `${sourceToken.transitionGeneration}:${sourceToken.canonicalHomeKey}:${sourceToken.physicalHomeKey}`;

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
    providerSourceKey,
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
