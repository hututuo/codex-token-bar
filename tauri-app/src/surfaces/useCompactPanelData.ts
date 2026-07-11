import { useMemo } from "react";
import type { AccountQuotaBundle, FloatingPanelSnapshot } from "../types/dashboard";
import { compactQuotaLabel } from "../utils/quota";
import {
  compactFloatingPaceLabel,
  compactResetCreditRateBarSuffix,
  compactResetCreditStandaloneSuffix,
} from "./compactPanelLabels";
import { useCompactPanelQuota } from "./useCompactPanelQuota";
import { useCompactPanelSnapshot } from "./useCompactPanelSnapshot";

interface CompactPanelDataOptions {
  active?: boolean;
  liveRateEnabled?: boolean;
  liveRateOwnerToken?: string;
  quotaEnabled?: boolean;
  quotaInitialDelayMs?: number;
  quotaIntervalMs?: number;
  sourceKey?: string | null;
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
  const liveRateOwnerToken = options.liveRateOwnerToken ?? "compact-live-rate";
  const quotaEnabled = options.quotaEnabled ?? true;
  const quotaInitialDelayMs = options.quotaInitialDelayMs ?? DEFAULT_QUOTA_INITIAL_DELAY_MS;
  const quotaIntervalMs = options.quotaIntervalMs ?? DEFAULT_QUOTA_INTERVAL_MS;
  const sourceKey = options.sourceKey ?? null;

  const rawSnapshot = useCompactPanelSnapshot({
    active,
    liveRateEnabled,
    liveRateOwnerToken,
    sourceKey,
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
      const hasQuotaPace = quota.quota.paceLabel && quota.quota.paceLabel !== "额度待读取";
      const compactPaceLabel = hasQuotaPace
        ? compactFloatingPaceLabel(quota.quota.paceLabel)
        : rawSnapshot.trendLabel;
      const rateBarSuffix = hasQuotaPace ? compactResetCreditRateBarSuffix(quota.quota.resetCredit) : "";
      const standaloneSuffix = hasQuotaPace ? compactResetCreditStandaloneSuffix(quota.quota.resetCredit) : "";

      return {
        ...rawSnapshot,
        trendLabel: compactPaceLabel,
        resetCreditLabel: "",
        resetCreditRateBarLabel: rateBarSuffix,
        resetCreditStandaloneLabel: standaloneSuffix,
        fiveHourLabel: quotaLabels.fiveHour,
        fiveHourAvailability: quota.quota.fiveHour.availability,
        fiveHourRemainingPercent: quota.quota.fiveHour.remainingPercent,
        sevenDayLabel: quotaLabels.sevenDay,
        sevenDayAvailability: quota.quota.sevenDay.availability,
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
