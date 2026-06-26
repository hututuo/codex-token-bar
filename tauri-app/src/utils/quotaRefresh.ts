import type { QuotaSnapshot } from "../types/dashboard";

export const QUOTA_RESET_REFRESH_GRACE_MS = 5_000;

export function nextQuotaResetRefreshDelayMs(
  quota: QuotaSnapshot,
  nowMs = Date.now(),
  graceMs = QUOTA_RESET_REFRESH_GRACE_MS,
): number | null {
  const resetTargets = [
    quota.fiveHour.resetsAtUnix,
    quota.sevenDay.resetsAtUnix,
  ]
    .filter((value): value is number => typeof value === "number" && Number.isFinite(value) && value > 0)
    .map((resetUnix) => resetUnix * 1_000 + graceMs)
    .filter((targetMs) => targetMs > nowMs)
    .sort((a, b) => a - b);

  if (resetTargets.length === 0) {
    return null;
  }

  return Math.max(0, resetTargets[0] - nowMs);
}
