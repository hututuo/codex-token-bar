import { memo } from "react";
import { CacheHitRanking } from "../../components/CacheHitRanking";
import { RecentUsageChart } from "../../components/RecentUsageChart";
import { TokenActivitySection } from "../../components/TokenActivitySection";
import type { DashboardSnapshot, CodexHomeSourceToken } from "../../types/dashboard";
import type { SharedAccountAttributionResult } from "../../components/sharedAccountAttribution/model";
import { modelCostProjectionAvailable } from "../../components/tokenActivity/modelCostAvailability";

interface DashboardAnalyticsSectionProps {
  dashboard: DashboardSnapshot;
  sourceToken?: CodexHomeSourceToken | null;
  sharedAccountAttribution: SharedAccountAttributionResult | null;
}

function DashboardAnalyticsSectionView({ dashboard, sharedAccountAttribution, sourceToken }: DashboardAnalyticsSectionProps) {
  return (
    <>
      <TokenActivitySection
        days={dashboard.activityDays}
        modelCostDataAvailable={modelCostProjectionAvailable(
          dashboard.activityDays,
          dashboard.preciseRecentUsageFresh,
        )}
      />
      <RecentUsageChart
        fiveHourQuotaPresent={dashboard.quota.fiveHour.availability !== "absent"}
        fiveHourResetAtUnix={dashboard.quota.fiveHour.resetsAtUnix ?? null}
        recentUsage24h={dashboard.recentUsage24h}
        recentUsage7d={dashboard.recentUsage7d}
        recentUsage30d={dashboard.recentUsage30d}
        sevenDayQuotaPresent={dashboard.quota.sevenDay.availability !== "absent"}
        sevenDayResetAtUnix={dashboard.quota.sevenDay.resetsAtUnix ?? null}
        sharedAccountAttribution={sharedAccountAttribution}
      />
      <CacheHitRanking key={JSON.stringify(sourceToken)} sourceToken={sourceToken} cacheUsage={dashboard.cacheUsage} legacyItems={dashboard.cacheHitRanking} />
    </>
  );
}

export const DashboardAnalyticsSection = memo(DashboardAnalyticsSectionView);
