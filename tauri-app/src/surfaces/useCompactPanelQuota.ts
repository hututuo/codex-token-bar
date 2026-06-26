import { useEffect, useRef, useState } from "react";
import { readAccountQuota } from "../api/client";
import { emptyAccountQuotaBundle } from "../api/fallback";
import type { AccountQuotaBundle } from "../types/dashboard";
import { nextQuotaResetRefreshDelayMs } from "../utils/quotaRefresh";

interface CompactPanelQuotaOptions {
  active: boolean;
  enabled: boolean;
  initialDelayMs: number;
  intervalMs: number;
}

export function useCompactPanelQuota({
  active,
  enabled,
  initialDelayMs,
  intervalMs,
}: CompactPanelQuotaOptions): AccountQuotaBundle {
  const [quota, setQuota] = useState<AccountQuotaBundle>(() => emptyAccountQuotaBundle());
  const inFlight = useRef(false);

  useEffect(() => {
    if (!active || !enabled) {
      return;
    }

    let cancelled = false;

    async function refreshQuota(forceRefresh = false) {
      if (inFlight.current) {
        return;
      }

      inFlight.current = true;
      try {
        const next = await readAccountQuota(forceRefresh);
        if (!cancelled && next !== null) {
          setQuota(next);
        }
      } finally {
        inFlight.current = false;
      }
    }

    const firstTimer = window.setTimeout(() => {
      void refreshQuota();
    }, Math.max(0, initialDelayMs));
    const interval = window.setInterval(() => {
      void refreshQuota();
    }, intervalMs);

    return () => {
      cancelled = true;
      window.clearTimeout(firstTimer);
      window.clearInterval(interval);
    };
  }, [active, enabled, initialDelayMs, intervalMs]);

  useEffect(() => {
    if (!active || !enabled) {
      return;
    }

    const delayMs = nextQuotaResetRefreshDelayMs(quota.quota);
    if (delayMs === null) {
      return;
    }

    let cancelled = false;
    const timer = window.setTimeout(async () => {
      if (inFlight.current) {
        return;
      }

      inFlight.current = true;
      try {
        const next = await readAccountQuota(true);
        if (!cancelled && next !== null) {
          setQuota(next);
        }
      } finally {
        inFlight.current = false;
      }
    }, delayMs);

    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
  }, [
    active,
    enabled,
    quota.quota.fiveHour.resetsAtUnix,
    quota.quota.sevenDay.resetsAtUnix,
  ]);

  return quota;
}
