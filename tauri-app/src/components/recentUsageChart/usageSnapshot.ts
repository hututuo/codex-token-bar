import type { RecentUsagePoint } from "../../types/dashboard";
import type { ClientTrendBucket } from "../../multiClient/multiClientProduct";
import { modelPresentationIdentity } from "../../domain/modelPresentationIdentity";
import { modelAwareAPICostUSD, type OfficialAPIPriceModel } from "../../settings/quotaPriceModel";
import { recordedChartCosts } from "./recordedCosts";
import { recentChartBucketEstimates, type PreparedRecentChartData } from "./model";

export interface ChartModelUsage {
  id: string; client: string; model: string; sourceModels: string[];
  totalTokens: number; inputTokens: number; cachedInputTokens: number; outputTokens: number; calls: number;
  cacheReadComplete: boolean; cacheWriteTokens: number | null; knownCostUSD: number | null; unpricedRequests: number;
}
export interface ChartUsageSummary {
  totalTokens: number; inputTokens: number; cachedInputTokens: number; outputTokens: number; calls: number;
  models: ChartModelUsage[]; cacheReadComplete: boolean; modelComplete: boolean; cacheHitRate: number | null;
  knownCostUSD: number; hasKnownCost: boolean; unpricedRequests: number;
}
export function chartModelCacheHitRate(row: ChartModelUsage): number | null {
  return row.cacheReadComplete && row.inputTokens > 0 ? row.cachedInputTokens / row.inputTokens : null;
}
export function chartModelCacheText(row: ChartModelUsage): string {
  const rate = chartModelCacheHitRate(row);
  return rate === null ? "—" : `${Math.round(rate * 100)}%`;
}
export function chartModelCacheDetail(row: ChartModelUsage): string {
  return !row.cacheReadComplete ? "缓存命中率未知：部分请求未报告缓存读取量"
    : row.inputTokens === 0 ? "缓存命中率不适用：没有输入 Token" : `缓存命中率 ${chartModelCacheText(row)}`;
}
export function combineChartModels(rows: readonly ChartModelUsage[]): ChartModelUsage[] {
  const groups = new Map<string, ChartModelUsage>();
  for (const row of rows) {
    const previous = groups.get(row.id);
    if (!previous) { groups.set(row.id, { ...row, cacheReadComplete: row.inputTokens === 0 || row.cacheReadComplete, sourceModels: [...row.sourceModels] }); continue; }
    previous.cacheReadComplete = (previous.inputTokens === 0 || previous.cacheReadComplete)
      && (row.inputTokens === 0 || row.cacheReadComplete);
    previous.sourceModels = [...new Set([...previous.sourceModels, ...row.sourceModels])].sort();
    for (const key of ["totalTokens","inputTokens","cachedInputTokens","outputTokens","calls","unpricedRequests"] as const) previous[key] += row[key];
    previous.cacheWriteTokens = previous.cacheWriteTokens === null || row.cacheWriteTokens === null ? null : previous.cacheWriteTokens + row.cacheWriteTokens;
    previous.knownCostUSD = previous.knownCostUSD === null && row.knownCostUSD === null ? null : (previous.knownCostUSD ?? 0) + (row.knownCostUSD ?? 0);
  }
  return [...groups.values()].sort((a,b) => b.totalTokens-a.totalTokens || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}
export function chartUsageSummary(buckets: readonly ChartUsageSummary[], start: number, end: number): ChartUsageSummary | null {
  const rows = buckets.slice(Math.max(0,Math.min(start,end)),Math.min(buckets.length-1,Math.max(start,end))+1);
  if (!rows.length) return null;
  const sum = (key: "totalTokens" | "inputTokens" | "cachedInputTokens" | "outputTokens" | "calls" | "knownCostUSD" | "unpricedRequests") => rows.reduce((n,row)=>n+row[key],0);
  const inputTokens=sum("inputTokens"),cachedInputTokens=sum("cachedInputTokens"),cacheReadComplete=rows.every(row=>row.cacheReadComplete);
  return { totalTokens:sum("totalTokens"),inputTokens,cachedInputTokens,outputTokens:sum("outputTokens"),calls:sum("calls"),
    models:combineChartModels(rows.flatMap(row=>row.models)),cacheReadComplete,modelComplete:rows.every(row=>row.modelComplete),
    cacheHitRate:cacheReadComplete&&inputTokens>0?cachedInputTokens/inputTokens:null,
    knownCostUSD:sum("knownCostUSD"),hasKnownCost:rows.some(row=>row.hasKnownCost),unpricedRequests:sum("unpricedRequests") };
}

/** One bounded snapshot feeds the plot, headline, hover and both selection
 * previews. Provider quota calculations retain their own points and prices. */
export function buildChartUsageSnapshot(data: PreparedRecentChartData, provider: readonly RecentUsagePoint[],
  external: readonly ClientTrendBucket[] | undefined, includesCodex: boolean, priceModel: OfficialAPIPriceModel) {
  const estimates = includesCodex ? recentChartBucketEstimates(provider,priceModel) : [];
  const providerCosts = estimates.map(estimate=>Number.isFinite(estimate.costUSD)?Math.max(estimate.costUSD,0):0);
  const recorded = recordedChartCosts(data.points,data.bucketSeconds,external,providerCosts,includesCodex);
  const byTime = new Map<number,ClientTrendBucket[]>();
  for (const row of external ?? []) {
    const key=Math.floor(row.startUnix/data.bucketSeconds),list=byTime.get(key)??[];list.push(row);byTime.set(key,list);
  }
  const buckets:ChartUsageSummary[] = data.points.map((point,index)=>{
    const codex=includesCodex?provider[index]:undefined;
    const others=byTime.get(Math.floor(point.startUnix/data.bucketSeconds))??[];
    const models:ChartModelUsage[]=(codex?.modelBreakdowns??[]).map(row=>{
      const model=modelPresentationIdentity(row.model).key;
      const price=modelAwareAPICostUSD([{...row,eventStartUnix:row.eventStartUnix??point.startUnix}],row.breakdown,priceModel);
      return { id:"codex|"+model,client:"codex",model,sourceModels:[row.model??"unknown"],...row.breakdown,
        cacheReadComplete:true,cacheWriteTokens:null,knownCostUSD:price.unpricedCalls<row.breakdown.calls?price.costUSD:null,unpricedRequests:price.unpricedCalls };
    });
    let inputTokens=codex?.inputTokens??0,cachedInputTokens=codex?.cachedInputTokens??0,outputTokens=codex?.outputTokens??0;
    let cacheReadComplete=!codex || codex.inputTokens<=0 || codex.cacheHitRate!==null;
    const attributed=(key:"totalTokens"|"inputTokens"|"cachedInputTokens"|"outputTokens"|"calls")=>models.reduce((n,row)=>n+row[key],0);
    const missingTokens=Math.max(0,(codex?.tokens??0)-attributed("totalTokens"));
    if(missingTokens>0)models.push({id:"codex|unknown",client:"codex",model:"unknown",sourceModels:["unknown"],totalTokens:missingTokens,
      inputTokens:Math.max(0,inputTokens-attributed("inputTokens")),cachedInputTokens:Math.max(0,cachedInputTokens-attributed("cachedInputTokens")),
      outputTokens:Math.max(0,outputTokens-attributed("outputTokens")),calls:Math.max(0,(codex?.calls??0)-attributed("calls")),
      cacheReadComplete,cacheWriteTokens:null,knownCostUSD:null,unpricedRequests:0});
    for (const row of others) {
      const model=modelPresentationIdentity(row.model).key;
      inputTokens+=row.inputTokens;cachedInputTokens+=row.cacheReadTokens??0;outputTokens+=row.outputTokens;
      const rowCacheComplete=row.inputTokens===0 || (row.cacheReadComplete===true && row.cacheReadTokens!=null);
      if(!rowCacheComplete)cacheReadComplete=false;
      models.push({id:row.client+"|"+model,client:row.client,model,sourceModels:[row.model??"unknown"],
        totalTokens:row.inputTokens+row.outputTokens,inputTokens:row.inputTokens,cachedInputTokens:row.cacheReadTokens??0,
        outputTokens:row.outputTokens,calls:row.requests,cacheReadComplete:rowCacheComplete,
        cacheWriteTokens:row.cacheWriteComplete===true?row.cacheWriteTokens??null:null,
        knownCostUSD:row.apiCostMicroUSD==null?null:row.apiCostMicroUSD/1_000_000,
        unpricedRequests:row.apiCostMicroUSD==null?row.requests:row.unpricedRequests??0});
    }
    return {totalTokens:point.tokens,calls:point.calls,inputTokens,cachedInputTokens,outputTokens,
      cacheReadComplete,cacheHitRate:cacheReadComplete&&inputTokens>0?cachedInputTokens/inputTokens:null,
      modelComplete:missingTokens===0&&others.every(row=>row.model!=null)&&models.reduce((n,row)=>n+row.totalTokens,0)===point.tokens,models:combineChartModels(models),
      knownCostUSD:recorded[index].cost,
      hasKnownCost:(codex?.calls??0)>(estimates[index]?.unpricedCalls??0)||others.some(row=>row.apiCostMicroUSD!=null),
      unpricedRequests:recorded[index].unknown+(estimates[index]?.unpricedCalls??0)};
  });
  return { data,buckets,bucketCostsUSD:buckets.map(row=>row.knownCostUSD) };
}
