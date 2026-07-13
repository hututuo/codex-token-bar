import { memo } from "react";
import { CacheHitRanking } from "../../components/CacheHitRanking";
import { RecentUsageChart } from "../../components/RecentUsageChart";
import { TokenActivitySection } from "../../components/TokenActivitySection";
import type { DashboardSnapshot } from "../../types/dashboard";

interface DashboardAnalyticsSectionProps {
  dashboard: DashboardSnapshot;
}

function DashboardAnalyticsSectionView({ dashboard }: DashboardAnalyticsSectionProps) {
  return (
    <>
      <TokenActivitySection days={dashboard.activityDays} />
      <RecentUsageChart
        fiveHourQuotaPresent={dashboard.quota.fiveHour.availability !== "absent"}
        recentUsage24h={dashboard.recentUsage24h}
        recentUsage7d={dashboard.recentUsage7d}
        recentUsage30d={dashboard.recentUsage30d}
        sevenDayQuotaPresent={dashboard.quota.sevenDay.availability !== "absent"}
      />
      <CacheHitRanking cacheUsage={dashboard.cacheUsage} legacyItems={dashboard.cacheHitRanking} />
    </>
  );
}

export const DashboardAnalyticsSection = memo(DashboardAnalyticsSectionView);
