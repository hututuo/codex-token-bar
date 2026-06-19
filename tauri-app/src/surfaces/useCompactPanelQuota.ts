import { useEffect, useState } from "react";
import { readAccountQuota } from "../api/client";
import { emptyAccountQuotaBundle } from "../api/fallback";
import type { AccountQuotaBundle } from "../types/dashboard";

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

  useEffect(() => {
    if (!active || !enabled) {
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

  return quota;
}
