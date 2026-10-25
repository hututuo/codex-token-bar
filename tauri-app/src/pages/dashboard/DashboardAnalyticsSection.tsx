import { memo } from "react";
import { CacheHitRanking } from "../../components/CacheHitRanking";
import { RecentUsageChart } from "../../components/RecentUsageChart";
import { TokenActivitySection } from "../../components/TokenActivitySection";
import type { DashboardSnapshot, CodexHomeSourceToken } from "../../types/dashboard";
import type { SharedAccountAttributionResult } from "../../components/sharedAccountAttribution/model";
import { modelCostProjectionAvailable } from "../../components/tokenActivity/modelCostAvailability";

interface DashboardAnalyticsSectionProps {
  dashboard: DashboardSnapshot;
  clientScoped?: boolean;
  sourceToken?: CodexHomeSourceToken | null;
  sharedAccountAttribution: SharedAccountAttributionResult | null;
}

function DashboardAnalyticsSectionView({ dashboard, sharedAccountAttribution, sourceToken, clientScoped = false }: DashboardAnalyticsSectionProps) {
  return (
    <>
      <TokenActivitySection
        days={dashboard.activityDays}
        tokensOnly={clientScoped}
        modelCostDataAvailable={modelCostProjectionAvailable(
          dashboard.activityDays,
          dashboard.preciseRecentUsageFresh,
        )}
      />
      <RecentUsageChart
        pricingAvailable={!clientScoped}
        fiveHourQuotaPresent={!clientScoped && dashboard.quota.fiveHour.availability !== "absent"}
        fiveHourResetAtUnix={dashboard.quota.fiveHour.resetsAtUnix ?? null}
        recentUsage24h={dashboard.recentUsage24h}
        recentUsage7d={dashboard.recentUsage7d}
        recentUsage30d={dashboard.recentUsage30d}
        sevenDayQuotaPresent={!clientScoped && dashboard.quota.sevenDay.availability !== "absent"}
        sevenDayResetAtUnix={dashboard.quota.sevenDay.resetsAtUnix ?? null}
        sharedAccountAttribution={clientScoped ? null : sharedAccountAttribution}
      />
      <CacheHitRanking key={JSON.stringify(sourceToken)} sourceToken={sourceToken} cacheUsage={dashboard.cacheUsage} legacyItems={dashboard.cacheHitRanking} />
    </>
  );
}

export const DashboardAnalyticsSection = memo(DashboardAnalyticsSectionView);
