import { useMemo } from "react";
import type { AccountQuotaBundle, FloatingPanelSnapshot, ResetCreditSummary } from "../types/dashboard";
import { compactQuotaLabel } from "../utils/quota";
import { useCompactPanelQuota } from "./useCompactPanelQuota";
import { useCompactPanelSnapshot } from "./useCompactPanelSnapshot";

interface CompactPanelDataOptions {
  active?: boolean;
  liveRateEnabled?: boolean;
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

const DEFAULT_QUOTA_INITIAL_DELAY_MS = 8_000;
const DEFAULT_QUOTA_INTERVAL_MS = 60_000;

export function useCompactPanelData(options: CompactPanelDataOptions = {}): CompactPanelData {
  const active = options.active ?? true;
  const liveRateEnabled = options.liveRateEnabled ?? true;
  const quotaEnabled = options.quotaEnabled ?? true;
  const quotaInitialDelayMs = options.quotaInitialDelayMs ?? DEFAULT_QUOTA_INITIAL_DELAY_MS;
  const quotaIntervalMs = options.quotaIntervalMs ?? DEFAULT_QUOTA_INTERVAL_MS;

  const rawSnapshot = useCompactPanelSnapshot({
    active: active && liveRateEnabled,
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
    () => {
      const compactPaceLabel = quota.quota.paceLabel && quota.quota.paceLabel !== "额度待读取"
        ? quota.quota.paceLabel
        : rawSnapshot.trendLabel;

      return {
        ...rawSnapshot,
        trendLabel: compactPaceLabel,
        resetCreditLabel: compactResetCreditLabel(quota.quota.resetCredit),
        fiveHourLabel: quotaLabels.fiveHour,
        fiveHourRemainingPercent: quota.quota.fiveHour.remainingPercent,
        sevenDayLabel: quotaLabels.sevenDay,
        sevenDayRemainingPercent: quota.quota.sevenDay.remainingPercent,
      };
    },
    [quota, quotaLabels, rawSnapshot],
  );

  return {
    snapshot,
    rawSnapshot,
    quota,
    quotaLabels,
  };
}

function compactResetCreditLabel(summary: ResetCreditSummary): string {
  if (summary.availableCount > 0) {
    return `${summary.availableCount}卡`;
  }
  if (summary.status.includes("待读取")) {
    return "卡--";
  }
  return "0卡";
}
