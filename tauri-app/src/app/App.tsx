import { useEffect, useMemo, useRef, useState } from "react";
import { emit, listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import {
  getCodexHome,
  hideFloatingWindow,
  readAccountQuota,
  readDashboardSnapshot,
  readLiveRateSnapshot,
  readPreciseDashboardSnapshot,
  resetCodexHome,
  scanProviderRepair,
  setCodexHome,
  showFloatingWindow,
} from "../api/client";
import { FloatingWindowApp } from "../floating/FloatingWindowApp";
import {
  FLOATING_SETTINGS_EVENT,
  readFloatingSettings,
  sanitizeFloatingSettings,
  writeFloatingSettings,
} from "../floating/floatingSettings";
import { DashboardPage } from "../pages/DashboardPage";
import { useStatusTray } from "../tray/useStatusTray";
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
  codexHome: pendingCodexHomeStatus(),
  dashboard: pendingDashboardSnapshot(),
  liveRate: pendingLiveRateSnapshot(),
  repair: pendingRepairSnapshot(),
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
  const repairScanStarted = useRef(false);
  const [floatingVisible, setFloatingVisible] = useState(true);
  const [floatingSettings, setFloatingSettings] = useState(readFloatingSettings);
  useStatusTray(state.liveRate);

  useEffect(() => {
    let cancelled = false;

    async function load() {
      const nextState = await readAppState();
      if (!cancelled) {
        setState(nextState);
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
    if (state.dashboard === null || state.loading || repairScanStarted.current) {
      return;
    }

    let cancelled = false;
    repairScanStarted.current = true;

    async function loadProviderRepair() {
      const repair = await scanProviderRepair();
      if (!cancelled) {
        setState((current) => ({ ...current, repair }));
      }
    }

    void loadProviderRepair();

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

  useEffect(() => {
    const sanitized = sanitizeFloatingSettings(floatingSettings);
    writeFloatingSettings(sanitized);
    if ("__TAURI_INTERNALS__" in window) {
      void emit(FLOATING_SETTINGS_EVENT, sanitized);
    }
  }, [floatingSettings]);

  async function toggleFloatingWindow() {
    const nextVisible = !floatingVisible;
    setFloatingVisible(nextVisible);
    const confirmed = nextVisible ? await showFloatingWindow() : await hideFloatingWindow();
    setFloatingVisible(confirmed);
  }

  function updateFloatingOpacity(opacity: number) {
    setFloatingSettings((current) => sanitizeFloatingSettings({ ...current, opacity }));
  }

  function updateFloatingScale(scale: number) {
    setFloatingSettings((current) => sanitizeFloatingSettings({ ...current, scale }));
  }

  function updateProviderRepair(repair: ProviderRepairSnapshot) {
    setState((current) => ({ ...current, repair }));
  }

  async function reloadAll() {
    preciseLoadStarted.current = false;
    quotaLoadStarted.current = false;
    repairScanStarted.current = false;
    setState((current) => ({ ...current, loading: true }));
    setState(await readAppState());
  }

  async function updateCodexHome(path: string) {
    setState((current) => ({ ...current, loading: true }));
    await setCodexHome(path);
    await reloadAll();
  }

  async function restoreAutoCodexHome() {
    setState((current) => ({ ...current, loading: true }));
    await resetCodexHome();
    await reloadAll();
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
        <div className="loading-text">正在读取本地数据</div>
      </main>
    );
  }

  return (
    <DashboardPage
      codexHome={readyState.codexHome}
      dashboard={readyState.dashboard}
      floatingSettings={floatingSettings}
      floatingVisible={floatingVisible}
      liveRate={readyState.liveRate}
      onRefresh={reloadAll}
      onFloatingOpacityChange={updateFloatingOpacity}
      onFloatingScaleChange={updateFloatingScale}
      onToggleFloating={toggleFloatingWindow}
      onCodexHomeChange={updateCodexHome}
      onCodexHomeReset={restoreAutoCodexHome}
      providerRepair={readyState.repair}
      onProviderRepairChange={updateProviderRepair}
      refreshing={state.loading}
    />
  );
}

async function readAppState(): Promise<AppState> {
  const [codexHome, dashboard] = await Promise.all([
    getCodexHome(),
    readDashboardSnapshot(),
  ]);
  const liveRate = pendingLiveRateSnapshot();
  return { codexHome, dashboard, liveRate, repair: pendingRepairSnapshot(), loading: false };
}

function pendingLiveRateSnapshot(): LiveRateSnapshot {
  return {
    scopeLabel: "全会话",
    threadTitle: "实时速率正在连接",
    tokensPerSecond: 0,
    totalTokensToday: 0,
    requestsToday: 0,
    maxTokensPerSecond: 200,
    preciseEnabled: false,
  };
}

function pendingCodexHomeStatus(): CodexHomeStatus {
  return {
    path: "~/.codex",
    exists: false,
    source: "读取中",
  };
}

function pendingDashboardSnapshot(): DashboardSnapshot {
  return {
    generatedAt: new Date().toISOString(),
    account: {
      displayName: "读取中",
      planLabel: "Pro",
    },
    stats: {
      totalTokens: 0,
      peakDayTokens: 0,
      peakThreadTokens: 0,
      currentStreakDays: 0,
      longestStreakDays: 0,
      totalCalls: 0,
      totalThreads: 0,
    },
    quota: {
      fiveHour: {
        label: "5h",
        remainingPercent: 0,
        usedPercent: 0,
        resetsAt: "待读取",
        resetsAtUnix: null,
      },
      sevenDay: {
        label: "7d",
        remainingPercent: 0,
        usedPercent: 0,
        resetsAt: "待读取",
        resetsAtUnix: null,
      },
      resetCredit: {
        availableCount: 0,
        status: "重置卡待读取",
        credits: [],
      },
      paceLabel: "额度待读取",
    },
    activityDays: pendingActivityDays(),
    recentUsage24h: pendingRecentUsage(),
    cacheHitRanking: [],
  };
}

function pendingActivityDays() {
  return Array.from({ length: 365 }, (_, index) => {
    const date = new Date();
    date.setDate(date.getDate() - (364 - index));
    return {
      date: date.toISOString().slice(0, 10),
      tokens: 0,
      calls: 0,
      cacheHitRate: 0,
      fiveHourRemainingPercent: null,
      sevenDayRemainingPercent: null,
    };
  });
}

function pendingRecentUsage() {
  return Array.from({ length: 48 }, (_, index) => ({
    label: `${String(Math.floor(index / 2)).padStart(2, "0")}:00`,
    tokens: 0,
    calls: 0,
    cacheHitRate: null,
    fiveHourRemainingPercent: null,
    sevenDayRemainingPercent: null,
  }));
}

function pendingRepairSnapshot(): ProviderRepairSnapshot {
  return {
    detectedProvider: "读取中",
    providerSource: "后台扫描",
    sessionFilesFound: 0,
    inconsistentCount: 0,
    status: "会话修复正在后台扫描，不影响主页面打开。",
    steps: [
      { label: "扫描", status: "后台扫描中", done: false, healthy: true },
      { label: "备份", status: "未备份", done: false, healthy: true },
      { label: "修复", status: "未进行修复", done: false, healthy: true },
      { label: "验证", status: "未验证", done: false, healthy: true },
    ],
  };
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
