import { useEffect, useRef } from "react";
import type { DashboardDataSource } from "../data/dashboardDataSource";
import type { AccountQuotaBundle, CodexHomeSourceToken } from "../types/dashboard";
import type { ResetCreditBundle } from "../types/quota";
import { persistentRefreshDelayMs } from "../utils/persistentRefreshBackoff";

interface DeferredQuotaLoadOptions {
  active: boolean;
  dashboardReady: boolean;
  loading: boolean;
  generation: number;
  forceQuotaRefresh: boolean;
  sourceToken: CodexHomeSourceToken | null;
  source: Pick<DashboardDataSource, "readAccountQuota" | "readAccountResetCredits">;
  onQuota: (quota: AccountQuotaBundle) => void;
  onResetCredits: (reset: ResetCreditBundle) => void;
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
  onResetCredits,
  onForceQuotaRefreshConsumed,
  onLoadEnd,
  onLoadStart,
}: DeferredQuotaLoadOptions) {
  const quotaRequestKey = useRef<string | null>(null);
  const resetRequestKey = useRef<string | null>(null);
  const quotaFailureCount = useRef(0);
  const resetFailureCount = useRef(0);
  const forceQuotaRefreshRef = useRef(forceQuotaRefresh);
  forceQuotaRefreshRef.current = forceQuotaRefresh;
  const sourceKey = sourceToken === null
    ? null
    : [
        sourceToken.canonicalHomeKey,
        sourceToken.physicalHomeKey,
        sourceToken.transitionGeneration,
      ].join("\u0000");

  useEffect(() => {
    quotaFailureCount.current = 0;
    resetFailureCount.current = 0;
    quotaRequestKey.current = null;
    resetRequestKey.current = null;
  }, [sourceKey]);

  useEffect(() => {
    const requestKey = sourceKey === null ? null : `${sourceKey}\u0000${generation}`;
    if (
      !active
      || !dashboardReady
      || loading
      || sourceToken === null
      || requestKey === null
      || quotaRequestKey.current === requestKey
    ) {
      return;
    }

    let cancelled = false;
    let retryTimer: number | null = null;
    const isFirstQuotaLoad = quotaRequestKey.current === null;
    quotaRequestKey.current = requestKey;
    const shouldForceRefresh = forceQuotaRefreshRef.current;
    const requestSourceToken = sourceToken;
    let forceConsumed = false;

    async function loadQuota(forceRefresh: boolean) {
      onLoadStart?.();
      let succeeded = false;
      try {
        const quota = await source.readAccountQuota(requestSourceToken, forceRefresh);
        if (!cancelled && quota !== null) {
          onQuota(quota);
          succeeded = !quota.diagnostics.some((diagnostic) => (
            diagnostic.source === "account_quota"
          ));
        }
      } catch {
        succeeded = false;
      } finally {
        if (!forceConsumed && shouldForceRefresh && !cancelled) {
          forceConsumed = true;
          onForceQuotaRefreshConsumed();
        }
        onLoadEnd?.();
      }

      if (cancelled) {
        return;
      }
      if (succeeded) {
        quotaFailureCount.current = 0;
        return;
      }
      const delayMs = persistentRefreshDelayMs(quotaFailureCount.current);
      quotaFailureCount.current += 1;
      retryTimer = window.setTimeout(() => {
        void loadQuota(true);
      }, delayMs);
    }

    const firstTimer = window.setTimeout(() => {
      void loadQuota(shouldForceRefresh);
    }, shouldForceRefresh || !isFirstQuotaLoad ? 0 : 5_000);

    return () => {
      cancelled = true;
      window.clearTimeout(firstTimer);
      if (retryTimer !== null) {
        window.clearTimeout(retryTimer);
      }
    };
  }, [
    active,
    dashboardReady,
    generation,
    loading,
    onForceQuotaRefreshConsumed,
    onLoadEnd,
    onLoadStart,
    onQuota,
    source,
    sourceKey,
    sourceToken,
  ]);

  useEffect(() => {
    const requestKey = sourceKey === null ? null : `${sourceKey}\u0000${generation}`;
    if (
      !active
      || !dashboardReady
      || loading
      || sourceToken === null
      || requestKey === null
      || resetRequestKey.current === requestKey
    ) {
      return;
    }

    let cancelled = false;
    let retryTimer: number | null = null;
    const isFirstResetLoad = resetRequestKey.current === null;
    resetRequestKey.current = requestKey;
    const requestSourceToken = sourceToken;
    const shouldForceResetRefresh = forceQuotaRefreshRef.current;

    async function loadResetCredits(forceRefresh: boolean) {
      let reset: ResetCreditBundle | null = null;
      try {
        reset = await source.readAccountResetCredits(requestSourceToken, forceRefresh);
      } catch {
        reset = null;
      }
      if (cancelled) {
        return;
      }
      if (reset !== null) {
        onResetCredits(reset);
      }
      if (reset?.successful === true) {
        resetFailureCount.current = 0;
        return;
      }
      const delayMs = persistentRefreshDelayMs(resetFailureCount.current);
      resetFailureCount.current += 1;
      retryTimer = window.setTimeout(() => {
        void loadResetCredits(true);
      }, delayMs);
    }

    const firstTimer = window.setTimeout(() => {
      void loadResetCredits(shouldForceResetRefresh);
    }, shouldForceResetRefresh || !isFirstResetLoad ? 0 : 5_000);

    return () => {
      cancelled = true;
      window.clearTimeout(firstTimer);
      if (retryTimer !== null) {
        window.clearTimeout(retryTimer);
      }
    };
  }, [
    active,
    dashboardReady,
    generation,
    loading,
    onResetCredits,
    source,
    sourceKey,
    sourceToken,
  ]);
}
