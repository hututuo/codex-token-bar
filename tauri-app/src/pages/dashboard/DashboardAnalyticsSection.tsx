import { memo, useMemo } from "react";
import { projectOriginalDashboard } from "../../multiClient/originalDashboardProjection";
import { clientNames, type Snapshot, type UsageClient } from "../../multiClient/MultiClientUsage";
import { ClientCacheRanking } from "../../multiClient/ClientCacheRanking";
import { CacheHitRanking } from "../../components/CacheHitRanking";
import { RecentUsageChart } from "../../components/RecentUsageChart";
import { TokenActivitySection } from "../../components/TokenActivitySection";
import type { DashboardSnapshot, CodexHomeSourceToken } from "../../types/dashboard";
import type { SharedAccountAttributionResult } from "../../components/sharedAccountAttribution/model";
import { modelCostProjectionAvailable } from "../../components/tokenActivity/modelCostAvailability";

interface DashboardAnalyticsSectionProps {
  dashboard: DashboardSnapshot;
  clientScoped?: boolean;
  originalCodex?: DashboardSnapshot;
  clients?: Snapshot;
  allowed?: readonly string[];
  sourceToken?: CodexHomeSourceToken | null;
  sharedAccountAttribution: SharedAccountAttributionResult | null;
}

function DashboardAnalyticsSectionView({ dashboard, originalCodex, clients, allowed, sharedAccountAttribution, sourceToken, clientScoped = false }: DashboardAnalyticsSectionProps) {
  const sources = useMemo(() => {
    if (!originalCodex || !clients || !allowed) return [{client:clientScoped?"local":"codex",dashboard,isCodex:!clientScoped}];
    return [...allowed].sort((a,b)=>a==="codex"?-1:b==="codex"?1:a.localeCompare(b)).map(client=>({
      client, dashboard: projectOriginalDashboard(originalCodex,clients,[client]), isCodex:client==="codex",
    }));
  },[dashboard,originalCodex,clients,allowed?.join(","),clientScoped]);
  return <>{sources.map(({client,dashboard:source,isCodex})=><section key={client} className="client-analytics" data-client={client}>
    {sources.length>1&&<h2>{isCodex?"Codex":clientNames[client as UsageClient]??client} · 用量与缓存</h2>}
    <TokenActivitySection
      days={source.activityDays}
      tokensOnly={!isCodex}
      modelCostDataAvailable={modelCostProjectionAvailable(source.activityDays,source.preciseRecentUsageFresh)}
    />
    <RecentUsageChart
      pricingAvailable={isCodex}
      fiveHourQuotaPresent={isCodex&&source.quota.fiveHour.availability!=="absent"}
      fiveHourResetAtUnix={isCodex?source.quota.fiveHour.resetsAtUnix:null}
      recentUsage24h={source.recentUsage24h}
      recentUsage7d={source.recentUsage7d}
      recentUsage30d={source.recentUsage30d}
      sevenDayQuotaPresent={isCodex&&source.quota.sevenDay.availability!=="absent"}
      sevenDayResetAtUnix={isCodex?source.quota.sevenDay.resetsAtUnix:null}
      sharedAccountAttribution={isCodex?sharedAccountAttribution:null}
    />
    {isCodex?<CacheHitRanking key={JSON.stringify(sourceToken)} sourceToken={sourceToken} cacheUsage={source.cacheUsage} legacyItems={source.cacheHitRanking}/>:<ClientCacheRanking client={client}/>}
  </section>)}</>;
}

export const DashboardAnalyticsSection = memo(DashboardAnalyticsSectionView);
