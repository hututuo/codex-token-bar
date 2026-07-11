import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
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

type QuotaReader = typeof readAccountQuota;

export function useCompactPanelQuota({
  active,
  enabled,
  initialDelayMs,
  intervalMs,
}: CompactPanelQuotaOptions, readQuota: QuotaReader = readAccountQuota): AccountQuotaBundle {
  const [quota, setQuota] = useState<AccountQuotaBundle>(() => emptyAccountQuotaBundle());
  const inFlightGeneration = useRef<number | null>(null);
  const lifecycleRef = useRef({ active, enabled, generation: 0 });
  const mounted = useRef(true);

  useLayoutEffect(() => {
    const current = lifecycleRef.current;
    lifecycleRef.current = {
      active,
      enabled,
      generation: current.active === active && current.enabled === enabled
        ? current.generation
        : current.generation + 1,
    };
  }, [active, enabled]);

  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);

  const refreshQuota = useCallback(async (forceRefresh = false) => {
    const lifecycle = lifecycleRef.current;
    if (
      !active
      || !enabled
      || !lifecycle.active
      || !lifecycle.enabled
      || inFlightGeneration.current === lifecycle.generation
    ) {
      return;
    }

    const requestGeneration = lifecycle.generation;
    inFlightGeneration.current = requestGeneration;
    try {
      const next = await readQuota(forceRefresh);
      const current = lifecycleRef.current;
      if (
        mounted.current
        && current.active
        && current.enabled
        && current.generation === requestGeneration
        && next !== null
      ) {
        setQuota(next);
      }
    } finally {
      if (inFlightGeneration.current === requestGeneration) {
        inFlightGeneration.current = null;
      }
    }
  }, [active, enabled, readQuota]);

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
