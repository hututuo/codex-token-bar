export interface CompactLiveRateStartResult {
  accepted: boolean;
  error?: string;
  ok: boolean;
}

export interface CompactLiveRateAttemptOperations<T> {
  cancelStart?: () => void;
  publishFailure: (message: string) => void;
  publishSnapshot: (snapshot: T) => void;
  readInitial: () => Promise<T>;
  start: () => Promise<CompactLiveRateStartResult>;
}

interface CompactLiveRateAttemptOptions {
  retryDelaysMs?: readonly number[];
  scheduleRetry?: (delayMs: number, retry: () => void) => () => void;
}

export interface CompactLiveRateAttemptHandle {
  cancel: () => void;
  settled: Promise<void>;
}

const DEFAULT_RETRY_DELAYS_MS = [5_000, 10_000, 30_000] as const;

export function createCompactLiveRateAttemptRunner(
  options: CompactLiveRateAttemptOptions = {},
) {
  const retryDelaysMs = options.retryDelaysMs ?? DEFAULT_RETRY_DELAYS_MS;
  const scheduleRetry = options.scheduleRetry ?? ((delayMs, retry) => {
    const timer = window.setTimeout(retry, delayMs);
    return () => window.clearTimeout(timer);
  });
  let generation = 0;
  let cancelCurrentRetry: (() => void) | null = null;

  return {
    start<T>(operations: CompactLiveRateAttemptOperations<T>): CompactLiveRateAttemptHandle {
      generation += 1;
      const expectedGeneration = generation;
      let cancelled = false;
      let resolveSettled = () => {};
      const settled = new Promise<void>((resolve) => {
        resolveSettled = resolve;
      });

      cancelCurrentRetry?.();
      cancelCurrentRetry = null;

      const run = async (failureCount: number): Promise<void> => {
        const result = await operations.start();
        if (cancelled || generation !== expectedGeneration) {
          operations.cancelStart?.();
          resolveSettled();
          return;
        }
        if (!result.ok || !result.accepted) {
          operations.cancelStart?.();
          operations.publishFailure(result.error ?? "实时速率流暂不可用");
          const delayMs = retryDelaysMs[Math.min(failureCount, retryDelaysMs.length - 1)];
          cancelCurrentRetry = scheduleRetry(delayMs, () => {
            cancelCurrentRetry = null;
            void run(failureCount + 1);
          });
          resolveSettled();
          return;
        }

        const snapshot = await operations.readInitial();
        if (!cancelled && generation === expectedGeneration) {
          operations.publishSnapshot(snapshot);
        }
        resolveSettled();
      };

      void run(0);
      return {
        cancel() {
          if (cancelled) {
            return;
          }
          cancelled = true;
          if (generation === expectedGeneration) {
            generation += 1;
            cancelCurrentRetry?.();
            cancelCurrentRetry = null;
          }
          operations.cancelStart?.();
          resolveSettled();
        },
        settled,
      };
    },
  };
}
