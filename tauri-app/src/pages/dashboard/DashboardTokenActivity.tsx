import { useEffect, useMemo, useState } from "react";
import type { DashboardSnapshot } from "../../types/dashboard";
import type { Snapshot } from "../../multiClient/MultiClientUsage";
import { useSharedChoice } from "../../multiClient/useSharedChoice";
import { clientTitle } from "../../multiClient/useClientScope";
import { recentChartAvailableClients, resolvedRecentChartClients } from "../../multiClient/recentChartClientScope";
import { projectOriginalDashboard } from "../../multiClient/originalDashboardProjection";
import { projectHeatmapDays } from "../../multiClient/heatmapProjection";
import { applyClientQuotaDays, quotaChartSources, resolveQuotaChartSource } from "../../multiClient/clientQuotaHistory";
import { TokenActivitySection } from "../../components/TokenActivitySection";
import { QUOTA_PRICE_MODEL_EVENT, readStoredQuotaPriceModel } from "../../settings/quotaPriceModel";

export function DashboardTokenActivity({dashboard,codex,clients,pageClients}:{
  dashboard:DashboardSnapshot;codex:DashboardSnapshot;clients?:Snapshot;pageClients:readonly string[];
}){
  const [selection,setSelection]=useSharedChoice("heatmapClientScope.v1","heatmap-client-changed","dashboard");
  const [quotaSelection,setQuotaSelection]=useSharedChoice("heatmapQuotaSource.v1","heatmap-quota-source-changed","codex");
  const [period,setPeriod]=useSharedChoice("heatmapQuotaPeriod.v1","heatmap-quota-period-changed","7d");
  const [price,setPrice]=useState(readStoredQuotaPriceModel);
  useEffect(()=>{const update=()=>setPrice(readStoredQuotaPriceModel());window.addEventListener(QUOTA_PRICE_MODEL_EVENT,update);
    return ()=>window.removeEventListener(QUOTA_PRICE_MODEL_EVENT,update);},[]);
  const available=useMemo(()=>recentChartAvailableClients(clients),[clients]);
  const allowed=useMemo(()=>resolvedRecentChartClients(selection,pageClients,available),[selection,pageClients,available]);
  const key=[...allowed].sort().join(","),pageKey=[...pageClients].sort().join(",");
  const display=useMemo(()=>key===pageKey||!clients?dashboard:projectOriginalDashboard(codex,clients,allowed),
    [key,pageKey,dashboard,codex,clients]);
  const usageDays=useMemo(()=>projectHeatmapDays(display.activityDays,codex.activityDays,clients?.dailyBuckets??[],allowed,price),
    [display.activityDays,codex.activityDays,clients?.dailyBuckets,key,price]);
  const source=useMemo(()=>resolveQuotaChartSource(quotaSelection,allowed,clients?.quotas),[quotaSelection,key,clients?.quotas]);
  const reading=clients?.quotas?.find(row=>row.client===source?.client);
  const days=useMemo(()=>applyClientQuotaDays(usageDays,codex.activityDays,reading,source,period==="5h"?"5h":"7d"),
    [usageDays,codex.activityDays,reading,source,period]);
  const effective=["dashboard","all","codex",...available].includes(selection)?selection:"dashboard";
  return <TokenActivitySection days={days} controls={<label>热力图客户端 <select aria-label="热力图客户端"
    className="recent-chart-client" value={effective} onChange={e=>setSelection(e.target.value)}>
    <option value="dashboard">跟随主页 · {pageClients.length===1?clientTitle(pageClients[0]):"汇总"}</option>
    <option value="all">汇总</option><option value="codex">Codex</option>
    {available.filter(id=>id!=="codex").map(id=><option key={id} value={id}>{clientTitle(id)}</option>)}
  </select></label>} quotaControls={source?<div className="heatmap-quota-controls">
    <label>额度来源 <select className="recent-chart-client" aria-label="热力图额度来源" value={source.id} onChange={e=>setQuotaSelection(e.target.value)}>
      {quotaChartSources(allowed,clients?.quotas).map(item=><option key={item.id} value={item.id}>{item.title}</option>)}
    </select></label>
    <label>周期 <select aria-label="热力图额度周期" className="recent-chart-client" value={period==="5h"?"5h":"7d"} onChange={e=>setPeriod(e.target.value)}>
      <option value="5h">5小时</option><option value="7d">7天</option>
    </select></label>
    <span>{source.title} · 日内有效采样剩余额度均值；空白表示没有观测。</span>
  </div>:<p>所选客户端尚无本地额度来源</p>}/>;
}
