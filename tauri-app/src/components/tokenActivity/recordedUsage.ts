import type { ChartUsageSummary } from "../recentUsageChart/usageSummary.ts";
import { modelPresentationIdentity } from "../../domain/modelPresentationIdentity.ts";
import { modelUsageColor } from "../modelUsagePresentation.ts";
import { CLIENT_TITLES } from "../liveRate/speedDisplay.ts";
import { floatingModelUsageMoneyText } from "../../floating/floatingModelUsage.ts";
import { formatTokens, formatPercent } from "../../utils/format.ts";
import type { ActivityDay } from "../../types/dashboard";
import { quotaPercentNumber } from "../../multiClient/multiClientProduct.ts";

export function recordedCostText(usage: ChartUsageSummary): string {
  if(!usage.hasKnownCost)return usage.totalTokens===0&&usage.calls===0?"$0.00":"金额未报告";
  return (usage.unpricedRequests>0||!usage.modelComplete?"已知金额 ":"API 等值 ")+floatingModelUsageMoneyText(usage.knownCostUSD);
}
export function recordedModelsText(usage: ChartUsageSummary,cost=false): string {
  return [...usage.models.map(row=>`${(CLIENT_TITLES[row.client] ?? row.client)} · ${modelPresentationIdentity(row.model).label} ${
    cost?(row.isReferenceOnly?"参考 "+(row.referenceCostUSD==null?"—":floatingModelUsageMoneyText(row.referenceCostUSD))+"（不计入合计）"
      :row.knownCostUSD==null?"金额未报告":floatingModelUsageMoneyText(row.knownCostUSD)):formatTokens(row.totalTokens)+" Token"}`),
    ...(!usage.modelComplete?["部分用量未报告模型"]:[])].join("；");
}
export function recordedGradient(usage: ChartUsageSummary,intensity:number):string {
  const paid=usage.models.filter(row=>(row.knownCostUSD??0)>0),total=paid.reduce((n,row)=>n+(row.knownCostUSD??0),0);
  if(total<=0)return "var(--heatmap-empty)";
  let cursor=0;const stops:string[]=[];
  for(const row of paid){
    const start=cursor;cursor=Math.min(100,cursor+(row.knownCostUSD??0)/total*100);
    const color=`color-mix(in srgb, ${modelUsageColor(row.model)} ${Math.round(28+intensity*68)}%, var(--heatmap-empty))`;
    stops.push(`${color} ${start}%`,`${color} ${cursor}%`);
  }
  return `linear-gradient(90deg, ${stops.join(", ")})`;
}
export function recordedSummary(usage:ChartUsageSummary,mode:string):string {
  if(mode==="cache")return (usage.cacheReadComplete?"命中率 "+(usage.cacheHitRate==null?"—":formatPercent(usage.cacheHitRate)):"缓存字段不完整")+` · ${usage.calls} calls`;
  return (mode==="modelCost"?recordedCostText(usage):formatTokens(usage.totalTokens)+" Token")+" · "+recordedModelsText(usage,mode==="modelCost");
}
export function quotaDayText(day:ActivityDay):string {
  const percent=(value:number|null)=>value==null?"暂无":quotaPercentNumber(value*100)+"%";
  const counts=day.quotaSampleCounts;
  const times=day.quotaObservedRange;
  return `日均剩余 5h ${percent(day.fiveHourRemainingPercent)}${counts?`（${counts.five}次）`:""} · 7d ${percent(day.sevenDayRemainingPercent)}${counts?`（${counts.seven}次）`:""}`
    +(times?` · ${new Date(times.first*1000).toLocaleTimeString()}–${new Date(times.last*1000).toLocaleTimeString()}`:"");
}
