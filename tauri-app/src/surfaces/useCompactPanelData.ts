import { useEffect, useMemo, useState } from "react";
import { readAccountQuota, readFloatingPanelSnapshot } from "../api/client";
import { emptyAccountQuotaBundle, emptyFloatingPanelSnapshot } from "../api/fallback";
import type { AccountQuotaBundle, FloatingPanelSnapshot } from "../types/dashboard";
import { compactQuotaLabel } from "../utils/quota";

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

  const [rawSnapshot, setRawSnapshot] = useState<FloatingPanelSnapshot>(emptyFloatingPanelSnapshot);
  const [quota, setQuota] = useState<AccountQuotaBundle>(() => emptyAccountQuotaBundle());

  useEffect(() => {
    if (!active) {
      return;
    }

    let cancelled = false;
    let inFlight = false;

    async function refreshSnapshot() {
      if (inFlight) {
        return;
      }

      inFlight = true;
      try {
        const next = await readFloatingPanelSnapshot();
        if (!cancelled) {
          setRawSnapshot(next);
        }
      } finally {
        inFlight = false;
      }
    }

    void refreshSnapshot();
    const interval = window.setInterval(() => {
      void refreshSnapshot();
    }, snapshotIntervalMs);

    return () => {
      cancelled = true;
      window.clearInterval(interval);
    };
  }, [active, snapshotIntervalMs]);

  useEffect(() => {
    if (!active || !quotaEnabled) {
      return;
    }

    let cancelled = false;
    let inFlight = false;

    async function refreshQuota() {
      if (inFlight) {
        return;
      }

      inFlight = true;
      try {
        const next = await readAccountQuota();
        if (!cancelled && next !== null) {
          setQuota(next);
        }
      } finally {
        inFlight = false;
      }
    }

    const firstTimer = window.setTimeout(() => {
      void refreshQuota();
    }, Math.max(0, quotaInitialDelayMs));
    const interval = window.setInterval(() => {
      void refreshQuota();
    }, quotaIntervalMs);

    return () => {
      cancelled = true;
      window.clearTimeout(firstTimer);
      window.clearInterval(interval);
    };
  }, [active, quotaEnabled, quotaInitialDelayMs, quotaIntervalMs]);

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
      sevenDayLabel: quotaLabels.sevenDay,
    }),
    [quotaLabels, rawSnapshot],
  );

  return {
    snapshot,
    rawSnapshot,
    quota,
    quotaLabels,
  };
}
