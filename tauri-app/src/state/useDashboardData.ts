import { useEffect, useMemo, useRef, useState } from "react";
import { dashboardDataSource, type DashboardDataSource } from "../data/dashboardDataSource";
import { desktopPlatform } from "../platform/desktop";
import type { ProviderRepairSnapshot } from "../types/dashboard";
import {
  initialDashboardState,
  mergeLiveRate,
  mergeLiveThreadOptions,
  mergePreciseDashboard,
  mergeQuota,
  pendingLiveRateSnapshot,
  pendingRepairSnapshot,
  readyDashboardState,
  type DashboardAppState,
} from "./dashboardState";

export function useDashboardData(source: DashboardDataSource = dashboardDataSource) {
  const [state, setState] = useState<DashboardAppState>(initialDashboardState);
  const preciseLoadStarted = useRef(false);
  const quotaLoadStarted = useRef(false);
  const liveThreadOptionsLoadStarted = useRef(false);
  const repairScanStarted = useRef(false);
  const [selectedLiveThreadId, setSelectedLiveThreadId] = useState("");

  useEffect(() => {
    let cancelled = false;

    async function load() {
      const nextState = await readInitialAppState(source);
      if (!cancelled) {
        setState(nextState);
      }
    }

    void load();

    return () => {
      cancelled = true;
    };
  }, [source]);

  useEffect(() => {
    if (state.dashboard === null || state.loading || preciseLoadStarted.current) {
      return;
    }

    let cancelled = false;
    preciseLoadStarted.current = true;

    async function loadPreciseSnapshot() {
      const precise = await source.readPreciseDashboardSnapshot();
      if (!cancelled) {
        setState((current) => mergePreciseDashboard(current, precise));
      }
    }

    void loadPreciseSnapshot();

    return () => {
      cancelled = true;
    };
  }, [source, state.dashboard, state.loading]);

  useEffect(() => {
    if (state.dashboard === null || state.loading || repairScanStarted.current) {
      return;
    }

    let cancelled = false;
    repairScanStarted.current = true;

    async function loadProviderRepair() {
      const repair = await source.scanProviderRepair();
      if (!cancelled) {
        setState((current) => ({ ...current, repair }));
      }
    }

    void loadProviderRepair();

    return () => {
      cancelled = true;
    };
  }, [source, state.dashboard, state.loading]);

  useEffect(() => {
    if (state.dashboard === null || state.loading || quotaLoadStarted.current) {
      return;
    }

    let cancelled = false;
    quotaLoadStarted.current = true;

    async function loadQuota() {
      const quota = await source.readAccountQuota();
      if (!cancelled) {
        setState((current) => mergeQuota(current, quota));
      }
    }

    void loadQuota();

    return () => {
      cancelled = true;
    };
  }, [source, state.dashboard, state.loading]);

  useEffect(() => {
    if (state.loading) {
      return;
    }

    let cancelled = false;
    let liveRateInFlight = false;
    let streaming = false;
    let unlisten: (() => void) | null = null;

    async function refreshLiveRate() {
      if (liveRateInFlight) {
        return;
      }

      liveRateInFlight = true;
      try {
        const liveRate = await source.readLiveRateSnapshot(selectedLiveThreadId || null);
        if (!cancelled) {
          setState((current) => mergeLiveRate(current, liveRate));
        }
      } finally {
        liveRateInFlight = false;
      }
    }

    void desktopPlatform.onLiveRateSnapshot((liveRate) => {
      if (!cancelled) {
        setState((current) => mergeLiveRate(current, liveRate));
      }
    }).then((listener) => {
      if (cancelled) {
        listener();
      } else {
        unlisten = listener;
      }
    });

    void refreshLiveRate();
    void desktopPlatform.startLiveRateStream(selectedLiveThreadId || null).then((started) => {
      if (cancelled) {
        if (started) {
          void desktopPlatform.stopLiveRateStream();
        }
        return;
      }
      streaming = started;
    });

    const interval = window.setInterval(() => {
      if (!streaming) {
        void refreshLiveRate();
      }
    }, 750);

    return () => {
      cancelled = true;
      unlisten?.();
      if (streaming) {
        void desktopPlatform.stopLiveRateStream();
      }
      window.clearInterval(interval);
    };
  }, [source, state.loading, selectedLiveThreadId]);

  useEffect(() => {
    if (state.dashboard === null || state.loading || liveThreadOptionsLoadStarted.current) {
      return;
    }

    let cancelled = false;
    liveThreadOptionsLoadStarted.current = true;

    async function loadThreadOptions() {
      const liveThreadOptions = await source.readLiveThreadOptions();
      if (!cancelled) {
        setState((current) => mergeLiveThreadOptions(current, liveThreadOptions));
      }
    }

    void loadThreadOptions();

    return () => {
      cancelled = true;
    };
  }, [source, state.dashboard, state.loading]);

  async function reloadAll() {
    preciseLoadStarted.current = false;
    quotaLoadStarted.current = false;
    liveThreadOptionsLoadStarted.current = false;
    repairScanStarted.current = false;
    setState((current) => ({ ...current, loading: true }));
    setState(await readInitialAppState(source));
  }

  async function updateCodexHome(path: string) {
    setSelectedLiveThreadId("");
    setState((current) => ({ ...current, loading: true }));
    await source.setCodexHome(path);
    await reloadAll();
  }

  async function restoreAutoCodexHome() {
    setSelectedLiveThreadId("");
    setState((current) => ({ ...current, loading: true }));
    await source.resetCodexHome();
    await reloadAll();
  }

  function updateProviderRepair(repair: ProviderRepairSnapshot) {
    setState((current) => ({ ...current, repair }));
  }

  const readyState = useMemo(() => readyDashboardState(state), [state]);

  return {
    state,
    readyState,
    reloadAll,
    updateCodexHome,
    restoreAutoCodexHome,
    updateProviderRepair,
    selectedLiveThreadId,
    setSelectedLiveThreadId,
  };
}

async function readInitialAppState(source: DashboardDataSource): Promise<DashboardAppState> {
  const [codexHome, platform, dashboard] = await Promise.all([
    source.getCodexHome(),
    source.readPlatformCapabilities(),
    source.readDashboardSnapshot(),
  ]);
  return {
    codexHome,
    platform,
    dashboard,
    liveRate: pendingLiveRateSnapshot(),
    liveThreadOptions: [],
    repair: pendingRepairSnapshot(),
    loading: false,
  };
}
