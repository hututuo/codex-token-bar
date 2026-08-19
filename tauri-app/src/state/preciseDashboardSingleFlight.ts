import type { CodexHomeSourceToken, DashboardSnapshot } from "../types/dashboard";
import type {
  PreciseDashboardDedupeDomain,
  PreciseDashboardRefreshReason,
  PreciseDashboardRequestRevision,
} from "../types/usage";
import { canonicalAttributionBoundaryKey } from "./attributionBoundary.ts";

type PreciseDashboardLoader = () => Promise<DashboardSnapshot | null>;
type PreciseDashboardSubscriber = (snapshot: DashboardSnapshot | null) => void;

interface PreciseDashboardFlight {
  latestLoader: PreciseDashboardLoader;
  initialRequest: PreciseDashboardRequestIdentity;
  coalescibleRequestsByDomain: Map<PreciseDashboardDedupeDomain, PreciseDashboardRequestIdentity>;
  coverageBoundary?: PreciseDashboardCoverageRequest;
  latestSubscriber?: {
    id: number;
    publish: PreciseDashboardSubscriber;
  };
  rerunRequested: boolean;
  rerunStarted: boolean;
  trailingRefreshFailed: boolean;
  settled: boolean;
  settlementWaiters: Set<() => void>;
  subscriberSequence: number;
  promise: Promise<DashboardSnapshot | null>;
}

interface PreciseDashboardCoverageRequest {
  boundarySeconds: number;
  request: PreciseDashboardRequestIdentity;
}

interface PreciseDashboardRequestIdentity {
  reason: PreciseDashboardRefreshReason;
  revision?: PreciseDashboardRequestRevision;
  dedupeDomain?: PreciseDashboardDedupeDomain;
  dedupeKey?: string;
}

export interface PreciseDashboardFlightHandle {
  result: Promise<DashboardSnapshot | null>;
  unsubscribe: () => void;
  waitForUiBudget: (timeoutMs: number) => Promise<void>;
}

export interface PreciseDashboardRequestOptions {
  /**
   * Forced requests represent a manual action, source/data change, or retry.
   * Background cadence requests may reuse a last-good snapshot only when the
   * source probe proves the same published exact-index generation.
   */
  force?: boolean;
  /** Published exact-index generation proven by the cadence source probe. */
  publishedGeneration?: string;
  /** Stable trigger label used for coalescing and native performance tracing. */
  reason?: PreciseDashboardRefreshReason;
  /** Trigger-local idempotency revision; never a native source-freshness proof. */
  revision?: PreciseDashboardRequestRevision;
  /** Explicit bounded dedupe domain; never represents native source freshness. */
  dedupeDomain?: PreciseDashboardDedupeDomain;
  /** Idempotent trigger key scoped to the dedupe domain. */
  dedupeKey?: string;
}

const flightsBySource = new Map<string, PreciseDashboardFlight>();
const lastSuccessfulSnapshotsBySource = new Map<string, DashboardSnapshot>();
const lastCompletedRequestsBySource = new Map<
  string,
  Map<PreciseDashboardDedupeDomain, PreciseDashboardRequestIdentity>
>();
const dirtySources = new Set<string>();
const MAX_PRECISE_SOURCE_CACHE_ENTRIES = 2;

const SETTLED_FORCE_COALESCIBLE_REASONS: ReadonlySet<PreciseDashboardRefreshReason> = new Set([
  "cadence",
  "quota",
  "catch-up",
  "attribution",
  "wake",
]);

/** Mark a source dirty before a forced request crosses status/probe IPC. */
export function markPreciseDashboardSourceDirty(sourceToken: CodexHomeSourceToken): void {
  const key = preciseDashboardSourceKey(sourceToken);
  dirtySources.add(key);
  // A dirty marker is the explicit evidence that the source lineage moved or
  // that the previous read failed. It invalidates any settled reason/revision
  // pair; the next request must be allowed to reach native precise again.
  lastCompletedRequestsBySource.delete(key);
  const existing = flightsBySource.get(key);
  if (existing && !existing.settled) {
    // A probe can observe a new append while the owner is still in flight. It
    // must retain one trailing run rather than letting that generation vanish
    // at the owner's stable boundary.
    if (existing.rerunStarted) {
      existing.trailingRefreshFailed = true;
    } else {
      existing.rerunRequested = true;
    }
  }
}

/**
 * Force requests with a stable idempotent trigger key may reuse the
 * immediately completed snapshot when no dirty marker intervened. Attribution
 * boundaries must carry a canonical five-minute bucket key; a raw revision is only
 * diagnostic metadata and never a freshness proof. Manual/source-change,
 * retry, and unknown requests intentionally return false for fail-safe
 * semantics.
 */
export function preciseDashboardForceRequestCanReuseSettled(
  reason: PreciseDashboardRefreshReason,
  revision: PreciseDashboardRequestRevision | undefined,
  dedupeDomain?: PreciseDashboardDedupeDomain,
  dedupeKey?: string,
): boolean {
  // A revision is diagnostic metadata. Once a dedupe domain is explicit, the
  // caller must provide that domain's semantic key; falling back to a raw
  // timestamp would reintroduce the millisecond-spelling bug this guard is
  // meant to prevent. Undomained callers remain non-coalescible below.
  const effectiveKey = dedupeDomain === undefined
    ? (dedupeKey ?? (revision === undefined ? undefined : String(revision)))
    : dedupeKey;
  const boundaryKeyIsCanonical = dedupeDomain !== "attribution-boundary"
      && dedupeDomain !== "aggregate-boundary"
    || (effectiveKey !== undefined && canonicalBoundarySeconds(effectiveKey) !== undefined);
  return SETTLED_FORCE_COALESCIBLE_REASONS.has(reason)
    && effectiveKey !== undefined
    && effectiveKey.trim().length > 0
    && boundaryKeyIsCanonical
    && ((dedupeDomain === "attribution-boundary"
      && (reason === "quota" || reason === "catch-up" || reason === "attribution"))
      || (dedupeDomain === "aggregate-boundary" && reason === "cadence")
      || (dedupeDomain === "wake" && reason === "wake"));
}

/**
 * Read-only source-scoped join check for cadence callers. A cadence tick that
 * observes an owner must join it before running any source probe; probing an
 * index while it has a building generation would otherwise manufacture a
 * dirty trailing request for the already-running owner.
 */
export function preciseDashboardFlightInProgress(
  sourceToken: CodexHomeSourceToken,
): boolean {
  const flight = flightsBySource.get(preciseDashboardSourceKey(sourceToken));
  return flight !== undefined && !flight.settled;
}

export function loadPreciseDashboardSingleFlight(
  sourceToken: CodexHomeSourceToken,
  loader: PreciseDashboardLoader,
  subscriber?: PreciseDashboardSubscriber,
  options: PreciseDashboardRequestOptions = {},
): PreciseDashboardFlightHandle {
  const key = preciseDashboardSourceKey(sourceToken);
  prunePreciseDashboardCaches(key);
  const force = options.force !== false;
  const request = preciseDashboardRequestIdentity(options, force);
  const existing = flightsBySource.get(key);
  if (existing && !existing.settled) {
    // Periodic joins do not replace the force owner's traced loader. If a
    // source-dirty marker later requires a trailing run, that run must retain
    // the reason attached to the force request that actually requested it.
    const coverageRequest = coverageRequestForIdentity(request);
    if (coverageRequest !== undefined) {
      const advanced = recordCoverageRequest(existing, coverageRequest);
      if (advanced) {
        existing.latestLoader = loader;
      }
      recordFlightRequest(existing, request);
      // Coverage requests join the active owner. Whether a trailing full is
      // needed is decided after the owner's fresh coverage watermark is
      // known; scheduling it here makes a covered boundary look stale.
      return flightHandle(existing, subscriber);
    }
    if (force) {
      const requestIsCoalescible = preciseDashboardForceRequestCanReuseSettled(
        request.reason,
        request.revision,
        request.dedupeDomain,
        request.dedupeKey,
      );
      const completedRequest = request.dedupeDomain === undefined
        ? undefined
        : lastCompletedRequestsBySource.get(key)?.get(request.dedupeDomain);
      const duplicateAcceptedKey = requestIsCoalescible && (
        requestIdentitiesShareDedupeKey(existing.initialRequest, request)
        || Array.from(existing.coalescibleRequestsByDomain.values())
          .some((accepted) => requestIdentitiesShareDedupeKey(accepted, request))
      );
      const duplicateCompletedKey = requestIsCoalescible
        && completedRequest !== undefined
        && requestIdentitiesShareDedupeKey(completedRequest, request);
      if (duplicateAcceptedKey || duplicateCompletedKey) {
        // A coalescible key completed before this owner started is still
        // covered by the new full result. Add it to the current flight's
        // bounded covered set so the fresh owner publishes both domains.
        if (duplicateCompletedKey
          && request.dedupeDomain !== undefined
          && !existing.coalescibleRequestsByDomain.has(request.dedupeDomain)) {
          recordFlightRequest(existing, request);
        }
        return flightHandle(existing, subscriber);
      }
      recordFlightRequest(existing, request);
      existing.latestLoader = loader;
    }
    // A periodic callback that arrives while the owner is still running is
    // already covered by that owner. Only an explicit/dirty request may ask
    // the single-flight cycle for one trailing attempt.
    if (force) {
      dirtySources.add(key);
      if (!existing.rerunStarted) {
        existing.rerunRequested = true;
      } else {
        existing.trailingRefreshFailed = true;
      }
    }
    return flightHandle(existing, subscriber);
  }
  if (existing) {
    flightsBySource.delete(key);
  }

  const cached = lastSuccessfulSnapshotsBySource.get(key);
  const coverageRequest = coverageRequestForIdentity(request);
  if (!dirtySources.has(key)
    && cached
    && coverageRequest !== undefined
    && preciseSnapshotCoversBoundary(cached, coverageRequest.boundarySeconds)) {
    return cachedSnapshotHandle(cached, subscriber);
  }
  const completedRequest = request.dedupeDomain === undefined
    ? undefined
    : lastCompletedRequestsBySource.get(key)?.get(request.dedupeDomain);
  if (force
    && coverageRequest === undefined
    && !dirtySources.has(key)
    && cached
    && completedRequest
    && requestIdentitiesShareDedupeKey(completedRequest, request)
    && preciseDashboardForceRequestCanReuseSettled(
      request.reason,
      request.revision,
      request.dedupeDomain,
      request.dedupeKey,
    )) {
    return cachedSnapshotHandle(cached, subscriber);
  }
  if (!force
    && !dirtySources.has(key)
    && cached
    && preciseSnapshotPublishedGenerationMatches(cached, options.publishedGeneration)) {
    return cachedSnapshotHandle(cached, subscriber);
  }
  // A periodic request without a valid published-generation proof must not
  // reuse an in-memory snapshot, including when the cache is absent or its
  // lineage field is missing/invalid. Keep the source dirty until a native
  // owner publishes a fresh exact snapshot.
  if (force || !preciseSnapshotPublishedGenerationMatches(cached, options.publishedGeneration)) {
    if (coverageRequest !== undefined) {
      // A boundary-gated owner is already the freshness action. Keep the
      // source clean while it runs so subsequent attribution boundaries can
      // join it; completion marks it dirty if coverage remains insufficient.
    } else if (force && preciseDashboardForceRequestCanReuseSettled(
      request.reason,
      request.revision,
      request.dedupeDomain,
      request.dedupeKey,
    )) {
      // A new idempotent trigger key requires one native full, but it is not
      // evidence that another dedupe domain became stale. Preserve completed
      // keys for the other domain until a real dirty/source-change marker.
      dirtySources.add(key);
    } else {
      markPreciseDashboardSourceDirty(sourceToken);
    }
  }

  const flight: PreciseDashboardFlight = {
    latestLoader: loader,
    initialRequest: request,
    coalescibleRequestsByDomain: new Map(),
    coverageBoundary: coverageRequest,
    rerunRequested: false,
    rerunStarted: false,
    trailingRefreshFailed: false,
    settled: false,
    settlementWaiters: new Set(),
    subscriberSequence: 0,
    promise: Promise.resolve(null),
  };
  recordFlightRequest(flight, request);
  flight.promise = runPreciseDashboardFlight(flight)
    .then(
      (result) => {
        const coverageSatisfied = flight.coverageBoundary === undefined
          || preciseSnapshotCoversBoundary(result, flight.coverageBoundary.boundarySeconds);
        if (isSuccessfulPreciseSnapshot(result)
          && coverageSatisfied
          && !flight.trailingRefreshFailed) {
          lastSuccessfulSnapshotsBySource.set(key, result);
          recordCompletedFlightRequests(key, flight);
          dirtySources.delete(key);
        } else {
          // A stale/null/error result, or a failed trailing run, must not leave
          // an older idempotency key able to hide the next retry.
          lastCompletedRequestsBySource.delete(key);
          dirtySources.add(key);
        }
        settleFlight(flight, result);
        return result;
      },
      (error) => {
        lastCompletedRequestsBySource.delete(key);
        dirtySources.add(key);
        settleFlight(flight);
        throw error;
      },
    )
    .finally(() => {
      if (flightsBySource.get(key) === flight) {
        flightsBySource.delete(key);
      }
      prunePreciseDashboardCaches(key);
    });
  void flight.promise.catch(() => undefined);
  flightsBySource.set(key, flight);
  return flightHandle(flight, subscriber);
}

async function runPreciseDashboardFlight(
  flight: PreciseDashboardFlight,
): Promise<DashboardSnapshot | null> {
  let firstResult: DashboardSnapshot | null = null;
  let firstError: unknown;
  let firstFailed = false;
  try {
    firstResult = await flight.latestLoader();
  } catch (error) {
    firstFailed = true;
    firstError = error;
  }

  // Let same-turn quota/attribution callbacks join before deciding whether
  // the first result covers the maximum requested boundary. Without this
  // settlement turn, a callback queued immediately after the loader resolves
  // could be observed only after the owner had already committed its result.
  await Promise.resolve();
  const coverageNeedsTrailing = flight.coverageBoundary !== undefined
    && !preciseSnapshotCoversBoundary(
      firstResult,
      flight.coverageBoundary.boundarySeconds,
    );
  if (flight.rerunRequested || coverageNeedsTrailing) {
    flight.rerunRequested = true;
    flight.rerunStarted = true;
    try {
      const trailingResult = await flight.latestLoader();
      if (trailingResult === null) {
        flight.trailingRefreshFailed = true;
      }
      return trailingResult ?? firstResult;
    } catch (error) {
      flight.trailingRefreshFailed = true;
      if (!firstFailed && firstResult !== null) {
        return firstResult;
      }
      throw error;
    }
  }
  if (firstFailed) {
    throw firstError;
  }
  return firstResult;
}

function flightHandle(
  flight: PreciseDashboardFlight,
  subscriber?: PreciseDashboardSubscriber,
): PreciseDashboardFlightHandle {
  const subscriptionId = flight.subscriberSequence + 1;
  flight.subscriberSequence = subscriptionId;
  if (subscriber) {
    flight.latestSubscriber = {
      id: subscriptionId,
      publish: subscriber,
    };
  }
  return {
    result: flight.promise,
    unsubscribe() {
      if (flight.latestSubscriber?.id === subscriptionId) {
        flight.latestSubscriber = undefined;
      }
    },
    waitForUiBudget: (timeoutMs) => waitForFlightUiBudget(flight, timeoutMs),
  };
}

function cachedSnapshotHandle(
  snapshot: DashboardSnapshot,
  subscriber?: PreciseDashboardSubscriber,
): PreciseDashboardFlightHandle {
  let cancelled = false;
  if (subscriber) {
    // Keep the cached path asynchronous like a native invoke, while still
    // letting an effect cleanup cancel publication to an unmounted view.
    queueMicrotask(() => {
      if (!cancelled) {
        try {
          subscriber(snapshot);
        } catch {
          // View callbacks must not turn a cache hit into a refresh failure.
        }
      }
    });
  }
  return {
    result: Promise.resolve(snapshot),
    unsubscribe() {
      cancelled = true;
    },
    waitForUiBudget: () => Promise.resolve(),
  };
}

function coverageRequestForIdentity(
  request: PreciseDashboardRequestIdentity,
): PreciseDashboardCoverageRequest | undefined {
  if (!preciseDashboardForceRequestCanReuseSettled(
    request.reason,
    request.revision,
    request.dedupeDomain,
    request.dedupeKey,
  ) || (request.dedupeDomain !== "attribution-boundary"
    && request.dedupeDomain !== "aggregate-boundary")
    || request.dedupeKey === undefined) {
    return undefined;
  }
  const boundarySeconds = canonicalBoundarySeconds(request.dedupeKey);
  if (boundarySeconds === undefined) {
    return undefined;
  }
  return { boundarySeconds, request };
}

function canonicalBoundarySeconds(value: string): number | undefined {
  if (!/^(0|-?[1-9]\d*)$/.test(value)) {
    return undefined;
  }
  const seconds = Number(value);
  return Number.isSafeInteger(seconds) && String(seconds) === value
    ? seconds
    : undefined;
}

function recordCoverageRequest(
  flight: PreciseDashboardFlight,
  incoming: PreciseDashboardCoverageRequest,
): boolean {
  if (flight.coverageBoundary !== undefined
    && flight.coverageBoundary.boundarySeconds >= incoming.boundarySeconds) {
    return false;
  }
  flight.coverageBoundary = incoming;
  return true;
}

function isSuccessfulPreciseSnapshot(
  snapshot: DashboardSnapshot | null,
): snapshot is DashboardSnapshot {
  const coveredAt = preciseCoverageBoundary(snapshot);
  return snapshot !== null
    && snapshot.preciseRecentUsageFresh === true
    && coveredAt !== null
    && preciseCoverageBoundarySeconds(coveredAt) !== undefined;
}

function preciseSnapshotCoversBoundary(
  snapshot: DashboardSnapshot | null | undefined,
  boundarySeconds: number,
): boolean {
  if (snapshot === undefined || !isSuccessfulPreciseSnapshot(snapshot)) {
    return false;
  }
  const coveredAt = preciseCoverageBoundary(snapshot);
  const coveredSeconds = coveredAt === null
    ? undefined
    : preciseCoverageBoundarySeconds(coveredAt);
  return coveredSeconds !== undefined && coveredSeconds >= boundarySeconds;
}

function preciseSnapshotPublishedGenerationMatches(
  snapshot: DashboardSnapshot | undefined,
  expectedPublishedGeneration: string | undefined,
): boolean {
  if (!snapshot || !isCanonicalPublishedGeneration(expectedPublishedGeneration)) {
    return false;
  }
  const cachedGeneration = snapshot.exactGeneration ?? snapshot.preciseAttributionGeneration;
  return canonicalGeneration(cachedGeneration) === expectedPublishedGeneration;
}

function canonicalGeneration(value: unknown): string | undefined {
  if (typeof value === "number") {
    return Number.isSafeInteger(value) && value >= 0 ? String(value) : undefined;
  }
  if (typeof value !== "string" || !/^(0|[1-9]\d*)$/.test(value)) {
    return undefined;
  }
  return value;
}

function preciseCoverageBoundary(snapshot: DashboardSnapshot | null | undefined): string | null {
  const value = snapshot?.preciseRecentUsageCoveredAt ?? snapshot?.settledThrough;
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : null;
}

function preciseCoverageBoundarySeconds(value: string): number | undefined {
  const key = canonicalAttributionBoundaryKey(value);
  if (key !== undefined) {
    return canonicalBoundarySeconds(key);
  }
  if (/^(0|[1-9]\d*)$/.test(value)) {
    const seconds = Number(value);
    return Number.isSafeInteger(seconds) ? seconds : undefined;
  }
  const milliseconds = Date.parse(value);
  if (!Number.isFinite(milliseconds)) return undefined;
  const seconds = Math.floor(milliseconds / 1_000);
  return Number.isSafeInteger(seconds) ? seconds : undefined;
}

function isCanonicalPublishedGeneration(value: unknown): value is string {
  return typeof value === "string" && /^(0|[1-9]\d*)$/.test(value);
}

function preciseDashboardRequestIdentity(
  options: PreciseDashboardRequestOptions,
  force: boolean,
): PreciseDashboardRequestIdentity {
  const reason = options.reason ?? (force ? "unknown" : "cadence");
  return {
    reason,
    revision: options.revision,
    dedupeDomain: options.dedupeDomain,
    dedupeKey: options.dedupeKey,
  };
}

function requestIdentitiesShareDedupeKey(
  completed: PreciseDashboardRequestIdentity,
  incoming: PreciseDashboardRequestIdentity,
): boolean {
  return completed.dedupeDomain !== undefined
    && completed.dedupeDomain === incoming.dedupeDomain
    && completed.dedupeKey !== undefined
    && completed.dedupeKey.trim().length > 0
    && incoming.dedupeKey !== undefined
    && incoming.dedupeKey.trim().length > 0
    && completed.dedupeKey === incoming.dedupeKey;
}

function recordFlightRequest(
  flight: PreciseDashboardFlight,
  request: PreciseDashboardRequestIdentity,
): void {
  if (!preciseDashboardForceRequestCanReuseSettled(
    request.reason,
    request.revision,
    request.dedupeDomain,
    request.dedupeKey,
  ) || request.dedupeDomain === undefined) {
    return;
  }
  const incomingCoverage = coverageRequestForIdentity(request);
  const current = flight.coalescibleRequestsByDomain.get(request.dedupeDomain);
  if (incomingCoverage !== undefined && current !== undefined) {
    const currentCoverage = coverageRequestForIdentity(current);
    if (currentCoverage !== undefined
      && currentCoverage.boundarySeconds > incomingCoverage.boundarySeconds) {
      return;
    }
  }
  flight.coalescibleRequestsByDomain.set(request.dedupeDomain, request);
}

function recordCompletedFlightRequests(
  sourceKey: string,
  flight: PreciseDashboardFlight,
): void {
  if (flight.coalescibleRequestsByDomain.size === 0) {
    return;
  }
  const completed = lastCompletedRequestsBySource.get(sourceKey) ?? new Map();
  for (const [domain, request] of flight.coalescibleRequestsByDomain) {
    completed.set(domain, request);
  }
  lastCompletedRequestsBySource.set(sourceKey, completed);
}

function waitForFlightUiBudget(
  flight: PreciseDashboardFlight,
  timeoutMs: number,
): Promise<void> {
  if (flight.settled || timeoutMs <= 0) {
    return Promise.resolve();
  }
  return new Promise((resolve) => {
    let finished = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const finish = () => {
      if (finished) {
        return;
      }
      finished = true;
      flight.settlementWaiters.delete(finish);
      if (timer !== undefined) {
        globalThis.clearTimeout(timer);
      }
      resolve();
    };
    flight.settlementWaiters.add(finish);
    timer = globalThis.setTimeout(finish, timeoutMs);
    if (flight.settled) {
      finish();
    }
  });
}

function settleFlight(
  flight: PreciseDashboardFlight,
  result?: DashboardSnapshot | null,
) {
  flight.settled = true;
  const subscriber = flight.latestSubscriber;
  flight.latestSubscriber = undefined;
  if (result !== undefined && subscriber) {
    try {
      subscriber.publish(result);
    } catch {
      // A view callback must not turn a completed native read into a failed flight.
    }
  }
  const waiters = Array.from(flight.settlementWaiters);
  flight.settlementWaiters.clear();
  waiters.forEach((finish) => finish());
}

function preciseDashboardSourceKey(sourceToken: CodexHomeSourceToken): string {
  return JSON.stringify([
    sourceToken.transitionGeneration,
    sourceToken.canonicalHomeKey,
    sourceToken.physicalHomeKey,
  ]);
}

function prunePreciseDashboardCaches(currentKey: string): void {
  if (lastSuccessfulSnapshotsBySource.size > MAX_PRECISE_SOURCE_CACHE_ENTRIES) {
    const protectedKeys = new Set([currentKey, ...flightsBySource.keys()]);
    for (const key of lastSuccessfulSnapshotsBySource.keys()) {
      if (lastSuccessfulSnapshotsBySource.size <= MAX_PRECISE_SOURCE_CACHE_ENTRIES) {
        break;
      }
      if (!protectedKeys.has(key)) {
        lastSuccessfulSnapshotsBySource.delete(key);
        lastCompletedRequestsBySource.delete(key);
      }
    }
  }

  // A source token includes the transition generation, so an old dirty entry
  // can never safely authorize a future Home. Keep only entries that still
  // have a current last-good snapshot or an owner in flight.
  for (const key of dirtySources) {
    if (key !== currentKey
      && !lastSuccessfulSnapshotsBySource.has(key)
      && !flightsBySource.has(key)) {
      dirtySources.delete(key);
      lastCompletedRequestsBySource.delete(key);
    }
  }
}
