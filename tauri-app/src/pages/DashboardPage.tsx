import { CacheHitRanking } from "../components/CacheHitRanking";
import { DashboardHeader } from "../components/DashboardHeader";
import { LiveRateCard } from "../components/LiveRateCard";
import { ProviderRepairCard } from "../components/ProviderRepairCard";
import { QuotaStrip } from "../components/QuotaStrip";
import { RecentUsageChart } from "../components/RecentUsageChart";
import { StatsStrip } from "../components/StatsStrip";
import { TokenActivitySection } from "../components/TokenActivitySection";
import type { FloatingWindowSettings } from "../floating/floatingSettings";
import type {
  CodexHomeStatus,
  DashboardSnapshot,
  DisplaySurfaceSettings,
  FloatingUnreadEffect,
  LiveRateSnapshot,
  PlatformCapabilities,
  ProviderRepairSnapshot,
} from "../types/dashboard";

interface DashboardPageProps {
  codexHome: CodexHomeStatus;
  dashboard: DashboardSnapshot;
  displaySurfaces: DisplaySurfaceSettings;
  floatingSettings: FloatingWindowSettings;
  floatingVisible: boolean;
  liveRate: LiveRateSnapshot;
  platform: PlatformCapabilities;
  onCodexHomeChange: (path: string) => Promise<void>;
  onCodexHomeReset: () => Promise<void>;
  onFloatingOpacityChange: (opacity: number) => void;
  onFloatingScaleChange: (scale: number) => void;
  onFloatingUnreadEffectChange: (effect: FloatingUnreadEffect) => void;
  onRefresh: () => Promise<void>;
  onToggleFloating: () => void;
  onToggleStatusTray: () => void;
  onProviderRepairChange: (snapshot: ProviderRepairSnapshot) => void;
  providerRepair: ProviderRepairSnapshot;
  refreshing: boolean;
}

export function DashboardPage({
  codexHome,
  dashboard,
  displaySurfaces,
  floatingSettings,
  floatingVisible,
  liveRate,
  platform,
  onCodexHomeChange,
  onCodexHomeReset,
  onFloatingOpacityChange,
  onFloatingScaleChange,
  onFloatingUnreadEffectChange,
  onRefresh,
  onProviderRepairChange,
  onToggleFloating,
  onToggleStatusTray,
  providerRepair,
  refreshing,
}: DashboardPageProps) {
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
          codexHome={codexHome}
          generatedAt={dashboard.generatedAt}
          onCodexHomeChange={onCodexHomeChange}
          onCodexHomeReset={onCodexHomeReset}
          onOpenProviderRepair={openProviderRepair}
          onRefresh={onRefresh}
          refreshing={refreshing}
        />

        <QuotaStrip snapshot={dashboard.quota} />
        <StatsStrip stats={dashboard.stats} />
        <LiveRateCard
          floatingSettings={floatingSettings}
          floatingVisible={floatingVisible}
          statusTrayLiveTextEnabled={displaySurfaces.statusTrayLiveTextEnabled}
          onFloatingOpacityChange={onFloatingOpacityChange}
          onFloatingScaleChange={onFloatingScaleChange}
          onFloatingUnreadEffectChange={onFloatingUnreadEffectChange}
          onToggleFloating={onToggleFloating}
          onToggleStatusTray={onToggleStatusTray}
          platform={platform}
          snapshot={liveRate}
        />
        <TokenActivitySection days={dashboard.activityDays} />
        <RecentUsageChart points={dashboard.recentUsage24h} />
        <CacheHitRanking items={dashboard.cacheHitRanking} />
        <ProviderRepairCard
          id="provider-repair"
          onSnapshotChange={onProviderRepairChange}
          snapshot={providerRepair}
        />
      </section>
    </main>
  );
}
