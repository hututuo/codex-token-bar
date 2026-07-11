import { useEffect, useRef } from "react";
import type { DashboardDataSource } from "../data/dashboardDataSource";
import type { AccountQuotaBundle, CodexHomeSourceToken } from "../types/dashboard";

interface DeferredQuotaLoadOptions {
  active: boolean;
  dashboardReady: boolean;
  loading: boolean;
  generation: number;
  forceQuotaRefresh: boolean;
  sourceToken: CodexHomeSourceToken | null;
  source: Pick<DashboardDataSource, "readAccountQuota">;
  onQuota: (quota: AccountQuotaBundle) => void;
  onForceQuotaRefreshConsumed: () => void;
  onLoadEnd?: () => void;
  onLoadStart?: () => void;
}

export function useDeferredQuotaLoad({
  active,
  dashboardReady,
  loading,
  generation,
  forceQuotaRefresh,
  sourceToken,
  source,
  onQuota,
  onForceQuotaRefreshConsumed,
  onLoadEnd,
  onLoadStart,
}: DeferredQuotaLoadOptions) {
  const quotaGeneration = useRef<number | null>(null);

  useEffect(() => {
    if (
      !active
      || !dashboardReady
      || loading
      || sourceToken === null
      || quotaGeneration.current === generation
    ) {
      return;
    }

    let cancelled = false;
    const isFirstQuotaLoad = quotaGeneration.current === null;
    quotaGeneration.current = generation;
    const shouldForceRefresh = forceQuotaRefresh;
    const requestSourceToken = sourceToken;
    const delayMs = shouldForceRefresh || !isFirstQuotaLoad ? 0 : 5_000;

    async function loadQuota() {
      onLoadStart?.();
      try {
        const quota = await source.readAccountQuota(requestSourceToken, shouldForceRefresh);
        if (!cancelled && quota !== null) {
          onQuota(quota);
        }
      } finally {
        if (shouldForceRefresh && !cancelled) {
          onForceQuotaRefreshConsumed();
        }
        onLoadEnd?.();
      }
    }

    const timer = window.setTimeout(() => {
      void loadQuota();
    }, delayMs);

    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
  }, [
    active,
    dashboardReady,
    forceQuotaRefresh,
    generation,
    loading,
    onForceQuotaRefreshConsumed,
    onLoadEnd,
    onLoadStart,
    onQuota,
    source,
    sourceToken,
  ]);
}
