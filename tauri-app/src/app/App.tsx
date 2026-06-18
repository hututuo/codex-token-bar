import { useEffect, useMemo, useRef, useState } from "react";
import {
  getCodexHome,
  readAccountQuota,
  readDashboardSnapshot,
  readFloatingPanelSnapshot,
  readLiveRateSnapshot,
  readPreciseDashboardSnapshot,
  scanProviderRepair,
} from "../api/client";
import { DashboardPage } from "../pages/DashboardPage";
import type {
  AccountQuotaBundle,
  CodexHomeStatus,
  DashboardSnapshot,
  FloatingPanelSnapshot,
  LiveRateSnapshot,
  ProviderRepairSnapshot,
} from "../types/dashboard";
import { formatTokens } from "../utils/format";

interface AppState {
  codexHome: CodexHomeStatus | null;
  dashboard: DashboardSnapshot | null;
  liveRate: LiveRateSnapshot | null;
  floating: FloatingPanelSnapshot | null;
  repair: ProviderRepairSnapshot | null;
  loading: boolean;
}

const initialState: AppState = {
  codexHome: null,
  dashboard: null,
  liveRate: null,
  floating: null,
  repair: null,
  loading: true,
};

export function App() {
  const [state, setState] = useState<AppState>(initialState);
  const preciseLoadStarted = useRef(false);
  const quotaLoadStarted = useRef(false);
  const liveRatePollStarted = useRef(false);

  useEffect(() => {
    let cancelled = false;

    async function load() {
      const [codexHome, dashboard, liveRate, floating, repair] = await Promise.all([
        getCodexHome(),
        readDashboardSnapshot(),
        readLiveRateSnapshot(),
        readFloatingPanelSnapshot(),
        scanProviderRepair(),
      ]);

      if (!cancelled) {
        setState({ codexHome, dashboard, liveRate, floating, repair, loading: false });
      }
    }

    void load();

    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    if (state.dashboard === null || state.loading || preciseLoadStarted.current) {
      return;
    }

    let cancelled = false;
    preciseLoadStarted.current = true;

    async function loadPreciseSnapshot() {
      const precise = await readPreciseDashboardSnapshot();
      if (!cancelled) {
        setState((current) => ({
          ...current,
          dashboard:
            current.dashboard === null
              ? precise
              : {
                  ...precise,
                  account: current.dashboard.account,
                  quota: current.dashboard.quota,
                },
        }));
      }
    }

    void loadPreciseSnapshot();

    return () => {
      cancelled = true;
    };
  }, [state.dashboard, state.loading]);

  useEffect(() => {
    if (state.dashboard === null || state.loading || quotaLoadStarted.current) {
      return;
    }

    let cancelled = false;
    quotaLoadStarted.current = true;

    async function loadQuota() {
      const quota = await readAccountQuota();
      if (!cancelled) {
        setState((current) => mergeQuota(current, quota));
      }
    }

    void loadQuota();

    return () => {
      cancelled = true;
    };
  }, [state.dashboard, state.loading]);

  useEffect(() => {
    if (state.loading || liveRatePollStarted.current) {
      return;
    }

    let cancelled = false;
    liveRatePollStarted.current = true;

    async function refreshLiveRate() {
      const liveRate = await readLiveRateSnapshot();
      if (!cancelled) {
        setState((current) => mergeLiveRate(current, liveRate));
      }
    }

    void refreshLiveRate();
    const interval = window.setInterval(() => {
      void refreshLiveRate();
    }, 500);

    return () => {
      cancelled = true;
      window.clearInterval(interval);
    };
  }, [state.loading]);

  const readyState = useMemo(() => {
    if (
      state.codexHome === null ||
      state.dashboard === null ||
      state.liveRate === null ||
      state.floating === null ||
      state.repair === null
    ) {
      return null;
    }

    return {
      codexHome: state.codexHome,
      dashboard: state.dashboard,
      liveRate: state.liveRate,
      floating: state.floating,
      repair: state.repair,
    };
  }, [state]);

  if (readyState === null) {
    return (
      <main className="app-shell app-shell--loading">
        <div className="loading-mark">CX</div>
      </main>
    );
  }

  return (
    <DashboardPage
      codexHome={readyState.codexHome}
      dashboard={readyState.dashboard}
      floating={readyState.floating}
      liveRate={readyState.liveRate}
      providerRepair={readyState.repair}
      refreshing={state.loading}
    />
  );
}

function mergeQuota(state: AppState, quota: AccountQuotaBundle): AppState {
  const dashboard =
    state.dashboard === null
      ? null
      : {
          ...state.dashboard,
          account: quota.account,
          quota: quota.quota,
        };
  const floating =
    state.floating === null
      ? null
      : {
          ...state.floating,
          fiveHourLabel: compactQuotaLabel(quota.quota.fiveHour),
          sevenDayLabel: compactQuotaLabel(quota.quota.sevenDay),
        };
  return {
    ...state,
    dashboard,
    floating,
  };
}

function mergeLiveRate(state: AppState, liveRate: LiveRateSnapshot): AppState {
  const floating =
    state.floating === null
      ? null
      : {
          ...state.floating,
          tokensPerSecond: liveRate.tokensPerSecond,
          trendLabel: liveRate.tokensPerSecond > 0.05 ? "输出中" : "待输出",
          totalTokensLabel:
            state.dashboard === null
              ? state.floating.totalTokensLabel
              : `总 ${formatTokens(state.dashboard.stats.totalTokens)}`,
          todayTokensLabel: `今 ${formatTokens(liveRate.totalTokensToday)}`,
          requestsLabel: `次 ${liveRate.requestsToday}`,
        };

  return {
    ...state,
    liveRate,
    floating,
  };
}

function compactQuotaLabel(limit: AccountQuotaBundle["quota"]["fiveHour"]): string {
  const percent = Math.round(limit.remainingPercent * 100);
  return `${limit.label} ${percent}% ${limit.resetsAt}`;
}
