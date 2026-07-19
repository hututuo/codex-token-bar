export interface FloatingCoordinates {
  x: number;
  y: number;
}

interface TimerApi {
  set(callback: () => void, delayMs: number): ReturnType<typeof setTimeout>;
  clear(timer: ReturnType<typeof setTimeout>): void;
}

const DEFAULT_TIMER_API: TimerApi = {
  set: (callback, delayMs) => setTimeout(callback, delayMs),
  clear: (timer) => clearTimeout(timer),
};

export function createFloatingPositionPersistence(
  persist: (position: FloatingCoordinates) => Promise<unknown>,
  delayMs = 400,
  timerApi: TimerApi = DEFAULT_TIMER_API,
) {
  let persisted: FloatingCoordinates | null = null;
  let pending: FloatingCoordinates | null = null;
  let queued: FloatingCoordinates | null = null;
  let writing: FloatingCoordinates | null = null;
  let timer: ReturnType<typeof setTimeout> | null = null;

  const clearTimer = () => {
    if (timer !== null) {
      timerApi.clear(timer);
      timer = null;
    }
  };

  const drain = () => {
    if (writing !== null || queued === null) {
      return;
    }
    const next = queued;
    queued = null;
    if (sameCoordinates(next, persisted)) {
      drain();
      return;
    }
    writing = next;
    void persist(next)
      .then(() => {
        persisted = next;
      })
      .catch(() => {})
      .finally(() => {
        writing = null;
        drain();
      });
  };

  const flush = () => {
    clearTimer();
    const next = pending;
    pending = null;
    if (next === null) {
      return;
    }
    queued = next;
    drain();
  };

  return {
    setPersisted(position: FloatingCoordinates | null) {
      persisted = position;
      if (pending !== null && sameCoordinates(pending, persisted)) {
        pending = null;
        clearTimer();
      }
    },
    schedule(position: FloatingCoordinates) {
      const latestRequested = pending ?? queued ?? writing ?? persisted;
      if (sameCoordinates(position, latestRequested)) {
        return;
      }
      if (sameCoordinates(position, persisted) && writing === null) {
        pending = null;
        queued = null;
        clearTimer();
        return;
      }
      if (sameCoordinates(position, pending)) {
        return;
      }
      pending = position;
      clearTimer();
      timer = timerApi.set(flush, delayMs);
    },
    flush,
  };
}

function sameCoordinates(
  left: FloatingCoordinates | null,
  right: FloatingCoordinates | null,
): boolean {
  return left !== null && right !== null && left.x === right.x && left.y === right.y;
}
