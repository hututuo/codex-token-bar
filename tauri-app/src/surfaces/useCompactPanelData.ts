import { useMemo } from "react";
import type { AccountQuotaBundle, FloatingPanelSnapshot } from "../types/dashboard";
import { compactQuotaLabel } from "../utils/quota";
import { useCompactPanelQuota } from "./useCompactPanelQuota";
import { useCompactPanelSnapshot } from "./useCompactPanelSnapshot";

interface CompactPanelDataOptions {
  active?: boolean;
  snapshotIntervalMs?: number;
  quotaEnabled?: boolean;
  quotaInitialDelayMs?: number;
  quotaIntervalMs?: number;
}

export interface CompactPanelData {
  snapshot: FloatingPanelSnapshot;
  rawSnapshot: FloatingPanelSnapshot;
  quota: AccountQuotaBundle;
  quotaLabels: {
    fiveHour: string;
    sevenDay: string;
  };
}

const DEFAULT_SNAPSHOT_INTERVAL_MS = 500;
const DEFAULT_QUOTA_INITIAL_DELAY_MS = 8_000;
const DEFAULT_QUOTA_INTERVAL_MS = 180_000;

export function useCompactPanelData(options: CompactPanelDataOptions = {}): CompactPanelData {
  const active = options.active ?? true;
  const snapshotIntervalMs = options.snapshotIntervalMs ?? DEFAULT_SNAPSHOT_INTERVAL_MS;
  const quotaEnabled = options.quotaEnabled ?? true;
  const quotaInitialDelayMs = options.quotaInitialDelayMs ?? DEFAULT_QUOTA_INITIAL_DELAY_MS;
  const quotaIntervalMs = options.quotaIntervalMs ?? DEFAULT_QUOTA_INTERVAL_MS;

  const rawSnapshot = useCompactPanelSnapshot({
    active,
    intervalMs: snapshotIntervalMs,
  });
  const quota = useCompactPanelQuota({
    active,
    enabled: quotaEnabled,
    initialDelayMs: quotaInitialDelayMs,
    intervalMs: quotaIntervalMs,
  });

  const quotaLabels = useMemo(
    () => ({
      fiveHour: compactQuotaLabel(quota.quota.fiveHour),
      sevenDay: compactQuotaLabel(quota.quota.sevenDay),
    }),
    [quota],
  );

  const snapshot = useMemo(
    () => ({
      ...rawSnapshot,
      fiveHourLabel: quotaLabels.fiveHour,
      fiveHourRemainingPercent: quota.quota.fiveHour.remainingPercent,
      sevenDayLabel: quotaLabels.sevenDay,
      sevenDayRemainingPercent: quota.quota.sevenDay.remainingPercent,
    }),
    [quota, quotaLabels, rawSnapshot],
  );

  return {
    snapshot,
    rawSnapshot,
    quota,
    quotaLabels,
  };
}
