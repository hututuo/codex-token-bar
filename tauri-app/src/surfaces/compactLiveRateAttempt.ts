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
  noteExternalSuccess: () => boolean;
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
      let accepted = false;
      let cancelled = false;
      let didSettle = false;
      let externalSuccess = false;
      let externalSuccessObserved = false;
      let resolveSettled = () => {};
      const settled = new Promise<void>((resolve) => {
        resolveSettled = resolve;
      });

      cancelCurrentRetry?.();
      cancelCurrentRetry = null;

      const settle = () => {
        if (!didSettle) {
          didSettle = true;
          resolveSettled();
        }
      };

      const isCurrent = () => !cancelled && generation === expectedGeneration;

      const failAttempt = (error: unknown, failureCount: number) => {
        if (isCurrent() && accepted && externalSuccess) {
          settle();
          return;
        }
        operations.cancelStart?.();
        accepted = false;
        if (!isCurrent()) {
          settle();
          return;
        }
        const message = error instanceof Error ? error.message : String(error);
        operations.publishFailure(message || "实时速率流暂不可用");
        const delayMs = retryDelaysMs[Math.min(failureCount, retryDelaysMs.length - 1)];
        cancelCurrentRetry?.();
        cancelCurrentRetry = scheduleRetry(delayMs, () => {
          cancelCurrentRetry = null;
          void run(failureCount + 1);
        });
        settle();
      };

      const run = async (failureCount: number): Promise<void> => {
        accepted = false;
        externalSuccess = false;
        externalSuccessObserved = false;
        let result: CompactLiveRateStartResult;
        try {
          result = await operations.start();
        } catch (error) {
          failAttempt(error, failureCount);
          return;
        }
        if (!isCurrent()) {
          operations.cancelStart?.();
          settle();
          return;
        }
        if (!result.ok || !result.accepted) {
          failAttempt(result.error ?? "实时速率流暂不可用", failureCount);
          return;
        }
        accepted = true;
        externalSuccess = externalSuccessObserved;

        let snapshot: T;
        try {
          snapshot = await operations.readInitial();
        } catch (error) {
          failAttempt(error, failureCount);
          return;
        }
        if (isCurrent() && !externalSuccess) {
          operations.publishSnapshot(snapshot);
        }
        settle();
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
          accepted = false;
          settle();
        },
        noteExternalSuccess() {
          if (!isCurrent()) {
            return false;
          }
          externalSuccessObserved = true;
          if (accepted) {
            externalSuccess = true;
          }
          return true;
        },
        settled,
      };
    },
  };
}
