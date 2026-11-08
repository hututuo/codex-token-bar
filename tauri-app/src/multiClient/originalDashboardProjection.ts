import { claudeModelGroups } from "../components/claudeModelPresentation";
import type { DashboardSnapshot, RecentUsagePoint, ModelTokenBreakdown } from '../types/dashboard';
import type { Snapshot, Summary } from './MultiClientUsage';
import { projectClientDays } from './integratedClientModel';
import { clientNames } from './MultiClientUsage';
import { floatingTodayModelUsageItems, type FloatingModelUsageItem, dashboardModelFamilyGroups } from '../floating/floatingModelUsage';
import { modelUsageColor } from '../components/modelUsagePresentation';
import { modelPresentationIdentity, modelPresentationDetail } from '../domain/modelPresentationIdentity';
import { officialAPICostUSD, independentQuotaModelName, isAutoReviewUsage, priceModelTitle, type OfficialAPIPriceModel } from '../settings/quotaPriceModel';

export interface ClientCostPeriods {
  lifetime: FloatingModelUsageItem[];
  today: FloatingModelUsageItem[];
  sevenDay: FloatingModelUsageItem[];
  codexPendingScopes?: ("today"|"sevenDay")[];
}
export function clientCostGroups(allItems: FloatingModelUsageItem[]) {
  const items=allItems.filter(x=>x.tokens>0 && x.key!=="unknown-models");
  const codex = items.filter(x => x.key.startsWith('codex|')).map(x => ({...x,key:x.key.slice(6)}));
  const codexGroups = dashboardModelFamilyGroups(codex);
  const claudeRows=items.filter(x=>/^claude(?:Code|Desktop)\|/.test(x.key));
  const claudeGroups = claudeModelGroups(claudeRows,"claude");
  const groups: {id:string;label:string;items:FloatingModelUsageItem[]}[] = [
    ...codexGroups.filter(g=>g.id==="6"), ...claudeGroups.filter(g=>g.id.endsWith(":latest")),
    ...codexGroups.filter(g=>g.id!=="6"), ...claudeGroups.filter(g=>!g.id.endsWith(":latest")),
  ];
  for (const client of [...new Set(items.filter(x=>!/^codex\||^claude(?:Code|Desktop)\|/.test(x.key)).map(x=>x.key.split('|')[0]))].sort()) {
    groups.push({id:client,label:clientNames[client as keyof typeof clientNames] ?? client,items:items.filter(x=>x.key.startsWith(client+'|'))});
  }
  const unknown=allItems.filter(x=>x.tokens>0 && x.key==="unknown-models");
  if(unknown.length)groups.push({id:"unknown-models",label:"参考",items:unknown});
  return groups;
}
export function clientModelCostItems(rows:Summary[], original:ModelTokenBreakdown[], allowed:readonly string[], fallbackModel:OfficialAPIPriceModel='gpt56Sol'):FloatingModelUsageItem[] {
    const unknownModel=(model:string|null|undefined)=> !isAutoReviewUsage(model) && independentQuotaModelName(model)===null
      && !['known','source'].includes(modelPresentationIdentity(model).kind);
    const selected=rows.filter(x=>allowed.includes(x.client));
    const unknownOriginal=allowed.includes('codex')?original.filter(x=>unknownModel(x.model)&&x.breakdown.totalTokens>0):[];
    const items:FloatingModelUsageItem[] = allowed.includes('codex') ? floatingTodayModelUsageItems(original.filter(x=>!unknownModel(x.model)),fallbackModel,{showPlaceholders:false,mergeAutoReview:false}).map(x=>({...x,key:'codex|'+x.key})) : [];
    let unknownTokens=0,unknownReference=0;
    const unknownSources:string[]=[],knownCosts:number[]=[];
    for(const row of unknownOriginal){
      unknownTokens+=row.breakdown.totalTokens;
      unknownReference+=officialAPICostUSD(row.breakdown.inputTokens,row.breakdown.cachedInputTokens??0,row.breakdown.outputTokens,fallbackModel);
      unknownSources.push('Codex · '+modelPresentationDetail(row.model??'unknown'));
    }
    for(const item of floatingTodayModelUsageItems(unknownOriginal,fallbackModel,{mergeAutoReview:false})){
      const cost=item.costUSD??item.knownPartialCostUSD;if(cost!=null)knownCosts.push(cost);
    }
    for(const row of selected.filter(x=>unknownModel(x.model)&&x.inputTokens+x.outputTokens>0)){
      unknownTokens+=row.inputTokens+row.outputTokens;
      unknownReference+=officialAPICostUSD(row.inputTokens,row.cacheReadTokens??0,row.outputTokens,fallbackModel);
      unknownSources.push(clientNames[row.client]+' · '+modelPresentationDetail(row.model));
      if(((row.unpricedRequests??0)===0||row.requests>(row.unpricedRequests??0))&&row.apiCostUSD!=null)knownCosts.push(row.apiCostUSD);
    }
    const groups=new Map<string,Summary[]>();
    for(const row of selected.filter(x=>!unknownModel(x.model))){
      const key=row.client+'|'+modelPresentationIdentity(row.model).key;
      const group=groups.get(key)??[];group.push(row);groups.set(key,group);
    }
    // Sum already-priced raw contributions. Never price the merged token sum.
    for(const key of [...groups.keys()].sort()){
      const group=groups.get(key)!,identity=modelPresentationIdentity(group[0].model);
      const known=group.flatMap(r=>r.apiCostUSD==null || ((r.unpricedRequests??0)>0&&r.requests<=(r.unpricedRequests??0))?[]:[r.apiCostUSD]);
      const complete=group.every(r=>(r.unpricedRequests??0)===0&&r.apiCostUSD!=null);
      const subtotal=known.length?known.reduce((a,b)=>a+b,0):null;
      items.push({key,label:identity.label,tokens:group.reduce((n,r)=>n+r.inputTokens+r.outputTokens,0),share:0,
        costUSD:complete?subtotal:null,knownPartialCostUSD:complete?null:subtotal,
        usesIndependentQuota:false,referenceCostUSD:null,color:modelUsageColor(identity.key),
        sourceModels:[...new Set(group.map(r=>r.model))].sort()});
    }
    if(unknownTokens>0)items.push({key:'unknown-models',label:'未知模型',tokens:unknownTokens,share:0,costUSD:null,
      knownPartialCostUSD:knownCosts.length?knownCosts.reduce((a,b)=>a+b,0):null,referenceCostUSD:unknownReference,
      usesIndependentQuota:false,color:modelUsageColor('unknown'),sourceModels:[...new Set(unknownSources)].sort(),referenceModelLabel:priceModelTitle(fallbackModel)});
    const total=Math.max(1,items.reduce((n,x)=>n+x.tokens,0));return items.filter(x=>x.tokens>0).map(x=>({...x,share:x.tokens/total}));
}
export function clientCostPeriods(codex: DashboardSnapshot, snapshot: Snapshot, allowed: string[], now=Date.now()/1000):ClientCostPeriods {
  const make = (rows:Summary[], original:ModelTokenBreakdown[]) => clientModelCostItems(rows, original, allowed);
  const recentPoints=codex.recentUsage24h.filter(x=>x.startUnix>=now-7*86400&&x.startUnix<=now);
  const recent=recentPoints.flatMap(x=>x.modelBreakdowns??[]);
  const day=new Date(now*1000);day.setHours(0,0,0,0);const dayStart=day.getTime()/1000;
  const directToday=codex.usageSummary?.todayModelBreakdowns??[];
  const todayModels=directToday.length?directToday:recentPoints.filter(x=>x.startUnix>=dayStart).flatMap(x=>x.modelBreakdowns??[]);
  const codexPendingScopes:("today"|"sevenDay")[]=[];
  if(allowed.includes('codex')){
    if(!todayModels.length&&(codex.usageSummary?.todayTokens??0)>0)codexPendingScopes.push('today');
    if(!recent.length&&recentPoints.some(x=>x.tokens>0))codexPendingScopes.push('sevenDay');
  }
  return {lifetime:make(snapshot.summaries,codex.stats.modelBreakdowns??[]),today:make(snapshot.todaySummaries??[],todayModels),sevenDay:make(snapshot.sevenDaySummaries??[],recent),codexPendingScopes};
}

/** Source adapter for the existing cards and charts. Never writes source data. */
export function projectOriginalDashboard(codex:DashboardSnapshot, snapshot:Snapshot, allowed:string[]):DashboardSnapshot {
  if(allowed.length===1&&allowed[0]==='codex') return codex;
  const includes=allowed.includes('codex'),rows=snapshot.summaries.filter(x=>allowed.includes(x.client));
  const trend=(snapshot.trendBuckets??[]).filter(x=>allowed.includes(x.client));
  const stats={...codex.stats};
  stats.totalTokens=(includes?codex.stats.totalTokens:0)+rows.reduce((n,x)=>n+x.inputTokens+x.outputTokens,0);
  stats.totalInputTokens=(includes?codex.stats.totalInputTokens??0:0)+rows.reduce((n,x)=>n+x.inputTokens,0);
  stats.totalOutputTokens=(includes?codex.stats.totalOutputTokens??0:0)+rows.reduce((n,x)=>n+x.outputTokens,0);
  stats.totalCachedInputTokens=(includes?codex.stats.totalCachedInputTokens??0:0)+rows.reduce((n,x)=>n+(x.cacheReadTokens??0),0);
  stats.totalCalls=(includes?codex.stats.totalCalls:0)+rows.reduce((n,x)=>n+x.requests,0);
  stats.totalThreads=0;stats.peakThreadTokens=0;
  stats.modelBreakdowns=(includes?codex.stats.modelBreakdowns??[]:[]).concat(rows.map(x=>({model:clientNames[x.client]+' · '+x.model,breakdown:{inputTokens:x.inputTokens,cachedInputTokens:x.cacheReadTokens??0,outputTokens:x.outputTokens,totalTokens:x.inputTokens+x.outputTokens,calls:x.requests}})));
  const complete=new Set<string>(rows.filter(x=>x.cacheReadComplete).map(x=>x.client));
  rows.filter(x=>!x.cacheReadComplete).forEach(x=>complete.delete(x.client));
  const recordedDays=projectClientDays(codex.activityDays,(snapshot.dailyBuckets??[]).map(row =>
    complete.has(row.client) ? row : {...row, cacheReadTokens: null}),allowed);
  const recordedByDate=new Map(recordedDays.map(x=>[x.date,x]));
  const endDate=new Date(snapshot.updatedAt??codex.generatedAt);endDate.setHours(12,0,0,0);
  const activityDays=Array.from({length:365},(_,index)=>{const date=new Date(endDate);date.setDate(date.getDate()+index-364);const key=`${date.getFullYear()}-${String(date.getMonth()+1).padStart(2,'0')}-${String(date.getDate()).padStart(2,'0')}`;return recordedByDate.get(key)??{date:key,tokens:0,calls:0,cacheHitRate:0,fiveHourRemainingPercent:null,sevenDayRemainingPercent:null};});
  stats.peakDayTokens=Math.max(0,...activityDays.map(x=>x.tokens));stats.longestStreakDays=0;stats.currentStreakDays=0;
  let run=0,last:string|undefined;
  for(const day of activityDays.filter(x=>x.tokens>0)) {
    const previous=last?new Date(last+'T12:00:00'):undefined;
    if(previous)previous.setDate(previous.getDate()+1);
    run=previous&&`${previous.getFullYear()}-${String(previous.getMonth()+1).padStart(2,'0')}-${String(previous.getDate()).padStart(2,'0')}`===day.date?run+1:1;
    stats.longestStreakDays=Math.max(stats.longestStreakDays,run);last=day.date;
  }
  if(last){const today=new Date();today.setHours(12,0,0,0);const diff=Math.round((today.getTime()-new Date(last+'T12:00:00').getTime())/86400000);if(diff<=1)stats.currentStreakDays=run;}

  function points(width:number, original:RecentUsagePoint[]) {
    const sums=new Map<number,RecentUsagePoint>(), unknown=new Set<number>();
    function add(t:number,tokens:number,calls:number,input:number,cached:number,output:number,known:boolean){
      const key=Math.floor(t/width)*width;
      const old=sums.get(key)??{startUnix:key,label:new Date(key*1000).toISOString(),tokens:0,calls:0,inputTokens:0,cachedInputTokens:0,outputTokens:0,cacheHitRate:null,fiveHourRemainingPercent:null,sevenDayRemainingPercent:null};
      old.tokens+=tokens;old.calls+=calls;old.inputTokens+=input;old.cachedInputTokens+=cached;old.outputTokens+=output;
      if(!known&&input>0)unknown.add(key);sums.set(key,old);
    }
    if(includes)original.forEach(x=>{
      add(x.startUnix,x.tokens,x.calls,x.inputTokens,x.cachedInputTokens,x.outputTokens,x.cacheHitRate!==null);
      const key=Math.floor(x.startUnix/width)*width, point=sums.get(key)!;
      // Provider history remains a labeled overlay, never a sum of percentages.
      point.fiveHourRemainingPercent=x.fiveHourRemainingPercent;
      point.sevenDayRemainingPercent=x.sevenDayRemainingPercent;
      point.fiveHourCycleId=x.fiveHourCycleId; point.sevenDayCycleId=x.sevenDayCycleId;
      point.modelBreakdowns=[...(point.modelBreakdowns??[]),...(x.modelBreakdowns??[])];
    });
    trend.forEach(x=>add(x.startUnix,x.inputTokens+x.outputTokens,x.requests,x.inputTokens,x.cacheReadTokens??0,x.outputTokens,complete.has(x.client)&&x.cacheReadTokens!==null));
    if(!sums.size)return [];
    const now=Math.max(Date.parse(codex.generatedAt)/1000,Date.parse(snapshot.updatedAt??codex.generatedAt)/1000);
    const last=Math.floor(now/width)*width, first=Math.max(Math.min(...sums.keys()),last-30*86400);
    const result:RecentUsagePoint[]=[];
    for(let key=first;key<=last;key+=width){const x=sums.get(key)??{startUnix:key,label:new Date(key*1000).toISOString(),tokens:0,calls:0,inputTokens:0,cachedInputTokens:0,outputTokens:0,cacheHitRate:null,fiveHourRemainingPercent:null,sevenDayRemainingPercent:null};result.push({...x,cacheHitRate:unknown.has(key)||x.inputTokens<=0?null:x.cachedInputTokens/x.inputTokens});}
    return result;
  }
  const todayRows=(snapshot.todaySummaries??[]).filter(x=>allowed.includes(x.client));
  const todayTokens=(includes?codex.usageSummary?.todayTokens??0:0)+todayRows.reduce((n,x)=>n+x.inputTokens+x.outputTokens,0);
  return {...codex,stats,activityDays,recentUsage24h:points(300,codex.recentUsage24h),recentUsage7d:points(3600,codex.recentUsage7d),recentUsage30d:points(21600,codex.recentUsage30d),
    cacheUsage:includes?codex.cacheUsage:{sessions:[],turns:[]},cacheHitRanking:includes?codex.cacheHitRanking:[],
    attributionIdentity:null,preciseRecentUsageFresh:true,
    usageSummary:{...(codex.usageSummary??{}),totalTokens:stats.totalTokens,todayTokens,todayRequests:(includes?codex.usageSummary?.todayRequests??0:0)+todayRows.reduce((n,x)=>n+x.requests,0),todayModelBreakdowns:[]},usageSummaryFresh:true,
    warnings:includes?codex.warnings:[]};
}
