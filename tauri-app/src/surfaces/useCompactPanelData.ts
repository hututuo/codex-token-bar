import { useMemo } from "react";
import type {
  AccountQuotaBundle,
  CodexHomeSourceToken,
  FloatingPanelSnapshot,
  RunningThreadSummary,
} from "../types/dashboard";
import { compactQuotaLabel, expectedRemainingPercentByEvenPace } from "../utils/quota";
import {
  compactFloatingPaceLabel,
  compactResetCreditRateBarSuffix,
  compactResetCreditStandaloneSuffix,
} from "./compactPanelLabels";
import { useCompactPanelQuota } from "./useCompactPanelQuota";
import { useCompactPanelSnapshot } from "./useCompactPanelSnapshot";
import { useCompactPanelAggregate } from "./useCompactPanelAggregate";
import { useRunningThreadSummary } from "../state/useRunningThreadSummary";

interface CompactPanelDataOptions {
  active?: boolean;
  liveRateEnabled?: boolean;
  liveRateOwnerToken?: string;
  quotaEnabled?: boolean;
  quotaInitialDelayMs?: number;
  quotaIntervalMs?: number;
  quotaSource?: "dashboard" | "direct";
  backgroundAggregateEnabled?: boolean;
  runningEnabled?: boolean;
  snapshotEnabled?: boolean;
  sourceToken?: CodexHomeSourceToken | null;
}

export interface CompactPanelData {
  snapshot: FloatingPanelSnapshot;
  rawSnapshot: FloatingPanelSnapshot;
  quota: AccountQuotaBundle;
  quotaLabels: {
    fiveHour: string;
    sevenDay: string;
  };
  runningThreads: RunningThreadSummary;
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
  const quotaSource = options.quotaSource ?? "dashboard";
  const runningEnabled = options.runningEnabled ?? true;
  const snapshotEnabled = options.snapshotEnabled ?? true;
  const sourceToken = options.sourceToken ?? null;
  const sourceActive = active && sourceToken !== null;

  useCompactPanelAggregate({
    active: sourceActive && (options.backgroundAggregateEnabled ?? false),
    sourceToken,
  });

  const rawSnapshot = useCompactPanelSnapshot({
    active: sourceActive && snapshotEnabled,
    liveRateEnabled,
    liveRateOwnerToken,
    sourceToken,
  });
  const quota = useCompactPanelQuota({
    active: sourceActive && quotaEnabled,
    enabled: quotaEnabled,
    initialDelayMs: quotaInitialDelayMs,
    intervalMs: quotaIntervalMs,
    followDashboardUpdates: quotaSource === "dashboard",
    sourceToken,
  });
  const runningThreads = useRunningThreadSummary({
    active: sourceActive && runningEnabled,
    sourceToken,
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
        fiveHourExpectedRemainingPercent: expectedRemainingPercentByEvenPace(quota.quota.fiveHour),
        sevenDayLabel: quotaLabels.sevenDay,
        sevenDayAvailability: quota.quota.sevenDay.availability,
        sevenDayRemainingPercent: quota.quota.sevenDay.remainingPercent,
        sevenDayExpectedRemainingPercent: expectedRemainingPercentByEvenPace(quota.quota.sevenDay),
      };
    },
    [quota, quotaLabels, rawSnapshot],
  );

  return {
    snapshot,
    rawSnapshot,
    quota,
    quotaLabels,
    runningThreads,
  };
}
