interface TimerApi {
  set(callback: () => void, delayMs: number): ReturnType<typeof setTimeout>;
  clear(timer: ReturnType<typeof setTimeout>): void;
}

interface PendingWrite<T> {
  generation: number;
  value: T;
}

interface TrailingSettingsPersistenceOptions<T, Result> {
  delayMs?: number;
  equals?: (left: T, right: T) => boolean;
  timerApi?: TimerApi;
  persistedValue?: (requested: T, result: Result) => T;
  onLatestPersisted?: (value: T, result: Result | null) => void;
  onLatestError?: (error: unknown, value: T) => void;
}

export interface TrailingSettingsPersistence<T> {
  setPersisted(value: T | null): void;
  schedule(value: T): void;
  flush(): Promise<void>;
}

const DEFAULT_TIMER_API: TimerApi = {
  set: (callback, delayMs) => setTimeout(callback, delayMs),
  clear: (timer) => clearTimeout(timer),
};

export function createTrailingSettingsPersistence<T, Result>(
  persist: (value: T) => Promise<Result>,
  options: TrailingSettingsPersistenceOptions<T, Result> = {},
): TrailingSettingsPersistence<T> {
  const delayMs = options.delayMs ?? 350;
  const equals = options.equals ?? Object.is;
  const timerApi = options.timerApi ?? DEFAULT_TIMER_API;
  const persistedValue = options.persistedValue ?? ((requested: T) => requested);

  let persisted: T | null = null;
  let latestRequested: T | null = null;
  let latestGeneration = 0;
  let latestFailedGeneration: number | null = null;
  let latestNotifiedGeneration = 0;
  let pending: PendingWrite<T> | null = null;
  let writing: PendingWrite<T> | null = null;
  let timer: ReturnType<typeof setTimeout> | null = null;
  let idleWaiters: Array<() => void> = [];

  const isSame = (left: T | null, right: T | null) => (
    left !== null && right !== null && equals(left, right)
  );

  const clearTimer = () => {
    if (timer !== null) {
      timerApi.clear(timer);
      timer = null;
    }
  };

  const resolveIdleWaiters = () => {
    if (timer !== null || pending !== null || writing !== null) {
      return;
    }
    const waiters = idleWaiters;
    idleWaiters = [];
    for (const resolve of waiters) {
      resolve();
    }
  };

  const notifyLatestPersisted = (value: T, result: Result | null) => {
    if (latestNotifiedGeneration === latestGeneration) {
      return;
    }
    latestNotifiedGeneration = latestGeneration;
    latestFailedGeneration = null;
    options.onLatestPersisted?.(value, result);
  };

  const drain = () => {
    if (timer !== null || writing !== null) {
      return;
    }

    while (pending !== null) {
      const next = pending;
      pending = null;
      if (isSame(next.value, persisted)) {
        if (next.generation === latestGeneration) {
          notifyLatestPersisted(next.value, null);
        }
        continue;
      }

      writing = next;
      void persist(next.value)
        .then((result) => {
          persisted = persistedValue(next.value, result);
          if (isSame(latestRequested, persisted)) {
            pending = null;
            clearTimer();
            notifyLatestPersisted(persisted, result);
          }
        })
        .catch((error) => {
          if (next.generation === latestGeneration) {
            latestFailedGeneration = next.generation;
            options.onLatestError?.(error, next.value);
          }
        })
        .finally(() => {
          writing = null;
          drain();
          resolveIdleWaiters();
        });
      return;
    }

    resolveIdleWaiters();
  };

  const startTimer = () => {
    clearTimer();
    let firedSynchronously = false;
    const nextTimer = timerApi.set(() => {
      firedSynchronously = true;
      timer = null;
      drain();
    }, delayMs);
    if (!firedSynchronously) {
      timer = nextTimer;
    }
  };

  return {
    setPersisted(value) {
      persisted = value;
      if (latestRequested === null) {
        latestRequested = value;
      }
      if (pending !== null && isSame(pending.value, persisted)) {
        const settled = pending;
        pending = null;
        clearTimer();
        if (settled.generation === latestGeneration && persisted !== null) {
          notifyLatestPersisted(persisted, null);
        }
      }
      resolveIdleWaiters();
    },

    schedule(value) {
      if (
        isSame(value, latestRequested)
        && latestFailedGeneration !== latestGeneration
      ) {
        return;
      }

      latestGeneration += 1;
      latestRequested = value;
      latestFailedGeneration = null;

      if (writing === null && isSame(value, persisted)) {
        pending = null;
        clearTimer();
        notifyLatestPersisted(value, null);
        resolveIdleWaiters();
        return;
      }

      pending = { generation: latestGeneration, value };
      startTimer();
    },

    flush() {
      clearTimer();
      drain();
      if (timer === null && pending === null && writing === null) {
        return Promise.resolve();
      }
      return new Promise<void>((resolve) => {
        idleWaiters.push(resolve);
      });
    },
  };
}
