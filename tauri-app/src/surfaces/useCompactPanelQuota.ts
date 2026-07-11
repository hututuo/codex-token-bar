import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { readAccountQuota } from "../api/client";
import { emptyAccountQuotaBundle } from "../api/fallback";
import type { AccountQuotaBundle, CodexHomeSourceToken } from "../types/dashboard";
import { nextQuotaResetRefreshDelayMs } from "../utils/quotaRefresh";
import { useWakeRefresh } from "../utils/useWakeRefresh";
import { codexHomeSourceTokenKey } from "./useCompactPanelSource";

interface CompactPanelQuotaOptions {
  active: boolean;
  enabled: boolean;
  initialDelayMs: number;
  intervalMs: number;
  sourceToken: CodexHomeSourceToken | null;
}

type QuotaReader = (
  forceRefresh: boolean,
  sourceToken: CodexHomeSourceToken,
) => ReturnType<typeof readAccountQuota>;

const defaultQuotaReader: QuotaReader = (forceRefresh) => readAccountQuota(forceRefresh);

export function useCompactPanelQuota({
  active,
  enabled,
  initialDelayMs,
  intervalMs,
  sourceToken,
}: CompactPanelQuotaOptions, readQuota: QuotaReader = defaultQuotaReader): AccountQuotaBundle {
  const sourceKey = codexHomeSourceTokenKey(sourceToken);
  const [quota, setQuota] = useState<AccountQuotaBundle>(() => emptyAccountQuotaBundle());
  const inFlightGeneration = useRef<number | null>(null);
  const lifecycleRef = useRef({ active, enabled, generation: 0, sourceKey });
  const mounted = useRef(true);

  useLayoutEffect(() => {
    const current = lifecycleRef.current;
    const sourceChanged = current.sourceKey !== sourceKey;
    lifecycleRef.current = {
      active,
      enabled,
      generation: current.active === active && current.enabled === enabled && !sourceChanged
        ? current.generation
        : current.generation + 1,
      sourceKey,
    };
    if (sourceChanged) {
      setQuota(emptyAccountQuotaBundle());
    }
  }, [active, enabled, sourceKey]);

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
      || sourceToken === null
      || !lifecycle.active
      || !lifecycle.enabled
      || lifecycle.sourceKey === null
      || inFlightGeneration.current === lifecycle.generation
    ) {
      return;
    }

    const requestGeneration = lifecycle.generation;
    const requestSourceKey = lifecycle.sourceKey;
    inFlightGeneration.current = requestGeneration;
    try {
      const next = await readQuota(forceRefresh, sourceToken);
      const current = lifecycleRef.current;
      if (
        mounted.current
        && current.active
        && current.enabled
        && current.generation === requestGeneration
        && current.sourceKey === requestSourceKey
        && next !== null
      ) {
        setQuota(next);
      }
    } finally {
      if (inFlightGeneration.current === requestGeneration) {
        inFlightGeneration.current = null;
      }
    }
  }, [active, enabled, readQuota, sourceToken]);

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
