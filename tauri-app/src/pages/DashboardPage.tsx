import { CacheHitRanking } from "../components/CacheHitRanking";
import { DashboardHeader } from "../components/DashboardHeader";
import { LiveRateCard } from "../components/LiveRateCard";
import { ProviderRepairCard } from "../components/ProviderRepairCard";
import { QuotaStrip } from "../components/QuotaStrip";
import { RecentUsageChart } from "../components/RecentUsageChart";
import { StatsStrip } from "../components/StatsStrip";
import { TokenActivitySection } from "../components/TokenActivitySection";
import type {
  CodexHomeStatus,
  DashboardSnapshot,
  LiveRateSnapshot,
  ProviderRepairSnapshot,
} from "../types/dashboard";

interface DashboardPageProps {
  codexHome: CodexHomeStatus;
  dashboard: DashboardSnapshot;
  floatingVisible: boolean;
  liveRate: LiveRateSnapshot;
  onToggleFloating: () => void;
  providerRepair: ProviderRepairSnapshot;
  refreshing: boolean;
}

export function DashboardPage({
  codexHome,
  dashboard,
  floatingVisible,
  liveRate,
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
          refreshing={refreshing}
        />

        <QuotaStrip snapshot={dashboard.quota} />
        <StatsStrip stats={dashboard.stats} />
        <LiveRateCard
          floatingVisible={floatingVisible}
          onToggleFloating={onToggleFloating}
          snapshot={liveRate}
        />
        <TokenActivitySection days={dashboard.activityDays} />
        <RecentUsageChart points={dashboard.recentUsage24h} />
        <CacheHitRanking items={dashboard.cacheHitRanking} />
        <ProviderRepairCard snapshot={providerRepair} />
      </section>
    </main>
  );
}
