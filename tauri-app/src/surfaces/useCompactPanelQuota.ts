import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { readAccountQuota, readAccountResetCredits } from "../api/client";
import { emptyAccountQuotaBundle } from "../api/fallback";
import { desktopPlatform } from "../platform/desktop";
import type {
  AccountQuotaChangedPayload,
  AccountResetCreditsChangedPayload,
} from "../platform/desktopEvents";
import {
  replaceAccountQuotaDiagnostics,
  replaceAccountQuotaWarnings,
  replaceResetCreditDiagnostics,
  replaceResetCreditWarnings,
} from "../state/dashboardWarnings";
import type { AccountQuotaBundle, CodexHomeSourceToken } from "../types/dashboard";
import type { ResetCreditBundle } from "../types/quota";
import {
  MAX_QUOTA_REFRESH_DELAY_MS,
  persistentRefreshDelayMs,
} from "../utils/persistentRefreshBackoff";
import { nextQuotaResetRefreshDelayMs } from "../utils/quotaRefresh";
import { useWakeRefresh } from "../utils/useWakeRefresh";
import { codexHomeSourceTokenKey } from "./useCompactPanelSource";

interface CompactPanelQuotaOptions {
  active: boolean;
  enabled: boolean;
  followDashboardUpdates?: boolean;
  initialDelayMs: number;
  intervalMs: number;
  sourceToken: CodexHomeSourceToken | null;
}

type QuotaReader = (
  forceRefresh: boolean,
  sourceToken: CodexHomeSourceToken,
) => ReturnType<typeof readAccountQuota>;

type ResetCreditReader = (
  forceRefresh: boolean,
  sourceToken: CodexHomeSourceToken,
) => ReturnType<typeof readAccountResetCredits>;

interface DashboardQuotaSubscriptions {
  onQuota: (handler: (payload: AccountQuotaChangedPayload) => void) => Promise<() => void>;
  onResetCredits: (
    handler: (payload: AccountResetCreditsChangedPayload) => void,
  ) => Promise<() => void>;
}

const defaultQuotaReader: QuotaReader = (forceRefresh, sourceToken) => (
  readAccountQuota(sourceToken, forceRefresh)
);
const defaultResetCreditReader: ResetCreditReader = (forceRefresh, sourceToken) => (
  readAccountResetCredits(sourceToken, forceRefresh)
);
const defaultDashboardSubscriptions: DashboardQuotaSubscriptions = {
  onQuota: desktopPlatform.onAccountQuotaChanged,
  onResetCredits: desktopPlatform.onAccountResetCreditsChanged,
};

export function useCompactPanelQuota({
  active,
  enabled,
  followDashboardUpdates = false,
  initialDelayMs,
  intervalMs,
  sourceToken,
}: CompactPanelQuotaOptions,
readQuota: QuotaReader = defaultQuotaReader,
readResetCredits: ResetCreditReader = defaultResetCreditReader,
dashboardSubscriptions: DashboardQuotaSubscriptions = defaultDashboardSubscriptions): AccountQuotaBundle {
  const sourceKey = codexHomeSourceTokenKey(sourceToken);
  const [quota, setQuota] = useState<AccountQuotaBundle>(() => emptyAccountQuotaBundle());
  const quotaInFlightGeneration = useRef<number | null>(null);
  const resetInFlightGeneration = useRef<number | null>(null);
  const quotaFailureCount = useRef(0);
  const resetFailureCount = useRef(0);
  const quotaRetryTimer = useRef<number | null>(null);
  const resetRetryTimer = useRef<number | null>(null);
  const lifecycleRef = useRef({ active, enabled, generation: 0, sourceKey });
  const mounted = useRef(true);
  const effectiveIntervalMs = Math.min(
    MAX_QUOTA_REFRESH_DELAY_MS,
    Math.max(1_000, intervalMs),
  );

  useLayoutEffect(() => {
    const current = lifecycleRef.current;
    const sourceChanged = current.sourceKey !== sourceKey;
    const lifecycleChanged = current.active !== active || current.enabled !== enabled || sourceChanged;
    lifecycleRef.current = {
      active,
      enabled,
      generation: lifecycleChanged ? current.generation + 1 : current.generation,
      sourceKey,
    };
    if (sourceChanged) {
      clearRetryTimer(quotaRetryTimer);
      clearRetryTimer(resetRetryTimer);
      quotaFailureCount.current = 0;
      resetFailureCount.current = 0;
      setQuota(emptyAccountQuotaBundle());
    }
  }, [active, enabled, sourceKey]);

  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
      clearRetryTimer(quotaRetryTimer);
      clearRetryTimer(resetRetryTimer);
    };
  }, []);

  useEffect(() => {
    if (!followDashboardUpdates || !active || !enabled || sourceKey === null) {
      return;
    }
    let disposed = false;
    let unlistenQuota: (() => void) | null = null;
    let unlistenResetCredits: (() => void) | null = null;

    void dashboardSubscriptions.onQuota((payload) => {
      if (disposed || codexHomeSourceTokenKey(payload.sourceToken) !== sourceKey) {
        return;
      }
      setQuota((previous) => mergeCompactQuota(previous, payload.quota));
    }).then((unlisten) => {
      if (disposed) unlisten();
      else unlistenQuota = unlisten;
    });
    void dashboardSubscriptions.onResetCredits((payload) => {
      if (disposed || codexHomeSourceTokenKey(payload.sourceToken) !== sourceKey) {
        return;
      }
      setQuota((previous) => mergeCompactResetCredits(previous, payload.resetCredits));
    }).then((unlisten) => {
      if (disposed) unlisten();
      else unlistenResetCredits = unlisten;
    });

    return () => {
      disposed = true;
      unlistenQuota?.();
      unlistenResetCredits?.();
    };
  }, [active, dashboardSubscriptions, enabled, followDashboardUpdates, sourceKey]);

  const refreshQuota = useCallback(async function refreshQuota(forceRefresh = false) {
    const lifecycle = lifecycleRef.current;
    if (
      !active
      || !enabled
      || followDashboardUpdates
      || sourceToken === null
      || !lifecycle.active
      || !lifecycle.enabled
      || lifecycle.sourceKey === null
      || quotaInFlightGeneration.current === lifecycle.generation
    ) {
      return;
    }

    const requestGeneration = lifecycle.generation;
    const requestSourceKey = lifecycle.sourceKey;
    quotaInFlightGeneration.current = requestGeneration;
    let next: AccountQuotaBundle | null = null;
    try {
      next = await readQuota(forceRefresh, sourceToken);
    } catch {
      next = null;
    } finally {
      if (quotaInFlightGeneration.current === requestGeneration) {
        quotaInFlightGeneration.current = null;
      }
    }

    const current = lifecycleRef.current;
    if (
      !mounted.current
      || !current.active
      || !current.enabled
      || current.generation !== requestGeneration
      || current.sourceKey !== requestSourceKey
    ) {
      return;
    }

    const succeeded = next !== null && !next.diagnostics.some((diagnostic) => (
      diagnostic.source === "account_quota"
    ));
    if (next !== null) {
      setQuota((previous) => mergeCompactQuota(previous, next));
    }
    if (succeeded) {
      quotaFailureCount.current = 0;
      clearRetryTimer(quotaRetryTimer);
      return;
    }

    const delayMs = persistentRefreshDelayMs(quotaFailureCount.current);
    quotaFailureCount.current += 1;
    clearRetryTimer(quotaRetryTimer);
    quotaRetryTimer.current = window.setTimeout(() => {
      quotaRetryTimer.current = null;
      void refreshQuota(true);
    }, delayMs);
  }, [active, enabled, followDashboardUpdates, readQuota, sourceToken]);

  const refreshResetCredits = useCallback(async function refreshResetCredits(forceRefresh = false) {
    const lifecycle = lifecycleRef.current;
    if (
      !active
      || !enabled
      || followDashboardUpdates
      || sourceToken === null
      || !lifecycle.active
      || !lifecycle.enabled
      || lifecycle.sourceKey === null
      || resetInFlightGeneration.current === lifecycle.generation
    ) {
      return;
    }

    const requestGeneration = lifecycle.generation;
    const requestSourceKey = lifecycle.sourceKey;
    resetInFlightGeneration.current = requestGeneration;
    let next: ResetCreditBundle | null = null;
    try {
      next = await readResetCredits(forceRefresh, sourceToken);
    } catch {
      next = null;
    } finally {
      if (resetInFlightGeneration.current === requestGeneration) {
        resetInFlightGeneration.current = null;
      }
    }

    const current = lifecycleRef.current;
    if (
      !mounted.current
      || !current.active
      || !current.enabled
      || current.generation !== requestGeneration
      || current.sourceKey !== requestSourceKey
    ) {
      return;
    }

    if (next !== null) {
      setQuota((previous) => mergeCompactResetCredits(previous, next));
    }
    if (next?.successful === true) {
      resetFailureCount.current = 0;
      clearRetryTimer(resetRetryTimer);
      return;
    }

    const delayMs = persistentRefreshDelayMs(resetFailureCount.current);
    resetFailureCount.current += 1;
    clearRetryTimer(resetRetryTimer);
    resetRetryTimer.current = window.setTimeout(() => {
      resetRetryTimer.current = null;
      void refreshResetCredits(true);
    }, delayMs);
  }, [active, enabled, followDashboardUpdates, readResetCredits, sourceToken]);

  useEffect(() => {
    if (!active || !enabled || followDashboardUpdates) {
      clearRetryTimer(quotaRetryTimer);
      clearRetryTimer(resetRetryTimer);
      return;
    }

    const firstTimer = window.setTimeout(() => {
      void refreshQuota();
      void refreshResetCredits();
    }, Math.max(0, initialDelayMs));
    const interval = window.setInterval(() => {
      void refreshQuota();
      void refreshResetCredits();
    }, effectiveIntervalMs);

    return () => {
      window.clearTimeout(firstTimer);
      window.clearInterval(interval);
    };
  }, [
    active,
    effectiveIntervalMs,
    enabled,
    followDashboardUpdates,
    initialDelayMs,
    refreshQuota,
    refreshResetCredits,
  ]);

  useEffect(() => {
    if (!active || !enabled || followDashboardUpdates) {
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
    followDashboardUpdates,
    quota.quota.fiveHour.resetsAtUnix,
    quota.quota.sevenDay.resetsAtUnix,
    refreshQuota,
  ]);

  useWakeRefresh({
    active: active && enabled && !followDashboardUpdates,
    onWake: () => {
      void refreshQuota(true);
      void refreshResetCredits(true);
    },
  });

  return quota;
}

function mergeCompactQuota(
  previous: AccountQuotaBundle,
  latest: AccountQuotaBundle,
): AccountQuotaBundle {
  return {
    ...latest,
    quota: {
      ...latest.quota,
      resetCredit: previous.quota.resetCredit,
    },
    warnings: replaceAccountQuotaWarnings(previous.warnings, latest.warnings),
    diagnostics: replaceAccountQuotaDiagnostics(previous.diagnostics, latest.diagnostics),
  };
}

function mergeCompactResetCredits(
  previous: AccountQuotaBundle,
  latest: ResetCreditBundle,
): AccountQuotaBundle {
  const resetCredit = latest.successful
    ? { ...latest.resetCredit, updatedAt: latest.updatedAt }
    : {
        ...previous.quota.resetCredit,
        status: latest.resetCredit.status,
        updatedAt: previous.quota.resetCredit.updatedAt ?? null,
      };
  return {
    ...previous,
    quota: {
      ...previous.quota,
      resetCredit,
    },
    warnings: replaceResetCreditWarnings(previous.warnings, latest.warnings),
    diagnostics: replaceResetCreditDiagnostics(previous.diagnostics, latest.diagnostics),
  };
}

function clearRetryTimer(timer: { current: number | null }) {
  if (timer.current !== null) {
    window.clearTimeout(timer.current);
    timer.current = null;
  }
}
