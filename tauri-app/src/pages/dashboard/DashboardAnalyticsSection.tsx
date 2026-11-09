import { memo, useEffect, useMemo, useState } from "react";
import { clientTitle } from "../../multiClient/useClientScope";
import { useSharedChoice } from "../../multiClient/useSharedChoice";
import { projectOriginalDashboard } from "../../multiClient/originalDashboardProjection";
import { RECENT_CHART_CLIENT_KEY, recentChartAvailableClients, resolvedRecentChartClients } from "../../multiClient/recentChartClientScope";
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
  // The parent prepares the scoped dashboard once for summary and analytics.
  // Keep originalCodex only for provider-specific quota/cost provenance.
  const source = dashboard;
  const codex = originalCodex ?? dashboard;
  const [chartSelection, setChartSelection] = useSharedChoice(RECENT_CHART_CLIENT_KEY, "recent-chart-client-scope-changed", "dashboard");
  const available = useMemo(() => recentChartAvailableClients(clients), [clients]);
  const chartClients = useMemo(() => resolvedRecentChartClients(chartSelection, scope, available), [chartSelection, scope, available]);
  const chartKey = [...chartClients].sort().join(",");
  const pageKey = [...scope].sort().join(",");
  // The page has already projected this scope. Reuse it until the user explicitly
  // picks a different chart client; don't rebuild buckets on unrelated renders.
  const chart = useMemo(() => chartKey === pageKey || !clients ? source : projectOriginalDashboard(codex, clients, chartClients),
    [source, codex, clients, chartKey, pageKey]);
  const chartIncludesCodex = chartClients.includes("codex");
  const chartAggregate = chartClients.length !== 1 || !chartIncludesCodex;
  const trendBuckets = clients?.trendBuckets;
  const externalCosts = useMemo(() => trendBuckets?.filter(row=>chartClients.includes(row.client)) ?? [], [trendBuckets,chartKey]);
  const effectiveSelection = ["dashboard", "all", "codex", ...available].includes(chartSelection) ? chartSelection : "dashboard";
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
      key={chartKey + "|" + JSON.stringify(sourceToken)}
      sourceControl={clients && <select aria-label="图表客户端" className="recent-chart-client" value={effectiveSelection} onChange={e => setChartSelection(e.target.value)}>
        <option value="dashboard">跟随主页 · {scope.length === 1 ? clientTitle(scope[0]) : "汇总"}</option>
        <option value="all">汇总</option><option value="codex">Codex</option>
        {available.map(id => <option key={id} value={id}>{clientTitle(id)}</option>)}
      </select>}
      unreportedCompactionUnix={chartIncludesCodex ? codex.stats.unreportedCompactionUnix : undefined}
      pricingAvailable={chartIncludesCodex || externalCosts.some(row=>row.apiCostMicroUSD!=null)}
      externalCostBuckets={chartAggregate ? externalCosts : undefined}
      includesCodexCost={chartIncludesCodex}
      quotaCostSeries={chartAggregate && chartIncludesCodex ? codex : undefined}
      fiveHourQuotaPresent={chartIncludesCodex && codex.quota.fiveHour.availability !== "absent"}
      fiveHourResetAtUnix={chartIncludesCodex ? codex.quota.fiveHour.resetsAtUnix : null}
      recentUsage24h={chart.recentUsage24h}
      recentUsage7d={chart.recentUsage7d}
      recentUsage30d={chart.recentUsage30d}
      sevenDayQuotaPresent={chartIncludesCodex && codex.quota.sevenDay.availability !== "absent"}
      sevenDayResetAtUnix={chartIncludesCodex ? codex.quota.sevenDay.resetsAtUnix : null}
      sharedAccountAttribution={chartIncludesCodex ? sharedAccountAttribution : null}
    />
    {chartAggregate && chartIncludesCodex && <p className="analytics-source-note">Token、调用与金额汇总所选客户端，命中率按输入加权；额度和额度反推仅对应 Codex 账户。</p>}
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
