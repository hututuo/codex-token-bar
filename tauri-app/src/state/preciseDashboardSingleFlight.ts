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

const flightsBySource = new Map<string, PreciseDashboardFlight>();

export function loadPreciseDashboardSingleFlight(
  sourceToken: CodexHomeSourceToken,
  loader: PreciseDashboardLoader,
  subscriber?: PreciseDashboardSubscriber,
): PreciseDashboardFlightHandle {
  const key = preciseDashboardSourceKey(sourceToken);
  const existing = flightsBySource.get(key);
  if (existing && !existing.settled) {
    existing.latestLoader = loader;
    if (!existing.rerunStarted) {
      existing.rerunRequested = true;
    }
    return flightHandle(existing, subscriber);
  }
  if (existing) {
    flightsBySource.delete(key);
  }

  const flight: PreciseDashboardFlight = {
    latestLoader: loader,
    rerunRequested: false,
    rerunStarted: false,
    settled: false,
    settlementWaiters: new Set(),
    subscriberSequence: 0,
    promise: Promise.resolve(null),
  };
  flight.promise = runPreciseDashboardFlight(flight)
    .then(
      (result) => {
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
      return trailingResult ?? firstResult;
    } catch (error) {
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
