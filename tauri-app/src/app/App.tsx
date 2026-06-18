import { useEffect, useMemo, useState } from "react";
import {
  getCodexHome,
  readDashboardSnapshot,
  readFloatingPanelSnapshot,
  readLiveRateSnapshot,
  scanProviderRepair,
} from "../api/client";
import { DashboardPage } from "../pages/DashboardPage";
import type {
  CodexHomeStatus,
  DashboardSnapshot,
  FloatingPanelSnapshot,
  LiveRateSnapshot,
  ProviderRepairSnapshot,
} from "../types/dashboard";

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
