import { useEffect, useMemo, useRef, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import {
  getCodexHome,
  hideFloatingWindow,
  readAccountQuota,
  readDashboardSnapshot,
  readLiveRateSnapshot,
  readPreciseDashboardSnapshot,
  scanProviderRepair,
  showFloatingWindow,
} from "../api/client";
import { FloatingWindowApp } from "../floating/FloatingWindowApp";
import { DashboardPage } from "../pages/DashboardPage";
import type {
  AccountQuotaBundle,
  CodexHomeStatus,
  DashboardSnapshot,
  LiveRateSnapshot,
  ProviderRepairSnapshot,
  RecentUsagePoint,
} from "../types/dashboard";
import { compactQuotaLabel } from "../utils/quota";

interface AppState {
  codexHome: CodexHomeStatus | null;
  dashboard: DashboardSnapshot | null;
  liveRate: LiveRateSnapshot | null;
  repair: ProviderRepairSnapshot | null;
  loading: boolean;
}

const initialState: AppState = {
  codexHome: null,
  dashboard: null,
  liveRate: null,
  repair: null,
  loading: true,
};

export function App() {
  const surface = useMemo(getSurfaceMode, []);
  if (surface === "floating") {
    return <FloatingWindowApp />;
  }

  return <DashboardApp />;
}

function DashboardApp() {
  const [state, setState] = useState<AppState>(initialState);
  const preciseLoadStarted = useRef(false);
  const quotaLoadStarted = useRef(false);
  const liveRatePollStarted = useRef(false);
  const [floatingVisible, setFloatingVisible] = useState(true);

  useEffect(() => {
    let cancelled = false;

    async function load() {
      const [codexHome, dashboard, liveRate, repair] = await Promise.all([
        getCodexHome(),
        readDashboardSnapshot(),
        readLiveRateSnapshot(),
        scanProviderRepair(),
      ]);

      if (!cancelled) {
        setState({ codexHome, dashboard, liveRate, repair, loading: false });
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

  useEffect(() => {
    if (!("__TAURI_INTERNALS__" in window)) {
      return;
    }

    let disposed = false;
    let unlisten: (() => void) | null = null;

    void listen("floating-window-hidden", () => {
      setFloatingVisible(false);
    }).then((listener) => {
      if (disposed) {
        listener();
      } else {
        unlisten = listener;
      }
    });

    return () => {
      disposed = true;
      unlisten?.();
    };
  }, []);

  async function toggleFloatingWindow() {
    const nextVisible = !floatingVisible;
    setFloatingVisible(nextVisible);
    const confirmed = nextVisible ? await showFloatingWindow() : await hideFloatingWindow();
    setFloatingVisible(confirmed);
  }

  const readyState = useMemo(() => {
    if (
      state.codexHome === null ||
      state.dashboard === null ||
      state.liveRate === null ||
      state.repair === null
    ) {
      return null;
    }

    return {
      codexHome: state.codexHome,
      dashboard: state.dashboard,
      liveRate: state.liveRate,
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
      floatingVisible={floatingVisible}
      liveRate={readyState.liveRate}
      onToggleFloating={toggleFloatingWindow}
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
          recentUsage24h: mergeQuotaHistory(state.dashboard.recentUsage24h, quota),
        };
  return {
    ...state,
    dashboard,
  };
}

function mergeQuotaHistory(points: RecentUsagePoint[], quota: AccountQuotaBundle): RecentUsagePoint[] {
  if (quota.quotaHistory24h.length === 0) {
    return points;
  }

  return points.map((point, index) => {
    const history = quota.quotaHistory24h[index];
    if (history === undefined) {
      return point;
    }
    return {
      ...point,
      fiveHourRemainingPercent: history.fiveHourRemainingPercent,
      sevenDayRemainingPercent: history.sevenDayRemainingPercent,
    };
  });
}

function mergeLiveRate(state: AppState, liveRate: LiveRateSnapshot): AppState {
  return {
    ...state,
    liveRate,
  };
}

function getSurfaceMode(): "dashboard" | "floating" {
  if (new URLSearchParams(window.location.search).get("surface") === "floating") {
    return "floating";
  }

  if ("__TAURI_INTERNALS__" in window) {
    try {
      return getCurrentWindow().label === "floating" ? "floating" : "dashboard";
    } catch (error) {
      console.warn("Failed to read Tauri window label", error);
    }
  }

  return "dashboard";
}
