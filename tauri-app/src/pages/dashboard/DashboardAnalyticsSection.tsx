import { CacheHitRanking } from "../../components/CacheHitRanking";
import { RecentUsageChart } from "../../components/RecentUsageChart";
import { TokenActivitySection } from "../../components/TokenActivitySection";
import type { DashboardSnapshot } from "../../types/dashboard";

interface DashboardAnalyticsSectionProps {
  dashboard: DashboardSnapshot;
}

export function DashboardAnalyticsSection({ dashboard }: DashboardAnalyticsSectionProps) {
  return (
    <>
      <TokenActivitySection days={dashboard.activityDays} />
      <RecentUsageChart
        recentUsage24h={dashboard.recentUsage24h}
        recentUsage7d={dashboard.recentUsage7d}
        recentUsage30d={dashboard.recentUsage30d}
      />
      <CacheHitRanking items={dashboard.cacheHitRanking} />
    </>
  );
}
