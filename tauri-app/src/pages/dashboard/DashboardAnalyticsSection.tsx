import { CacheHitRanking } from "../../components/CacheHitRanking";
import { ProviderRepairCard } from "../../components/ProviderRepairCard";
import { RecentUsageChart } from "../../components/RecentUsageChart";
import { TokenActivitySection } from "../../components/TokenActivitySection";
import type { DashboardSnapshot, ProviderRepairSnapshot } from "../../types/dashboard";

interface DashboardAnalyticsSectionProps {
  dashboard: DashboardSnapshot;
  onProviderRepairChange: (snapshot: ProviderRepairSnapshot) => void;
  providerRepair: ProviderRepairSnapshot;
}

export function DashboardAnalyticsSection({
  dashboard,
  onProviderRepairChange,
  providerRepair,
}: DashboardAnalyticsSectionProps) {
  return (
    <>
      <TokenActivitySection days={dashboard.activityDays} />
      <RecentUsageChart points={dashboard.recentUsage24h} />
      <CacheHitRanking items={dashboard.cacheHitRanking} />
      <ProviderRepairCard id="provider-repair" onSnapshotChange={onProviderRepairChange} snapshot={providerRepair} />
    </>
  );
}
