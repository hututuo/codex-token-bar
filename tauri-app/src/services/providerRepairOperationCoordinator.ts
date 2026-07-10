const PROVIDER_STATUS_POLL_MS = 500;
const DEFAULT_MAX_STATUS_FAILURES = 3;
const DEFAULT_MAX_NOT_STARTED_READS = 8;

export type ProviderOperationLifecycle = "notStarted" | "active" | "finished";
export type ProviderRepairSafetyPhase =
  | "bootstrapping"
  | "ready"
  | "invokePending"
  | "uncertain"
  | "statusUnavailable";

export interface ProviderOperationStatus {
  operationId: string;
  lifecycle: ProviderOperationLifecycle;
}

export interface ProviderOperationOwnership {
  canonicalHome: string;
  operationId: string;
}

export interface ProviderOperationOwnershipDiscovery {
  activeOperations: ProviderOperationOwnership[];
}

export interface ProviderRepairSafetySnapshot {
  generation: number;
  operationIds: string[];
  phase: ProviderRepairSafetyPhase;
}

export interface ProviderRepairSafetyLatch {
  beginBootstrap: () => void;
  clearFinished: (operationId: string) => boolean;
  completeBootstrap: (operationIds: string[], expectedGeneration?: number) => boolean;
  getSnapshot: () => ProviderRepairSafetySnapshot;
  markInvokePending: (operationId: string) => void;
  markStatusUnavailable: (expectedGeneration: number) => boolean;
  markUncertain: (operationId: string) => void;
  subscribe: (listener: (snapshot: ProviderRepairSafetySnapshot) => void) => () => void;
}

interface ReconcileProviderRepairOperationOptions {
  maxNotStartedReads?: number;
  maxStatusFailures?: number;
  operationId: string;
  readStatus: (operationId: string) => Promise<ProviderOperationStatus>;
  signal: AbortSignal;
  waitForNextPoll?: (signal: AbortSignal) => Promise<void>;
}

interface BootstrapProviderRepairSafetyLatchOptions {
  discoverOwnership: () => Promise<ProviderOperationOwnershipDiscovery>;
  safetyLatch: ProviderRepairSafetyLatch;
}

export type ProviderOperationReconciliationOutcome = "aborted" | "finished" | "statusUnavailable";
export type ProviderRepairBootstrapOutcome =
  | "ownersDiscovered"
  | "ready"
  | "stale"
  | "statusUnavailable";

export function createProviderRepairSafetyLatch(): ProviderRepairSafetyLatch {
  let snapshot: ProviderRepairSafetySnapshot = {
    generation: 0,
    operationIds: [],
    phase: "bootstrapping",
  };
  const listeners = new Set<(nextSnapshot: ProviderRepairSafetySnapshot) => void>();

  function publish(phase: ProviderRepairSafetyPhase, operationIds: string[]) {
    snapshot = {
      generation: snapshot.generation + 1,
      operationIds: [...new Set(operationIds)],
      phase,
    };
    for (const listener of listeners) {
      listener(snapshot);
    }
  }

  return {
    beginBootstrap() {
      publish("bootstrapping", []);
    },
    clearFinished(operationId) {
      if (!snapshot.operationIds.includes(operationId)) {
        return false;
      }
      const remaining = snapshot.operationIds.filter((candidate) => candidate !== operationId);
      publish(remaining.length === 0 ? "ready" : "uncertain", remaining);
      return true;
    },
    completeBootstrap(operationIds, expectedGeneration = snapshot.generation) {
      if (snapshot.phase !== "bootstrapping" || snapshot.generation !== expectedGeneration) {
        return false;
      }
      publish(operationIds.length === 0 ? "ready" : "uncertain", operationIds);
      return true;
    },
    getSnapshot() {
      return snapshot;
    },
    markInvokePending(operationId) {
      publish("invokePending", [operationId]);
    },
    markStatusUnavailable(expectedGeneration) {
      if (snapshot.generation !== expectedGeneration) {
        return false;
      }
      publish("statusUnavailable", snapshot.operationIds);
      return true;
    },
    markUncertain(operationId) {
      publish("uncertain", [operationId]);
    },
    subscribe(listener) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
  };
}

export const providerRepairSafetyLatch = createProviderRepairSafetyLatch();

export function deriveProviderRepairInteractionState(
  hasPendingLocalAction: boolean,
  safetyPhase: ProviderRepairSafetyPhase,
) {
  return {
    closeBlocked: hasPendingLocalAction
      && safetyPhase !== "uncertain"
      && safetyPhase !== "statusUnavailable",
    controlsDisabled: hasPendingLocalAction || safetyPhase !== "ready",
  };
}

export async function bootstrapProviderRepairSafetyLatch({
  discoverOwnership,
  safetyLatch,
}: BootstrapProviderRepairSafetyLatchOptions): Promise<ProviderRepairBootstrapOutcome> {
  const bootstrapSnapshot = safetyLatch.getSnapshot();
  if (bootstrapSnapshot.phase !== "bootstrapping") {
    return "stale";
  }

  try {
    const discovery = await discoverOwnership();
    const operationIds = discovery.activeOperations.map((operation) => operation.operationId);
    if (!safetyLatch.completeBootstrap(operationIds, bootstrapSnapshot.generation)) {
      return "stale";
    }
    return operationIds.length === 0 ? "ready" : "ownersDiscovered";
  } catch {
    return safetyLatch.markStatusUnavailable(bootstrapSnapshot.generation)
      ? "statusUnavailable"
      : "stale";
  }
}

export async function reconcileProviderRepairOperation({
  maxNotStartedReads = DEFAULT_MAX_NOT_STARTED_READS,
  maxStatusFailures = DEFAULT_MAX_STATUS_FAILURES,
  operationId,
  readStatus,
  signal,
  waitForNextPoll = waitForProviderStatusPoll,
}: ReconcileProviderRepairOperationOptions): Promise<ProviderOperationReconciliationOutcome> {
  let notStartedReads = 0;
  let statusFailures = 0;

  while (!signal.aborted) {
    let status: ProviderOperationStatus;
    try {
      status = await raceWithAbort(readStatus(operationId), signal);
      if (status.operationId !== operationId || !isProviderOperationLifecycle(status.lifecycle)) {
        throw new Error("Provider operation status identity mismatch.");
      }
    } catch (error) {
      if (signal.aborted || error === ABORTED) {
        return "aborted";
      }
      statusFailures += 1;
      if (statusFailures >= maxStatusFailures) {
        return "statusUnavailable";
      }
      if (!await waitForNextPollOrAbort(waitForNextPoll, signal)) {
        return "aborted";
      }
      continue;
    }

    if (status.lifecycle === "finished") {
      return "finished";
    }
    if (status.lifecycle === "notStarted") {
      notStartedReads += 1;
      if (notStartedReads >= maxNotStartedReads) {
        return "statusUnavailable";
      }
    } else {
      notStartedReads = 0;
    }

    if (!await waitForNextPollOrAbort(waitForNextPoll, signal)) {
      return "aborted";
    }
  }

  return "aborted";
}

const ABORTED = Symbol("provider-operation-aborted");

function isProviderOperationLifecycle(value: unknown): value is ProviderOperationLifecycle {
  return value === "notStarted" || value === "active" || value === "finished";
}

async function waitForNextPollOrAbort(
  waitForNextPoll: (signal: AbortSignal) => Promise<void>,
  signal: AbortSignal,
) {
  try {
    await raceWithAbort(waitForNextPoll(signal), signal);
    return true;
  } catch (error) {
    if (signal.aborted || error === ABORTED) {
      return false;
    }
    throw error;
  }
}

function raceWithAbort<T>(promise: Promise<T>, signal: AbortSignal): Promise<T> {
  if (signal.aborted) {
    return Promise.reject(ABORTED);
  }

  return new Promise<T>((resolve, reject) => {
    const abort = () => {
      reject(ABORTED);
    };
    signal.addEventListener("abort", abort, { once: true });
    promise.then(
      (value) => {
        signal.removeEventListener("abort", abort);
        resolve(value);
      },
      (error) => {
        signal.removeEventListener("abort", abort);
        reject(error);
      },
    );
  });
}

function waitForProviderStatusPoll(signal: AbortSignal) {
  return new Promise<void>((resolve) => {
    if (signal.aborted) {
      resolve();
      return;
    }
    const finish = () => {
      signal.removeEventListener("abort", abort);
      resolve();
    };
    const timer = window.setTimeout(finish, PROVIDER_STATUS_POLL_MS);
    const abort = () => {
      window.clearTimeout(timer);
    };
    signal.addEventListener("abort", abort, { once: true });
  });
}
