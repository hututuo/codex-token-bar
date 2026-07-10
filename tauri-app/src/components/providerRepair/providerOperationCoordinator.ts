const PROVIDER_STATUS_POLL_MS = 500;
const DEFAULT_MAX_STATUS_FAILURES = 3;
const DEFAULT_MAX_NOT_STARTED_READS = 8;

export type ProviderOperationLifecycle = "notStarted" | "active" | "finished";

export interface ProviderOperationStatus {
  operationId: string;
  lifecycle: ProviderOperationLifecycle;
}

export interface ProviderRepairSafetyLatch {
  clearFinished: (operationId: string) => boolean;
  getSnapshot: () => string | null;
  latch: (operationId: string) => void;
  subscribe: (listener: (operationId: string | null) => void) => () => void;
}

interface ReconcileProviderRepairOperationOptions {
  maxNotStartedReads?: number;
  maxStatusFailures?: number;
  operationId: string;
  readStatus: (operationId: string) => Promise<ProviderOperationStatus>;
  signal: AbortSignal;
  waitForNextPoll?: (signal: AbortSignal) => Promise<void>;
}

export type ProviderOperationReconciliationOutcome = "aborted" | "finished" | "statusUnavailable";

export function createProviderRepairSafetyLatch(): ProviderRepairSafetyLatch {
  let operationId: string | null = null;
  const listeners = new Set<(nextOperationId: string | null) => void>();

  function publish(nextOperationId: string | null) {
    if (operationId === nextOperationId) {
      return;
    }
    operationId = nextOperationId;
    for (const listener of listeners) {
      listener(operationId);
    }
  }

  return {
    clearFinished(finishedOperationId) {
      if (operationId !== finishedOperationId) {
        return false;
      }
      publish(null);
      return true;
    },
    getSnapshot() {
      return operationId;
    },
    latch(nextOperationId) {
      publish(nextOperationId);
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
