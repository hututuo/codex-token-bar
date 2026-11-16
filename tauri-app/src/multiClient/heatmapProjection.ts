import type { ActivityDay } from "../types/dashboard";
import type { ClientTrendBucket } from "./multiClientProduct";
import { modelPresentationIdentity } from "../domain/modelPresentationIdentity";
import { modelAwareAPICostUSD, type OfficialAPIPriceModel } from "../settings/quotaPriceModel";
import { combineChartModels, type ChartModelUsage, type ChartUsageSummary } from "../components/recentUsageChart/usageSummary.ts";
import { floatingTodayModelUsageItems, isReferenceOnlyModelUsage } from "../floating/floatingModelUsage";

export function localDayKey(unix: number): string {
  const d = new Date(unix * 1000);
  return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,"0")}-${String(d.getDate()).padStart(2,"0")}`;
}

/** Shared chart facts adapted to calendar dates, with already-priced external
 * rows. Missing fields never erase known models or become a zero-price day. */
export function projectHeatmapDays(days: ActivityDay[], codex: ActivityDay[],
  external: ClientTrendBucket[], allowed: readonly string[], priceModel: OfficialAPIPriceModel): ActivityDay[] {
  const original = new Map(allowed.includes("codex") ? codex.map(day=>[day.date,day]) : []);
  const others = new Map<string,ClientTrendBucket[]>();
  for(const row of external.filter(row=>allowed.includes(row.client))){
    const key=localDayKey(row.startUnix), rows=others.get(key)??[];
    rows.push(row);others.set(key,rows);
  }
  return days.map(day=>{
    const base=original.get(day.date),rows=others.get(day.date)??[];
    const models:ChartModelUsage[]=(base?.modelBreakdowns??[]).map(row=>{
      const price=modelAwareAPICostUSD([row],row.breakdown,priceModel);
      const item=floatingTodayModelUsageItems([row],priceModel,{mergeAutoReview:false})[0];
      const reference=item?isReferenceOnlyModelUsage(item)&&item.key!=="unknown-models":false;
      const known=reference?null:item?.knownPartialCostUSD??item?.costUSD??null;
      const model=modelPresentationIdentity(row.model).key;
      return {id:"codex|"+model,client:"codex",model,sourceModels:[row.model??"unknown"],...row.breakdown,
        cacheReadComplete:true,cacheWriteTokens:null,
        knownCostUSD:known,unpricedRequests:reference?0:known==null?Math.max(1,row.breakdown.calls):price.unpricedCalls,
        referenceCostUSD:item?.referenceCostUSD,isReferenceOnly:reference};
    });
    const knownTokens=models.reduce((n,row)=>n+row.totalTokens,0);
    const knownCalls=models.reduce((n,row)=>n+row.calls,0);
    const missing=Math.max(0,(base?.tokens??0)-knownTokens),missingCalls=Math.max(0,(base?.calls??0)-knownCalls);
    if(missing>0||missingCalls>0)models.push({id:"codex|unknown",client:"codex",model:"unknown",
      sourceModels:["模型明细未提供"],totalTokens:missing,calls:missingCalls,inputTokens:0,cachedInputTokens:0,outputTokens:0,
      cacheReadComplete:false,cacheWriteTokens:null,knownCostUSD:null,unpricedRequests:missingCalls});
    const baseInput=base?.cacheInputTokens??models.reduce((n,row)=>n+row.inputTokens,0);
    const baseRead=base?.cacheReadTokens??models.reduce((n,row)=>n+row.cachedInputTokens,0);
    let cacheComplete=(!base||base.tokens===0||base.cacheHitRateKnown!==false&&missing===0);
    for(const row of rows){
      const model=modelPresentationIdentity(row.model).key;
      const complete=row.inputTokens===0 || row.cacheReadComplete===true&&row.cacheReadTokens!=null;
      cacheComplete&&=complete;
      models.push({id:row.client+"|"+model,client:row.client,model,sourceModels:[row.model??"模型明细未提供"],
        totalTokens:row.inputTokens+row.outputTokens,inputTokens:row.inputTokens,cachedInputTokens:row.cacheReadTokens??0,
        outputTokens:row.outputTokens,calls:row.requests,cacheReadComplete:complete,
        cacheWriteTokens:row.cacheWriteComplete===true?row.cacheWriteTokens??null:null,
        knownCostUSD:row.apiCostMicroUSD==null?null:row.apiCostMicroUSD/1_000_000,
        unpricedRequests:row.apiCostMicroUSD==null?row.requests:row.unpricedRequests??0});
    }
    const input=baseInput+rows.reduce((n,row)=>n+row.inputTokens,0);
    const cached=baseRead+rows.reduce((n,row)=>n+(row.cacheReadTokens??0),0);
    const usage:ChartUsageSummary={totalTokens:day.tokens,calls:day.calls,inputTokens:input,cachedInputTokens:cached,
      outputTokens:models.reduce((n,row)=>n+row.outputTokens,0),models:combineChartModels(models),
      cacheReadComplete:cacheComplete,cacheHitRate:cacheComplete&&input>0?cached/input:null,
      modelComplete:missing===0&&missingCalls===0&&models.every(row=>row.model!=="unknown"),
      knownCostUSD:models.reduce((n,row)=>n+(row.knownCostUSD??0),0),
      hasKnownCost:models.some(row=>row.knownCostUSD!=null)||(models.every(row=>row.isReferenceOnly)&&missing===0&&missingCalls===0),
      unpricedRequests:models.reduce((n,row)=>n+row.unpricedRequests,0)};
    return {...day,recordedUsage:usage,cacheHitRateKnown:cacheComplete,cacheInputTokens:input,cacheReadTokens:cached,
      cacheHitRate:usage.cacheHitRate??0};
  });
}
