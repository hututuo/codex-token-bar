import { useCallback, useEffect, useRef, useState } from "react";
import { readAccountQuota } from "../api/client";
import { emptyAccountQuotaBundle } from "../api/fallback";
import type { AccountQuotaBundle } from "../types/dashboard";
import { nextQuotaResetRefreshDelayMs } from "../utils/quotaRefresh";
import { useWakeRefresh } from "../utils/useWakeRefresh";

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
  const mounted = useRef(true);

  useEffect(() => {
    return () => {
      mounted.current = false;
    };
  }, []);

  const refreshQuota = useCallback(async (forceRefresh = false) => {
    if (!active || !enabled || inFlight.current) {
      return;
    }

    inFlight.current = true;
    try {
      const next = await readAccountQuota(forceRefresh);
      if (mounted.current && next !== null) {
        setQuota(next);
      }
    } finally {
      inFlight.current = false;
    }
  }, [active, enabled]);

  useEffect(() => {
    if (!active || !enabled) {
      return;
    }

    const firstTimer = window.setTimeout(() => {
      void refreshQuota();
    }, Math.max(0, initialDelayMs));
    const interval = window.setInterval(() => {
      void refreshQuota();
    }, intervalMs);

    return () => {
      window.clearTimeout(firstTimer);
      window.clearInterval(interval);
    };
  }, [active, enabled, initialDelayMs, intervalMs, refreshQuota]);

  useEffect(() => {
    if (!active || !enabled) {
      return;
    }

    const delayMs = nextQuotaResetRefreshDelayMs(quota.quota);
    if (delayMs === null) {
      return;
    }

    const timer = window.setTimeout(() => {
      void refreshQuota(true);
    }, delayMs);

    return () => {
      window.clearTimeout(timer);
    };
  }, [
    active,
    enabled,
    quota.quota.fiveHour.resetsAtUnix,
    quota.quota.sevenDay.resetsAtUnix,
    refreshQuota,
  ]);

  useWakeRefresh({
    active: active && enabled,
    onWake: () => {
      void refreshQuota(true);
    },
  });

  return quota;
}
