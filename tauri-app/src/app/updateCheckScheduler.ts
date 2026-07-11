export const DEFAULT_UPDATE_CHECK_INTERVAL_MS = 4 * 60 * 60 * 1_000;

export type UpdateCheckOutcome<T> =
  | { kind: "skipped" }
  | { kind: "completed"; value: T }
  | { kind: "failed"; error: unknown };

interface UpdateCheckStorage {
  getItem: (key: string) => string | null;
  setItem: (key: string, value: string) => void;
}

interface UpdateCheckSchedulerOptions<T> {
  check: () => Promise<T>;
  intervalMs?: number;
  now?: () => number;
  storage?: UpdateCheckStorage | null;
  storageKey: string;
}

export interface UpdateCheckScheduler<T> {
  runAutomatic: () => Promise<UpdateCheckOutcome<T>>;
  runManual: () => Promise<UpdateCheckOutcome<T>>;
}

export function createUpdateCheckScheduler<T>({
  check,
  intervalMs = DEFAULT_UPDATE_CHECK_INTERVAL_MS,
  now = Date.now,
  storage = null,
  storageKey,
}: UpdateCheckSchedulerOptions<T>): UpdateCheckScheduler<T> {
  let inFlight: Promise<UpdateCheckOutcome<T>> | null = null;
  let processLastAttemptAt = readStoredAttempt(storage, storageKey);

  const run = (manual: boolean): Promise<UpdateCheckOutcome<T>> => {
    if (inFlight !== null) {
      return inFlight;
    }

    const attemptedAt = now();
    if (!manual && !isAutomaticCheckDue(processLastAttemptAt, attemptedAt, intervalMs)) {
      return Promise.resolve({ kind: "skipped" });
    }

    processLastAttemptAt = attemptedAt;
    writeStoredAttempt(storage, storageKey, attemptedAt);
    let checkPromise: Promise<T>;
    try {
      checkPromise = check();
    } catch (error) {
      checkPromise = Promise.reject(error);
    }
    const pending: Promise<UpdateCheckOutcome<T>> = checkPromise.then(
      (value): UpdateCheckOutcome<T> => ({ kind: "completed", value }),
      (error): UpdateCheckOutcome<T> => ({ kind: "failed", error }),
    );
    const tracked = pending.finally(() => {
      if (inFlight === tracked) {
        inFlight = null;
      }
    });
    inFlight = tracked;
    return tracked;
  };

  return {
    runAutomatic: () => run(false),
    runManual: () => run(true),
  };
}

function isAutomaticCheckDue(lastAttemptAt: number | null, now: number, intervalMs: number) {
  if (lastAttemptAt === null || lastAttemptAt > now) {
    return true;
  }
  return now - lastAttemptAt >= intervalMs;
}

function readStoredAttempt(storage: UpdateCheckStorage | null, key: string): number | null {
  try {
    const parsed = Number(storage?.getItem(key));
    return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
  } catch {
    return null;
  }
}

function writeStoredAttempt(storage: UpdateCheckStorage | null, key: string, value: number) {
  try {
    storage?.setItem(key, String(value));
  } catch {
    // Process-local cadence still prevents a retry loop when storage is unavailable.
  }
}
