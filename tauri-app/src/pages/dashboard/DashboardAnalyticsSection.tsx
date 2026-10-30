import { memo, useEffect, useMemo, useState } from "react";
import { projectOriginalDashboard } from "../../multiClient/originalDashboardProjection";
import type { Snapshot } from "../../multiClient/MultiClientUsage";
import { ClientCacheRanking } from "../../multiClient/ClientCacheRanking";
import { useAggregateClientCacheRows } from "../../multiClient/aggregateCacheRanking";
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
const CODEX = ["codex"];
const LOCAL = ["local"];

function DashboardAnalyticsSectionView({ dashboard, originalCodex, clients, allowed, sharedAccountAttribution, sourceToken, clientScoped = false }: DashboardAnalyticsSectionProps) {
  const scope = allowed ?? (clientScoped ? LOCAL : CODEX);
  const includesCodex = scope.includes("codex");
  const aggregate = scope.length !== 1 || !includesCodex;
  const source = useMemo(() => originalCodex && clients
    ? projectOriginalDashboard(originalCodex, clients, [...scope]) : dashboard,
    [dashboard, originalCodex, clients, scope.join(",")]);
  const codex = originalCodex ?? dashboard;
  const localRanking = useAggregateClientCacheRows(clients, scope);
  const [localDetail, setLocalDetail] = useState<{client: string; sessionID: string} | null>(null);
  const scopeKey = scope.join(",");
  useEffect(() => setLocalDetail(null), [scopeKey]);
  return <section className="client-analytics" data-client={scope.length > 1 ? "all" : scope[0]}>
    <TokenActivitySection
      days={source.activityDays}
      tokensOnly={!includesCodex}
      modelCostDataAvailable={modelCostProjectionAvailable(source.activityDays, source.preciseRecentUsageFresh)}
    />
    <RecentUsageChart
      pricingAvailable={includesCodex}
      quotaCostSeries={aggregate && includesCodex ? codex : undefined}
      fiveHourQuotaPresent={includesCodex && codex.quota.fiveHour.availability !== "absent"}
      fiveHourResetAtUnix={includesCodex ? codex.quota.fiveHour.resetsAtUnix : null}
      recentUsage24h={source.recentUsage24h}
      recentUsage7d={source.recentUsage7d}
      recentUsage30d={source.recentUsage30d}
      sevenDayQuotaPresent={includesCodex && codex.quota.sevenDay.availability !== "absent"}
      sevenDayResetAtUnix={includesCodex ? codex.quota.sevenDay.resetsAtUnix : null}
      sharedAccountAttribution={includesCodex ? sharedAccountAttribution : null}
    />
    {aggregate && includesCodex && <p className="analytics-source-note">Token、调用和命中率为汇总；额度、逐桶金额及额度反推保留 Codex 来源。其他客户端尚无逐桶模型金额，不按 Codex 单价估填。</p>}
    {localRanking.issue && <p role="status">{localRanking.issue}</p>}
    <CacheHitRanking key={scope.join(",") + JSON.stringify(sourceToken)}
      sourceToken={includesCodex ? sourceToken : null} cacheUsage={source.cacheUsage}
      legacyItems={source.cacheHitRanking} aggregate={aggregate} localOnly={!includesCodex}
      additionalItems={localRanking.rows}
      onOpenLocalSession={(client, sessionID) => setLocalDetail({client, sessionID})}/>
    {localDetail && scope.includes(localDetail.client) && <ClientCacheRanking key={localDetail.client + "|" + localDetail.sessionID}
      client={localDetail.client} sessionID={localDetail.sessionID} detailsOnly onClose={() => setLocalDetail(null)}/>}
  </section>;
}

export const DashboardAnalyticsSection = memo(DashboardAnalyticsSectionView);
