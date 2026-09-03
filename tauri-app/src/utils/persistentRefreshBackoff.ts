export const PERSISTENT_REFRESH_RETRY_DELAYS_MS = [
  1_000,
  2_000,
  5_000,
  10_000,
  30_000,
  60_000,
  120_000,
  300_000,
  600_000,
] as const;

export const QUOTA_REFRESH_RETRY_DELAYS_MS = [
  1_000,
  3_000,
  5_000,
  10_000,
  30_000,
  60_000,
  120_000,
] as const;

export const MAX_QUOTA_REFRESH_DELAY_MS = 60_000;
export const MAX_BACKGROUND_REFRESH_DELAY_MS = 600_000;
export const SILENT_QUOTA_REFRESH_FAILURES = 3;

export function persistentRefreshDelayMs(
  failureCount: number,
  maximumDelayMs = MAX_QUOTA_REFRESH_DELAY_MS,
): number {
  const normalizedFailureCount = Number.isFinite(failureCount)
    ? Math.max(0, Math.floor(failureCount))
    : 0;
  const index = Math.min(
    normalizedFailureCount,
    PERSISTENT_REFRESH_RETRY_DELAYS_MS.length - 1,
  );
  const maximum = Number.isFinite(maximumDelayMs)
    ? Math.max(100, maximumDelayMs)
    : MAX_QUOTA_REFRESH_DELAY_MS;
  return Math.min(PERSISTENT_REFRESH_RETRY_DELAYS_MS[index], maximum);
}

export function quotaRefreshDelayMs(failureCount: number): number {
  const normalizedFailureCount = Number.isFinite(failureCount)
    ? Math.max(0, Math.floor(failureCount))
    : 0;
  const index = Math.min(
    normalizedFailureCount,
    QUOTA_REFRESH_RETRY_DELAYS_MS.length - 1,
  );
  return QUOTA_REFRESH_RETRY_DELAYS_MS[index];
}

export function shouldPublishQuotaRefreshResult(
  succeeded: boolean,
  previousFailureCount: number,
): boolean {
  return succeeded || previousFailureCount >= SILENT_QUOTA_REFRESH_FAILURES;
}
