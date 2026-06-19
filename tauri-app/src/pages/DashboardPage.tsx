import { useEffect, useState } from "react";
import { CacheHitRanking } from "../components/CacheHitRanking";
import { DashboardHeader } from "../components/DashboardHeader";
import { LiveRateCard } from "../components/LiveRateCard";
import { ProviderRepairCard } from "../components/ProviderRepairCard";
import { QuotaStrip } from "../components/QuotaStrip";
import { RecentUsageChart } from "../components/RecentUsageChart";
import { StatsStrip } from "../components/StatsStrip";
import { TokenActivitySection } from "../components/TokenActivitySection";
import { recordStartupEvent } from "../api/client";
import type { FloatingWindowSettings } from "../floating/floatingSettings";
import type {
  AutostartStatus,
  CodexHomeStatus,
  DashboardSnapshot,
  DisplaySurfaceSettings,
  FloatingUnreadEffect,
  LiveRateSnapshot,
  LiveThreadOption,
  PlatformCapabilities,
  ProviderRepairSnapshot,
} from "../types/dashboard";
import type { CommandFailureDiagnostic } from "../api/client";

interface DashboardPageProps {
  autostartStatus: AutostartStatus;
  codexHome: CodexHomeStatus;
  dashboard: DashboardSnapshot;
  diagnostics: CommandFailureDiagnostic[];
  displaySurfaces: DisplaySurfaceSettings;
  floatingSettings: FloatingWindowSettings;
  floatingVisible: boolean;
  liveRate: LiveRateSnapshot;
  liveThreadOptions: LiveThreadOption[];
  platform: PlatformCapabilities;
  onCodexHomeChange: (path: string) => Promise<void>;
  onCodexHomeReset: () => Promise<void>;
  onFloatingOpacityChange: (opacity: number) => void;
  onFloatingScaleChange: (scale: number) => void;
  onFloatingUnreadEffectChange: (effect: FloatingUnreadEffect) => void;
  onLiveThreadSelect: (threadId: string) => void;
  onRefresh: () => Promise<void>;
  onToggleAutostart: () => void;
  onToggleFloating: () => void;
  onToggleStatusTray: () => void;
  onProviderRepairChange: (snapshot: ProviderRepairSnapshot) => void;
  providerRepair: ProviderRepairSnapshot;
  refreshing: boolean;
  selectedLiveThreadId: string;
}

export function DashboardPage({
  autostartStatus,
  codexHome,
  dashboard,
  diagnostics,
  displaySurfaces,
  floatingSettings,
  floatingVisible,
  liveRate,
  liveThreadOptions,
  platform,
  onCodexHomeChange,
  onCodexHomeReset,
  onFloatingOpacityChange,
  onFloatingScaleChange,
  onFloatingUnreadEffectChange,
  onLiveThreadSelect,
  onRefresh,
  onProviderRepairChange,
  onToggleAutostart,
  onToggleFloating,
  onToggleStatusTray,
  providerRepair,
  refreshing,
  selectedLiveThreadId,
}: DashboardPageProps) {
  const [summaryReady] = useState(true);
  const [analyticsReady, setAnalyticsReady] = useState(false);

  useEffect(() => {
    void recordStartupEvent("dashboard summary ui ready");
  }, []);

  useEffect(() => {
    if (!summaryReady) {
      return;
    }

    let cancelled = false;
    const reveal = () => {
      if (!cancelled) {
        setAnalyticsReady(true);
        void recordStartupEvent("dashboard analytics ui ready");
      }
    };
    const schedule = scheduleAfterFirstPaint(reveal);

    return () => {
      cancelled = true;
      schedule.cancel();
    };
  }, [summaryReady]);

  function openProviderRepair() {
    document.getElementById("provider-repair")?.scrollIntoView({
      behavior: "smooth",
      block: "start",
    });
  }

  return (
    <main className="app-shell">
      <section className="dashboard">
        <DashboardHeader
          account={dashboard.account}
          autostartStatus={autostartStatus}
          codexHome={codexHome}
          diagnostics={diagnostics}
          generatedAt={dashboard.generatedAt}
          onCodexHomeChange={onCodexHomeChange}
          onCodexHomeReset={onCodexHomeReset}
          onOpenProviderRepair={openProviderRepair}
          onRefresh={onRefresh}
          onToggleAutostart={onToggleAutostart}
          refreshing={refreshing}
        />

        {summaryReady ? (
          <>
            <QuotaStrip snapshot={dashboard.quota} />
            <StatsStrip stats={dashboard.stats} />
            <LiveRateCard
              floatingSettings={floatingSettings}
              floatingVisible={floatingVisible}
              statusTrayLiveTextEnabled={displaySurfaces.statusTrayLiveTextEnabled}
              onFloatingOpacityChange={onFloatingOpacityChange}
              onFloatingScaleChange={onFloatingScaleChange}
              onFloatingUnreadEffectChange={onFloatingUnreadEffectChange}
              onLiveThreadSelect={onLiveThreadSelect}
              onToggleFloating={onToggleFloating}
              onToggleStatusTray={onToggleStatusTray}
              liveThreadOptions={liveThreadOptions}
              platform={platform}
              selectedLiveThreadId={selectedLiveThreadId}
              snapshot={liveRate}
            />
            {analyticsReady ? (
              <>
                <TokenActivitySection days={dashboard.activityDays} />
                <RecentUsageChart points={dashboard.recentUsage24h} />
                <CacheHitRanking items={dashboard.cacheHitRanking} />
                <ProviderRepairCard
                  id="provider-repair"
                  onSnapshotChange={onProviderRepairChange}
                  snapshot={providerRepair}
                />
              </>
            ) : (
              <section className="analytics-boot" aria-label="图表区域正在准备">
                <span>正在准备图表和排行...</span>
              </section>
            )}
          </>
        ) : (
          <section className="analytics-boot" aria-label="统计区域正在准备">
            <span>正在准备统计和实时速率...</span>
          </section>
        )}
      </section>
    </main>
  );
}

function scheduleAfterFirstPaint(callback: () => void) {
  let cancelled = false;
  queueMicrotask(() => {
    if (!cancelled) {
      callback();
    }
  });

  return {
    cancel: () => {
      cancelled = true;
    },
  };
}
