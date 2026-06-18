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
  LiveRateSnapshot,
  ProviderRepairSnapshot,
} from "../types/dashboard";

interface DashboardPageProps {
  codexHome: CodexHomeStatus;
  dashboard: DashboardSnapshot;
  floatingSettings: FloatingWindowSettings;
  floatingVisible: boolean;
  liveRate: LiveRateSnapshot;
  onCodexHomeChange: (path: string) => Promise<void>;
  onCodexHomeReset: () => Promise<void>;
  onFloatingOpacityChange: (opacity: number) => void;
  onFloatingScaleChange: (scale: number) => void;
  onRefresh: () => Promise<void>;
  onToggleFloating: () => void;
  onProviderRepairChange: (snapshot: ProviderRepairSnapshot) => void;
  providerRepair: ProviderRepairSnapshot;
  refreshing: boolean;
}

export function DashboardPage({
  codexHome,
  dashboard,
  floatingSettings,
  floatingVisible,
  liveRate,
  onCodexHomeChange,
  onCodexHomeReset,
  onFloatingOpacityChange,
  onFloatingScaleChange,
  onRefresh,
  onProviderRepairChange,
  onToggleFloating,
  providerRepair,
  refreshing,
}: DashboardPageProps) {
  return (
    <main className="app-shell">
      <section className="dashboard">
        <DashboardHeader
          account={dashboard.account}
          codexHome={codexHome}
          generatedAt={dashboard.generatedAt}
          onCodexHomeChange={onCodexHomeChange}
          onCodexHomeReset={onCodexHomeReset}
          onRefresh={onRefresh}
          refreshing={refreshing}
        />

        <QuotaStrip snapshot={dashboard.quota} />
        <StatsStrip stats={dashboard.stats} />
        <LiveRateCard
          floatingSettings={floatingSettings}
          floatingVisible={floatingVisible}
          onFloatingOpacityChange={onFloatingOpacityChange}
          onFloatingScaleChange={onFloatingScaleChange}
          onToggleFloating={onToggleFloating}
          snapshot={liveRate}
        />
        <TokenActivitySection days={dashboard.activityDays} />
        <RecentUsageChart points={dashboard.recentUsage24h} />
        <CacheHitRanking items={dashboard.cacheHitRanking} />
        <ProviderRepairCard onSnapshotChange={onProviderRepairChange} snapshot={providerRepair} />
      </section>
    </main>
  );
}
