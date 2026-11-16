export interface ChartModelUsage {
  id: string; client: string; model: string; sourceModels: string[];
  totalTokens: number; inputTokens: number; cachedInputTokens: number; outputTokens: number; calls: number;
  cacheReadComplete: boolean; cacheWriteTokens: number | null; knownCostUSD: number | null; unpricedRequests: number;
  referenceCostUSD?: number | null; isReferenceOnly?: boolean;
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
    previous.referenceCostUSD = previous.referenceCostUSD==null&&row.referenceCostUSD==null?null:(previous.referenceCostUSD??0)+(row.referenceCostUSD??0);
    previous.isReferenceOnly = previous.isReferenceOnly===true&&row.isReferenceOnly===true;
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

