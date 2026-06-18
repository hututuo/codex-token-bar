import { useEffect, useMemo, useRef, useState, type Dispatch, type SetStateAction } from "react";
import {
  getCommandDiagnosticsSnapshot,
  recordStartupEvent,
  subscribeCommandDiagnostics,
} from "../api/client";
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
  const [fastSnapshotLoaded, setFastSnapshotLoaded] = useState(false);
  const preciseLoadStarted = useRef(false);
  const quotaLoadStarted = useRef(false);
  const forceNextQuotaLoad = useRef(false);
  const liveThreadOptionsLoadStarted = useRef(false);
  const [selectedLiveThreadId, setSelectedLiveThreadId] = useState("");

  useEffect(() => {
    return subscribeCommandDiagnostics((diagnostics) => {
      setState((current) => ({ ...current, diagnostics }));
    });
  }, []);

  useEffect(() => {
    let cancelled = false;

    setFastSnapshotLoaded(false);
    void loadInitialAppStateInParts(
      source,
      () => cancelled,
      (update) => setState(update),
      () => setFastSnapshotLoaded(true),
    );

    return () => {
      cancelled = true;
    };
  }, [source]);

  useEffect(() => {
    if (!fastSnapshotLoaded || state.dashboard === null || state.loading || preciseLoadStarted.current) {
      return;
    }

    let cancelled = false;
    preciseLoadStarted.current = true;

    async function loadPreciseSnapshot() {
      const precise = await source.readPreciseDashboardSnapshot();
      if (!cancelled && precise !== null) {
        setState((current) => mergePreciseDashboard(current, precise));
      }
    }

    void loadPreciseSnapshot();

    return () => {
      cancelled = true;
    };
  }, [fastSnapshotLoaded, source, state.dashboard, state.loading]);

  useEffect(() => {
    if (!fastSnapshotLoaded || state.dashboard === null || state.loading || quotaLoadStarted.current) {
      return;
    }

    let cancelled = false;
    quotaLoadStarted.current = true;
    const delayMs = forceNextQuotaLoad.current ? 0 : 5_000;

    async function loadQuota() {
      const quota = await source.readAccountQuota(forceNextQuotaLoad.current);
      forceNextQuotaLoad.current = false;
      if (!cancelled && quota !== null) {
        setState((current) => mergeQuota(current, quota));
      }
    }

    const timer = window.setTimeout(() => {
      void loadQuota();
    }, delayMs);

    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
  }, [fastSnapshotLoaded, source, state.dashboard, state.loading]);

  useEffect(() => {
    if (!fastSnapshotLoaded) {
      return;
    }

    let cancelled = false;
    let liveRateInFlight = false;
    let streaming = false;
    let unlisten: (() => void) | null = null;
    let startupTimer = 0;

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

    startupTimer = window.setTimeout(() => {
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
    }, 250);

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
      window.clearTimeout(startupTimer);
      window.clearInterval(interval);
    };
  }, [fastSnapshotLoaded, source, selectedLiveThreadId]);

  useEffect(() => {
    if (!fastSnapshotLoaded || state.dashboard === null || liveThreadOptionsLoadStarted.current) {
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
  }, [fastSnapshotLoaded, source, state.dashboard, state.loading]);

  async function reloadAll() {
    preciseLoadStarted.current = false;
    quotaLoadStarted.current = false;
    forceNextQuotaLoad.current = true;
    liveThreadOptionsLoadStarted.current = false;
    setFastSnapshotLoaded(false);
    setState((current) => ({ ...current, loading: true }));
    await loadInitialAppStateInParts(
      source,
      () => false,
      (update) => setState(update),
      () => setFastSnapshotLoaded(true),
    );
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

async function loadInitialAppStateInParts(
  source: DashboardDataSource,
  isCancelled: () => boolean,
  setState: Dispatch<SetStateAction<DashboardAppState>>,
  markFastSnapshotLoaded: () => void,
): Promise<void> {
  void source.getCodexHome().then((codexHome) => {
    if (!isCancelled()) {
      setState((current) => ({ ...current, codexHome }));
      void recordStartupEvent("codex home ready");
    }
  });

  void source.readPlatformCapabilities().then((platform) => {
    if (!isCancelled()) {
      setState((current) => ({ ...current, platform }));
      void recordStartupEvent("platform ready");
    }
  });

  await source.readDashboardSnapshot().then((dashboard) => {
    if (!isCancelled()) {
      setState((current) => ({
        ...current,
        dashboard,
        diagnostics: getCommandDiagnosticsSnapshot(),
        loading: false,
      }));
      markFastSnapshotLoaded();
      void recordStartupEvent("dashboard snapshot ready");
    }
  });
}
