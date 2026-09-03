import { useCallback, useEffect, useRef } from "react";
import type { DashboardDataSource } from "../data/dashboardDataSource";
import type { AccountQuotaBundle, CodexHomeSourceToken } from "../types/dashboard";
import type { ResetCreditBundle } from "../types/quota";
import {
  persistentRefreshDelayMs,
  quotaRefreshDelayMs,
  quotaRefreshFailureNoticeDelayMs,
} from "../utils/persistentRefreshBackoff";

// The 7d model-cost row needs the authoritative reset boundary. Starting the
// first quota read after a fixed 5s delay made an otherwise ready precise
// dashboard show "本7d模型明细待读取" on every cold start. Keep the read
// asynchronous (it does not block the first dashboard paint), but start it as
// soon as the dashboard source is ready. Retry/backoff remains unchanged.
const FIRST_QUOTA_LOAD_DELAY_MS = 0;

interface DeferredQuotaLoadOptions {
  active: boolean;
  dashboardReady: boolean;
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
  const quotaFailureStartedAt = useRef<number | null>(null);
  const quotaFailureNoticeTimer = useRef<number | null>(null);
  const latestFailedQuota = useRef<AccountQuotaBundle | null>(null);
  const quotaFailureNoticePublished = useRef(false);
  const quotaNoticeMounted = useRef(true);
  const onQuotaRef = useRef(onQuota);
  const forceQuotaRefreshRef = useRef(forceQuotaRefresh);
  onQuotaRef.current = onQuota;
  forceQuotaRefreshRef.current = forceQuotaRefresh;
  const sourceKey = sourceToken === null
    ? null
    : [
        sourceToken.canonicalHomeKey,
        sourceToken.physicalHomeKey,
        sourceToken.transitionGeneration,
      ].join("\u0000");

  const quotaLifecycleRef = useRef({ active, dashboardReady, sourceKey });
  quotaLifecycleRef.current = { active, dashboardReady, sourceKey };

  const scheduleQuotaFailureNotice = useCallback(() => {
    if (
      quotaFailureNoticeTimer.current !== null
      || quotaFailureNoticePublished.current
      || quotaFailureStartedAt.current === null
      || latestFailedQuota.current === null
    ) {
      return;
    }
    const expectedSourceKey = sourceKey;
    const delayMs = quotaRefreshFailureNoticeDelayMs(quotaFailureStartedAt.current);
    quotaFailureNoticeTimer.current = window.setTimeout(() => {
      quotaFailureNoticeTimer.current = null;
      const lifecycle = quotaLifecycleRef.current;
      const startedAt = quotaFailureStartedAt.current;
      const latest = latestFailedQuota.current;
      if (
        !quotaNoticeMounted.current
        || !lifecycle.active
        || !lifecycle.dashboardReady
        || lifecycle.sourceKey !== expectedSourceKey
        || startedAt === null
        || latest === null
      ) {
        return;
      }
      const remainingMs = quotaRefreshFailureNoticeDelayMs(startedAt);
      if (remainingMs > 0) {
        scheduleQuotaFailureNotice();
        return;
      }
      quotaFailureNoticePublished.current = true;
      onQuotaRef.current(latest);
    }, delayMs);
  }, [sourceKey]);

  useEffect(() => {
    quotaFailureCount.current = 0;
    resetFailureCount.current = 0;
    quotaRequestKey.current = null;
    resetRequestKey.current = null;
    quotaFailureStartedAt.current = null;
    latestFailedQuota.current = null;
    quotaFailureNoticePublished.current = false;
    if (quotaFailureNoticeTimer.current !== null) {
      window.clearTimeout(quotaFailureNoticeTimer.current);
      quotaFailureNoticeTimer.current = null;
    }
  }, [sourceKey]);

  useEffect(() => {
    quotaNoticeMounted.current = true;
    return () => {
      quotaNoticeMounted.current = false;
      if (quotaFailureNoticeTimer.current !== null) {
        window.clearTimeout(quotaFailureNoticeTimer.current);
        quotaFailureNoticeTimer.current = null;
      }
    };
  }, []);

  useEffect(() => {
    if (!active || !dashboardReady || sourceKey === null) {
      if (quotaFailureNoticeTimer.current !== null) {
        window.clearTimeout(quotaFailureNoticeTimer.current);
        quotaFailureNoticeTimer.current = null;
      }
      return;
    }
    scheduleQuotaFailureNotice();
  }, [active, dashboardReady, scheduleQuotaFailureNotice, sourceKey]);

  useEffect(() => {
    const requestKey = sourceKey === null ? null : `${sourceKey}\u0000${generation}`;
    if (
      !active
      || !dashboardReady
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
          succeeded = !quota.diagnostics.some((diagnostic) => (
            diagnostic.source === "account_quota"
          ));
          if (succeeded) {
            quotaFailureStartedAt.current = null;
            latestFailedQuota.current = null;
            quotaFailureNoticePublished.current = false;
            if (quotaFailureNoticeTimer.current !== null) {
              window.clearTimeout(quotaFailureNoticeTimer.current);
              quotaFailureNoticeTimer.current = null;
            }
            onQuota(quota);
          } else {
            latestFailedQuota.current = quota;
            quotaFailureStartedAt.current ??= Date.now();
            const noticeDue = quotaRefreshFailureNoticeDelayMs(quotaFailureStartedAt.current) <= 0;
            if (quotaFailureNoticePublished.current || noticeDue) {
              quotaFailureNoticePublished.current = true;
              if (quotaFailureNoticeTimer.current !== null) {
                window.clearTimeout(quotaFailureNoticeTimer.current);
                quotaFailureNoticeTimer.current = null;
              }
              onQuota(quota);
            } else {
              scheduleQuotaFailureNotice();
            }
          }
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
      const delayMs = quotaRefreshDelayMs(quotaFailureCount.current);
      quotaFailureCount.current += 1;
      retryTimer = window.setTimeout(() => {
        void loadQuota(true);
      }, delayMs);
    }

    const firstTimer = window.setTimeout(() => {
      void loadQuota(shouldForceRefresh);
    }, shouldForceRefresh || !isFirstQuotaLoad ? 0 : FIRST_QUOTA_LOAD_DELAY_MS);

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
    onForceQuotaRefreshConsumed,
    onLoadEnd,
    onLoadStart,
    onQuota,
    scheduleQuotaFailureNotice,
    source,
    sourceKey,
    sourceToken,
  ]);

  useEffect(() => {
    const requestKey = sourceKey === null ? null : `${sourceKey}\u0000${generation}`;
    if (
      !active
      || !dashboardReady
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
    onResetCredits,
    source,
    sourceKey,
    sourceToken,
  ]);
}
