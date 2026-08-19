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
  PreciseDashboardDedupeDomain,
  PreciseDashboardProgress,
  PreciseDashboardRefreshReason,
  PreciseDashboardRequestRevision,
  UsageCacheStatus,
} from "../types/dashboard";
import type { ResetCreditBundle } from "../types/quota";
import {
  disabledLiveRateSnapshot,
  clearPreciseAttributionSafety,
  initialDashboardState,
  mergeLiveRate,
  mergeLiveThreadOptions,
  markPreciseRecentUsageStale,
  markUsageSummaryStale,
  mergePreciseDashboard,
  mergeUsageSummary,
  mergeQuota,
  mergeResetCredits,
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
import { canonicalAttributionBoundaryKey } from "./attributionBoundary";
import { planPreciseUsageCatchUp } from "./preciseUsageCatchUp";
import { publishPreciseUsageFailure } from "./preciseUsageFailureChannel";
import { useDashboardActions } from "./useDashboardActions";
import { useDeferredDashboardLoads } from "./useDeferredDashboardLoads";
import { useLiveRateFeed } from "./useLiveRateFeed";
import { useRunningThreadSummary } from "./useRunningThreadSummary";
import { hasStaleAccountQuotaData } from "./dashboardWarnings";
import { nextQuotaResetRefreshDelayMs } from "../utils/quotaRefresh";
import { useWakeRefresh } from "../utils/useWakeRefresh";
import {
  DEFAULT_USAGE_REFRESH_SETTINGS,
  sanitizeUsageRefreshSettings,
} from "../settings/usageRefreshCadence";
import {
  latestEligibleBoundary,
  nextAggregateFireAtMs,
} from "../utils/usageRefreshCadence";

export const MAIN_SOURCE_RECONCILE_INTERVAL_MS = 30_000;

interface PreciseDashboardRequestIntent {
  force: boolean;
  reason: PreciseDashboardRefreshReason;
  revision?: PreciseDashboardRequestRevision;
  dedupeDomain?: PreciseDashboardDedupeDomain;
  dedupeKey?: string;
}

function mergePreciseRequestIntent(
  previous: PreciseDashboardRequestIntent | null,
  incoming: PreciseDashboardRequestIntent,
): PreciseDashboardRequestIntent {
  if (previous === null) {
    return incoming;
  }
  // Keep a fail-safe intent when several React updates batch into one exact
  // generation. Manual/source-change/retry/unknown requests must not be
  // downgraded to a coalescible quota or attribution request.
  const previousPriority = preciseRequestReasonPriority(previous.reason);
  const incomingPriority = preciseRequestReasonPriority(incoming.reason);
  if (incomingPriority >= previousPriority) {
    return {
      ...incoming,
      force: previous.force || incoming.force,
    };
  }
  return {
    ...previous,
    force: previous.force || incoming.force,
  };
}

function preciseRequestReasonPriority(reason: PreciseDashboardRefreshReason): number {
  if (reason === "manual" || reason === "source-change" || reason === "retry" || reason === "unknown") {
    return 2;
  }
  if (reason === "quota" || reason === "catch-up" || reason === "attribution" || reason === "wake") {
    return 1;
  }
  return 0;
}

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
  const [startupDashboardUnavailable, setStartupDashboardUnavailable] = useState(false);
  const [startupRetrySequence, setStartupRetrySequence] = useState(0);
  const [loadGeneration, setLoadGeneration] = useState(0);
  const [quotaLoadGeneration, setQuotaLoadGeneration] = useState(0);
  const [radarRefreshGeneration, setRadarRefreshGeneration] = useState(0);
  const [liveRateRetryGeneration, setLiveRateRetryGeneration] = useState(0);
  const [forceNextQuotaLoad, setForceNextQuotaLoad] = useState(false);
  const [dashboardVisible, setDashboardVisible] = useState(dashboardIsVisible);
  const [refreshTaskCount, setRefreshTaskCount] = useState(0);
  const [preciseProgress, setPreciseProgress] = useState<PreciseDashboardProgress | null>(null);
  const [preciseRequestInFlight, setPreciseRequestInFlight] = useState(false);
  const [usageCacheInitializing, setUsageCacheInitializing] = useState(false);
  const [quotaRefreshIntervalMs, setQuotaRefreshIntervalMs] = useState(DEFAULT_QUOTA_REFRESH_INTERVAL_MS);
  const [usageRefreshSettings, setUsageRefreshSettings] = useState(DEFAULT_USAGE_REFRESH_SETTINGS);
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
  const pendingForcedPreciseRefreshRef = useRef(false);
  const pendingPreciseRequestRef = useRef<PreciseDashboardRequestIntent | null>(null);
  const retryPreciseRefreshRef = useRef(false);
  const wakeRefreshSequenceRef = useRef(0);
  const preciseRequestSequenceRef = useRef(0);
  // Keep the force bit stable for the whole active generation. Clearing only
  // the pending bit at timer start must not make a later unrelated render
  // change the effect dependency and cancel the in-flight owner.
  const activeForcedPreciseGenerationRef = useRef<number | null>(null);
  const activePreciseRequestRef = useRef<PreciseDashboardRequestIntent | null>(null);
  latestPreciseCoverageRef.current = state.dashboard?.preciseRecentUsageCoveredAt
    ?? state.dashboard?.settledThrough
    ?? null;
  const markRenderCommit = useRenderCommitPerformanceTrace(state.dashboard);

  const requestPreciseRefresh = useCallback((
    force = true,
    reason?: PreciseDashboardRefreshReason,
    revision?: PreciseDashboardRequestRevision,
    dedupeDomain?: PreciseDashboardDedupeDomain,
    dedupeKey?: string,
  ) => {
    const requestId = preciseRequestSequenceRef.current + 1;
    preciseRequestSequenceRef.current = requestId;
    void recordPerformanceEvent(
      `frontend precise request id=${requestId} reason=${reason ?? (force ? "unknown" : "cadence")} force=${force ? 1 : 0} source_generation=${sourceTransitionRef.current.sourceToken?.transitionGeneration ?? "na"}`,
    );
    const request: PreciseDashboardRequestIntent = {
      force,
      reason: reason ?? (force ? "unknown" : "cadence"),
      revision,
      dedupeDomain,
      dedupeKey,
    };
    pendingPreciseRequestRef.current = mergePreciseRequestIntent(
      pendingPreciseRequestRef.current,
      request,
    );
    if (force) {
      pendingForcedPreciseRefreshRef.current = true;
    }
    setLoadGeneration((current) => {
      // A cadence tick can batch with a forced/manual request. The pending
      // force bit is consumed only when the exact effect actually starts, so
      // the final batched generation cannot silently downgrade to periodic.
      return current + 1;
    });
  }, []);

  const markPreciseRequestStarted = useCallback((
    generation: number,
    forced: boolean,
    reason: PreciseDashboardRefreshReason,
    revision?: PreciseDashboardRequestRevision,
    dedupeDomain?: PreciseDashboardDedupeDomain,
    dedupeKey?: string,
  ) => {
    setPreciseRequestInFlight(true);
    activeForcedPreciseGenerationRef.current = forced ? generation : null;
    activePreciseRequestRef.current = {
      force: forced,
      reason,
      revision,
      dedupeDomain,
      dedupeKey,
    };
    pendingPreciseRequestRef.current = null;
    retryPreciseRefreshRef.current = false;
    pendingForcedPreciseRefreshRef.current = false;
  }, []);

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
  const markPreciseRequestSettled = useCallback(() => {
    if (sourceToken === null || isSourceTokenCurrent(sourceToken)) {
      setPreciseRequestInFlight(false);
    }
  }, [isSourceTokenCurrent, sourceToken]);
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

    void recordPerformanceEvent(
      `frontend source envelope accepted initialized=${result.initialized ? 1 : 0} changed=${result.sourceChanged ? 1 : 0} generation=${acceptedSourceToken.transitionGeneration}`,
    );

    setSourceToken((current) => isSourceTokenCurrent(acceptedSourceToken)
      ? acceptedSourceToken
      : current);
    setFastSnapshotLoaded(false);
    setPreciseRequestInFlight(false);
    setStartupDashboardUnavailable(false);
    setStartupRetrySequence(0);
    setSelectedLiveThreadId("");
    setForceNextQuotaLoad(false);
    setRefreshTaskCount(0);
    setUsageCacheInitializing(false);

    if (result.sourceChanged) {
      quotaComparisonObservationRef.current = null;
      latestComparisonUpdatedAtRef.current = null;
      preciseCatchUpQuotaRef.current = null;
      attributionPreciseRefreshRef.current = null;
      requestPreciseRefresh(true, "source-change", acceptedSourceToken.transitionGeneration);
      setQuotaLoadGeneration((current) => current + 1);
      setRadarRefreshGeneration((current) => current + 1);
      setLiveRateRetryGeneration((current) => current + 1);
    } else {
      void recordStartupEvent("codex home ready");
    }
    return true;
  }, [isSourceTokenCurrent, requestPreciseRefresh]);
  const refreshCurrentSource = useCallback((token: DashboardSourceToken) => {
    if (!isSourceTokenCurrent(token)) {
      return;
    }
    setState((current) => isSourceTokenCurrent(token)
      ? { ...current, loading: true }
      : current);
    setSourceLoadGeneration((current) => isSourceTokenCurrent(token) ? current + 1 : current);
    setForceNextQuotaLoad(true);
    setQuotaLoadGeneration((current) => isSourceTokenCurrent(token) ? current + 1 : current);
    requestPreciseRefresh(true, "source-change", token.transitionGeneration);
  }, [isSourceTokenCurrent, requestPreciseRefresh]);
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
    requestPreciseRefresh,
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
    const wasStartupUnavailable = startupDashboardUnavailable;
    setStartupDashboardUnavailable(false);
    markRenderCommit("frontend precise dashboard");
    startTransition(() => {
      setState((current) => {
        if (!isSourceTokenCurrent(sourceToken)) return current;
        const merged = mergePreciseDashboard(current, precise);
        return wasStartupUnavailable ? { ...merged, loading: false } : merged;
      });
    });
    const catchUp = planPreciseUsageCatchUp({
      quotaUpdatedAt: latestComparisonUpdatedAtRef.current,
      preciseCoveredAt: precise.preciseRecentUsageCoveredAt ?? precise.settledThrough,
      preciseFresh: precise.preciseRecentUsageFresh,
      requestedForQuotaBoundaryKey: preciseCatchUpQuotaRef.current,
    });
    preciseCatchUpQuotaRef.current = catchUp.requestedForQuotaBoundaryKey;
    if (catchUp.shouldSchedule) {
      requestPreciseRefresh(
        true,
        "catch-up",
        latestComparisonUpdatedAtRef.current ?? undefined,
        "attribution-boundary",
        catchUp.requestedForQuotaBoundaryKey ?? undefined,
      );
    }
  }, [
    isSourceTokenCurrent,
    markRenderCommit,
    requestPreciseRefresh,
    sourceToken,
    startupDashboardUnavailable,
  ]);

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
    retryPreciseRefreshRef.current = true;
    if (startupDashboardUnavailable) {
      setStartupRetrySequence((current) => current + 1);
    }
  }, [isSourceTokenCurrent, sourceToken, startupDashboardUnavailable]);

  const mergeQuotaSnapshot = useCallback((quota: AccountQuotaBundle) => {
    if (!isSourceTokenCurrent(sourceToken) || sourceToken === null) {
      return;
    }
    void desktopPlatform.publishAccountQuotaChanged({ quota, sourceToken });
    markRenderCommit("frontend quota dashboard");
    const comparison = advanceQuotaComparisonObservation(
      quotaComparisonObservationRef.current,
      {
        quotaDataFresh: !hasStaleAccountQuotaData(quota.diagnostics),
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
      const comparisonUpdatedAt = comparison.state?.comparisonUpdatedAt ?? quota.updatedAt;
      const comparisonBoundaryKey = canonicalAttributionBoundaryKey(comparisonUpdatedAt);
      attributionPreciseRefreshRef.current = comparisonBoundaryKey ?? null;
      // The first quota observation commonly arrives while the cold precise
      // owner is already running. Coalesce that observation without asking the
      // owner for a redundant trailing full scan; a coverage mismatch after
      // settlement still schedules an explicit catch-up below.
      requestPreciseRefresh(
        comparison.reason !== "initial",
        "quota",
        comparisonUpdatedAt,
        "attribution-boundary",
        comparisonBoundaryKey,
      );
    }
  }, [isSourceTokenCurrent, markRenderCommit, requestPreciseRefresh, sourceToken]);

  const mergeResetCreditSnapshot = useCallback((reset: ResetCreditBundle) => {
    if (!isSourceTokenCurrent(sourceToken) || sourceToken === null) {
      return;
    }
    void desktopPlatform.publishAccountResetCreditsChanged({
      resetCredits: reset,
      sourceToken,
    });
    markRenderCommit("frontend reset-credit dashboard");
    startTransition(() => {
      setState((current) => isSourceTokenCurrent(sourceToken)
        ? mergeResetCredits(current, reset)
        : current);
    });
  }, [isSourceTokenCurrent, markRenderCommit, sourceToken]);

  const refreshAttributionPreciseUsage = useCallback((comparisonUpdatedAt: string) => {
    if (!isSourceTokenCurrent(sourceToken)) {
      return;
    }
    const comparisonBoundaryKey = canonicalAttributionBoundaryKey(comparisonUpdatedAt);
    const parsedComparisonMillis = typeof comparisonUpdatedAt === "string"
      ? Date.parse(comparisonUpdatedAt)
      : Number.NaN;
    // A malformed UI callback must not reuse an earlier boundary. Let it
    // reach the native owner without a dedupe key instead of silently
    // suppressing a refresh.
    if (comparisonBoundaryKey === undefined || !Number.isFinite(parsedComparisonMillis)) {
      attributionPreciseRefreshRef.current = null;
      requestPreciseRefresh(
        true,
        "attribution",
        typeof comparisonUpdatedAt === "string" ? comparisonUpdatedAt : undefined,
        "attribution-boundary",
      );
      return;
    }
    const alreadyRequested = attributionPreciseRefreshRef.current === comparisonBoundaryKey;
    attributionPreciseRefreshRef.current = comparisonBoundaryKey;
    quotaComparisonObservationRef.current = alignQuotaComparisonObservation(
      quotaComparisonObservationRef.current,
      comparisonUpdatedAt,
    );
    const previousMillis = latestComparisonUpdatedAtRef.current === null
      ? Number.NEGATIVE_INFINITY
      : Date.parse(latestComparisonUpdatedAtRef.current);
    if (parsedComparisonMillis > previousMillis) {
      latestComparisonUpdatedAtRef.current = comparisonUpdatedAt;
    }
    if (alreadyRequested) return;
    requestPreciseRefresh(
      true,
      "attribution",
      comparisonUpdatedAt,
      "attribution-boundary",
      comparisonBoundaryKey,
    );
  }, [isSourceTokenCurrent, requestPreciseRefresh, sourceToken]);

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
      // This acknowledgement removes only the reviewed safety marker. A
      // source-change request here used to turn that metadata write into a
      // second full scan immediately after the normal refresh. Clear the
      // marker locally and let the existing cadence/source probe publish the
      // next canonical snapshot; token and quota values are unchanged.
      setState((current) => isSourceTokenCurrent(sourceToken)
        ? clearPreciseAttributionSafety(current)
        : current);
      void recordPerformanceEvent(
        `frontend attribution safety acknowledged generation=${throughGeneration}; deferred precise refresh`,
      );
    }
    return acknowledged;
  }, [isSourceTokenCurrent, requestPreciseRefresh, source, sourceToken]);

  const refreshAttributionSafety = useCallback(() => {
    if (isSourceTokenCurrent(sourceToken)) {
      requestPreciseRefresh(true, "attribution");
    }
  }, [isSourceTokenCurrent, requestPreciseRefresh, sourceToken]);

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
      onDashboardAvailable: () => {
        if (!isSourceTokenCurrent(sourceToken)) return;
        setStartupDashboardUnavailable(false);
      },
      onDashboardUnavailable: () => {
        if (!isSourceTokenCurrent(sourceToken)) return;
        setFastSnapshotLoaded(true);
        setStartupDashboardUnavailable(true);
        setStartupRetrySequence((current) => current + 1);
      },
    });
    return () => {
      cancelled = true;
    };
  }, [isSourceTokenCurrent, source, sourceLoadGeneration, sourceToken]);

  useEffect(() => {
    if (!startupDashboardUnavailable || sourceToken === null) {
      return undefined;
    }
    const timer = window.setTimeout(() => {
      if (isSourceTokenCurrent(sourceToken)) {
        setLoadGeneration((current) => current + 1);
      }
    }, 30_000);
    return () => window.clearTimeout(timer);
  }, [
    isSourceTokenCurrent,
    sourceToken,
    startupDashboardUnavailable,
    startupRetrySequence,
  ]);

  const dashboardReady = state.dashboard !== null;

  useEffect(() => {
    let cancelled = false;
    let unlisten: (() => void) | null = null;

    void readAppSettings().then((settings) => {
      if (!cancelled && settings !== null) {
        setQuotaRefreshIntervalMs(sanitizeQuotaRefreshIntervalMs(settings.quotaRefreshIntervalMs));
        setUsageRefreshSettings(sanitizeUsageRefreshSettings(settings));
      }
    }).catch(() => {
      // 保持默认刷新间隔；失败已由命令诊断链路记录并在横幅中展示。
    });

    void desktopPlatform.onAppSettingsChanged((settings) => {
      setQuotaRefreshIntervalMs(sanitizeQuotaRefreshIntervalMs(settings.quotaRefreshIntervalMs));
      setUsageRefreshSettings(sanitizeUsageRefreshSettings(settings));
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

  const refreshUsageSummary = useCallback(async () => {
    if (sourceToken === null
      || !isSourceTokenCurrent(sourceToken)
      || !source.readUsageSummarySnapshot) return;
    setState((current) => isSourceTokenCurrent(sourceToken)
      ? markUsageSummaryStale(current)
      : current);
    try {
      const summary = await source.readUsageSummarySnapshot(
        sourceToken,
        usageRefreshSettings.usageLightRefreshIntervalSeconds,
      );
      if (summary !== null && isSourceTokenCurrent(sourceToken)) {
        setState((current) => isSourceTokenCurrent(sourceToken)
          ? mergeUsageSummary(current, summary)
          : current);
      }
    } catch {
      // Command diagnostics retain the failure. Keep the last trusted summary
      // and let the next configured lightweight cadence retry it.
    }
  }, [
    isSourceTokenCurrent,
    source,
    sourceToken,
    usageRefreshSettings.usageLightRefreshIntervalSeconds,
  ]);

  useEffect(() => {
    // The light owner is deliberately independent from the slower precise
    // chart owner. It must continue while a five-minute aggregate scan is in
    // flight so today's summary/model rows can publish without waiting for
    // the chart/index progress to settle.
    if (!fastSnapshotLoaded || !dashboardReady || sourceToken === null) {
      return undefined;
    }
    void refreshUsageSummary();
    const interval = window.setInterval(
      () => { void refreshUsageSummary(); },
      usageRefreshSettings.usageLightRefreshIntervalSeconds * 1_000,
    );
    return () => window.clearInterval(interval);
  }, [
    dashboardReady,
    fastSnapshotLoaded,
    refreshUsageSummary,
    sourceToken,
    usageRefreshSettings.usageLightRefreshIntervalSeconds,
  ]);

  useEffect(() => {
    if (!fastSnapshotLoaded || !dashboardReady || state.loading || sourceToken === null) {
      return undefined;
    }

    const intervalMinutes = dashboardVisible
      ? usageRefreshSettings.usageVisibleAggregateIntervalMinutes
      : usageRefreshSettings.usageBackgroundAggregateIntervalMinutes;
    const nowMs = Date.now();
    const eligibleBoundary = latestEligibleBoundary(nowMs / 1_000);
    const coveredAt = state.dashboard?.preciseRecentUsageCoveredAt
      ?? state.dashboard?.settledThrough
      ?? null;
    const coveredSeconds = coveredAt === null ? Number.NaN : Date.parse(coveredAt) / 1_000;

    // A cached startup snapshot with no coverage is already handled by the
    // initial precise owner. A visible dashboard with older trusted coverage
    // catches up immediately; hidden surfaces wait for their background slot.
    if (dashboardVisible
      && coveredAt !== null
      && (state.dashboard?.preciseRecentUsageFresh === false
        || !Number.isFinite(coveredSeconds)
        || coveredSeconds < eligibleBoundary)) {
      const boundaryKey = String(eligibleBoundary);
      requestPreciseRefresh(
        true,
        "cadence",
        boundaryKey,
        "aggregate-boundary",
        boundaryKey,
      );
    }

    let cancelled = false;
    let timer: number | null = null;
    const scheduleNext = () => {
      const scheduledFromMs = Date.now();
      const fireAtMs = nextAggregateFireAtMs(scheduledFromMs, intervalMinutes);
      timer = window.setTimeout(() => {
        if (cancelled) return;
        const boundaryKey = String(latestEligibleBoundary(Date.now() / 1_000));
        requestPreciseRefresh(
          true,
          "cadence",
          boundaryKey,
          "aggregate-boundary",
          boundaryKey,
        );
        scheduleNext();
      }, Math.max(0, fireAtMs - scheduledFromMs));
    };
    scheduleNext();
    return () => {
      cancelled = true;
      if (timer !== null) window.clearTimeout(timer);
    };
  }, [
    dashboardReady,
    dashboardVisible,
    fastSnapshotLoaded,
    requestPreciseRefresh,
    sourceToken,
    state.dashboard?.preciseRecentUsageCoveredAt,
    state.dashboard?.settledThrough,
    state.dashboard?.preciseRecentUsageFresh,
    state.loading,
    usageRefreshSettings.usageBackgroundAggregateIntervalMinutes,
    usageRefreshSettings.usageVisibleAggregateIntervalMinutes,
  ]);

  const quotaAutoRefreshPlan = useMemo(
    () => makeQuotaAutoRefreshPlan({
      dashboardReady,
      fastSnapshotLoaded,
      intervalMs: quotaRefreshIntervalMs,
    }),
    [dashboardReady, fastSnapshotLoaded, quotaRefreshIntervalMs],
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
    if (!fastSnapshotLoaded || !dashboardReady || state.dashboard === null) {
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
  ]);

  const refreshAfterWake = useCallback(() => {
    const eligibleBoundary = latestEligibleBoundary(Date.now() / 1_000);
    const context = makeDashboardWakeRefreshContext({
      dashboardGeneratedAt: state.dashboard?.generatedAt ?? null,
      preciseCoveredAt: state.dashboard?.preciseRecentUsageCoveredAt
        ?? state.dashboard?.settledThrough
        ?? null,
      preciseFresh: state.dashboard?.preciseRecentUsageFresh,
      eligibleBoundarySeconds: eligibleBoundary,
      dashboardVisible,
      nowMs: Date.now(),
      visibleRefreshIntervalMs:
        usageRefreshSettings.usageVisibleAggregateIntervalMinutes * 60 * 1_000,
    });
    const plan = makeDashboardRefreshPlan("systemWake", context);
    applyDashboardRefreshPlan(plan, {
      refreshPreciseUsage: () => {
        const boundaryKey = String(eligibleBoundary);
        requestPreciseRefresh(
          true,
          "cadence",
          boundaryKey,
          "aggregate-boundary",
          boundaryKey,
        );
      },
      refreshQuota: () => {
        setForceNextQuotaLoad(true);
        setQuotaLoadGeneration((current) => current + 1);
      },
      refreshRadar: () => setRadarRefreshGeneration((current) => current + 1),
      scanProviders: () => {},
    });
  }, [
    dashboardVisible,
    requestPreciseRefresh,
    state.dashboard?.generatedAt,
    state.dashboard?.preciseRecentUsageCoveredAt,
    state.dashboard?.settledThrough,
    state.dashboard?.preciseRecentUsageFresh,
    usageRefreshSettings.usageVisibleAggregateIntervalMinutes,
  ]);

  useWakeRefresh({
    active: fastSnapshotLoaded && dashboardReady && !state.loading,
    onWake: refreshAfterWake,
  });

  useDeferredDashboardLoads({
    active: fastSnapshotLoaded,
    dashboardReady,
    startupUnavailable: startupDashboardUnavailable,
    loading: state.loading,
    generation: loadGeneration,
    forcePreciseRefresh: pendingForcedPreciseRefreshRef.current
      || activeForcedPreciseGenerationRef.current === loadGeneration,
    preciseRefreshReason: pendingPreciseRequestRef.current?.reason
      ?? (activePreciseRequestRef.current
        && activePreciseRequestRef.current.force
        && activeForcedPreciseGenerationRef.current === loadGeneration
        ? activePreciseRequestRef.current.reason
        : retryPreciseRefreshRef.current ? "retry" : "cadence"),
    preciseRefreshRevision: pendingPreciseRequestRef.current?.revision
      ?? (activePreciseRequestRef.current
        && activePreciseRequestRef.current.force
        && activeForcedPreciseGenerationRef.current === loadGeneration
        ? activePreciseRequestRef.current.revision
        : undefined),
    preciseRefreshDedupeDomain: pendingPreciseRequestRef.current?.dedupeDomain
      ?? (activePreciseRequestRef.current
        && activePreciseRequestRef.current.force
        && activeForcedPreciseGenerationRef.current === loadGeneration
        ? activePreciseRequestRef.current.dedupeDomain
        : undefined),
    preciseRefreshDedupeKey: pendingPreciseRequestRef.current?.dedupeKey
      ?? (activePreciseRequestRef.current
        && activePreciseRequestRef.current.force
        && activeForcedPreciseGenerationRef.current === loadGeneration
        ? activePreciseRequestRef.current.dedupeKey
        : undefined),
    quotaGeneration: quotaLoadGeneration,
    forceQuotaRefresh: forceNextQuotaLoad,
    sourceToken,
    source,
    onPreciseDashboard: mergePreciseSnapshot,
    onPreciseDashboardFailure: markPreciseSnapshotFailure,
    onPreciseDashboardStale: markPreciseSnapshotStale,
    onUsageCacheInitialized: markUsageCacheInitialized,
    onUsageCacheStatus: updateUsageCacheStatus,
    onPreciseRequestStarted: markPreciseRequestStarted,
    onPreciseRequestSettled: markPreciseRequestSettled,
    onQuota: mergeQuotaSnapshot,
    onResetCredits: mergeResetCreditSnapshot,
    onLiveThreadOptions: mergeThreadOptions,
    onForceQuotaRefreshConsumed: consumeForcedQuotaRefresh,
    onRefreshTaskStart: beginRefreshTask,
    onRefreshTaskEnd: endRefreshTask,
  });

  useLiveRateFeed({
    active: fastSnapshotLoaded && dashboardReady && !state.loading && liveRateEnabled,
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

  useEffect(() => {
    const readProgress = source.readPreciseDashboardProgress;
    if (!readProgress || sourceToken === null) {
      setPreciseProgress(null);
      return undefined;
    }
    let cancelled = false;
    const poll = async () => {
      const next = await readProgress(sourceToken);
      if (!cancelled && next !== null) {
        setPreciseProgress(next);
      }
    };
    void poll();
    // refreshTaskCount is only the soft UI budget. The native precise owner
    // deliberately continues beyond that budget for large histories, so keep
    // polling until the actual single-flight settles.
    const active = state.loading || refreshTaskCount > 0 || preciseRequestInFlight;
    if (!active) {
      return () => {
        cancelled = true;
      };
    }
    const timer = window.setInterval(() => {
      void poll();
    }, 250);
    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, [preciseRequestInFlight, refreshTaskCount, source, sourceToken, state.loading]);

  return {
    state,
    readyState,
    refreshing: state.loading || refreshTaskCount > 0,
    preciseProgress,
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
