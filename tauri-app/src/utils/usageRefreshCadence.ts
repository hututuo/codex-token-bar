import type { LiveRateSnapshot } from "../types/dashboard";

export const ACTIVE_USAGE_REFRESH_INTERVAL_MS = 30_000;
export const LIVE_USAGE_ACTIVITY_HOLD_MS = 31_000;

const MIN_ACTIVE_TOKENS_PER_SECOND = 0.05;

export function liveRateHasUsageRefreshActivity(
  liveRate: Pick<LiveRateSnapshot, "selectedTokensPerSecond" | "tokensPerSecond">,
): boolean {
  return (
    liveRate.tokensPerSecond > MIN_ACTIVE_TOKENS_PER_SECOND
    || liveRate.selectedTokensPerSecond > MIN_ACTIVE_TOKENS_PER_SECOND
  );
}

export function usageRefreshIntervalMs({
  baselineIntervalMs,
  lastLiveActivityAtMs,
  nowMs = Date.now(),
}: {
  baselineIntervalMs: number;
  lastLiveActivityAtMs: number;
  nowMs?: number;
}): number {
  if (
    lastLiveActivityAtMs > 0
    && nowMs - lastLiveActivityAtMs < LIVE_USAGE_ACTIVITY_HOLD_MS
  ) {
    return ACTIVE_USAGE_REFRESH_INTERVAL_MS;
  }
  return baselineIntervalMs;
}
