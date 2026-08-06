import type { CodexHomeSourceToken, DashboardSnapshot } from "../types/dashboard";

type PreciseDashboardLoader = () => Promise<DashboardSnapshot | null>;
type PreciseDashboardSubscriber = (snapshot: DashboardSnapshot | null) => void;

interface PreciseDashboardFlight {
  latestLoader: PreciseDashboardLoader;
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

export interface PreciseDashboardFlightHandle {
  result: Promise<DashboardSnapshot | null>;
  unsubscribe: () => void;
  waitForUiBudget: (timeoutMs: number) => Promise<void>;
}

export interface PreciseDashboardRequestOptions {
  /**
   * Forced requests represent a manual action, source/data change, or retry.
   * Background cadence requests may reuse an unchanged last-good snapshot.
   */
  force?: boolean;
}

const flightsBySource = new Map<string, PreciseDashboardFlight>();
const lastSuccessfulSnapshotsBySource = new Map<string, DashboardSnapshot>();
const dirtySources = new Set<string>();
const MAX_PRECISE_SOURCE_CACHE_ENTRIES = 2;

/** Mark a source dirty before a forced request crosses status/probe IPC. */
export function markPreciseDashboardSourceDirty(sourceToken: CodexHomeSourceToken): void {
  const key = preciseDashboardSourceKey(sourceToken);
  dirtySources.add(key);
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
  const existing = flightsBySource.get(key);
  if (existing && !existing.settled) {
    existing.latestLoader = loader;
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
  if (!force && !dirtySources.has(key) && cached) {
    return cachedSnapshotHandle(cached, subscriber);
  }
  if (force) markPreciseDashboardSourceDirty(sourceToken);

  const flight: PreciseDashboardFlight = {
    latestLoader: loader,
    rerunRequested: false,
    rerunStarted: false,
    trailingRefreshFailed: false,
    settled: false,
    settlementWaiters: new Set(),
    subscriberSequence: 0,
    promise: Promise.resolve(null),
  };
  flight.promise = runPreciseDashboardFlight(flight)
    .then(
      (result) => {
        if (isSuccessfulPreciseSnapshot(result)) {
          lastSuccessfulSnapshotsBySource.set(key, result);
          if (!flight.trailingRefreshFailed) {
            dirtySources.delete(key);
          }
        }
        settleFlight(flight, result);
        return result;
      },
      (error) => {
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

  if (flight.rerunRequested) {
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

function isSuccessfulPreciseSnapshot(
  snapshot: DashboardSnapshot | null,
): snapshot is DashboardSnapshot {
  return snapshot !== null
    && snapshot.preciseRecentUsageFresh === true
    && typeof snapshot.preciseRecentUsageCoveredAt === "string"
    && snapshot.preciseRecentUsageCoveredAt.length > 0;
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
    }
  }
}
