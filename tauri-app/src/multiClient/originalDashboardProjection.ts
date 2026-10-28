import { claudeModelIdentity, claudeModelGroups } from "../components/claudeModelPresentation";
import type { DashboardSnapshot, RecentUsagePoint, ModelTokenBreakdown } from '../types/dashboard';
import type { Snapshot, Summary } from './MultiClientUsage';
import { projectClientDays } from './integratedClientModel';
import { clientNames } from './MultiClientUsage';
import { floatingTodayModelUsageItems, type FloatingModelUsageItem, dashboardModelFamilyGroups } from '../floating/floatingModelUsage';
import { modelUsageColor } from '../components/modelUsagePresentation';

export interface ClientCostPeriods {
  lifetime: FloatingModelUsageItem[];
  today: FloatingModelUsageItem[];
  sevenDay: FloatingModelUsageItem[];
}
export function clientCostGroups(items: FloatingModelUsageItem[]) {
  const codex = items.filter(x => x.key.startsWith('codex|')).map(x => ({...x,key:x.key.slice(6)}));
  const groups: {id:string;label:string;items:FloatingModelUsageItem[]}[] = dashboardModelFamilyGroups(codex);
  for (const client of [...new Set(items.filter(x=>!x.key.startsWith('codex|')).map(x=>x.key.split('|')[0]))].sort()) {
    const rows=items.filter(x=>x.key.startsWith(client+'|'));
    if(["claudeCode","claudeDesktop"].includes(client))groups.push(...claudeModelGroups(rows,client));
    else groups.push({id:client,label:clientNames[client as keyof typeof clientNames] ?? client,items:rows});
  }
  return groups;
}
export function clientCostPeriods(codex: DashboardSnapshot, snapshot: Snapshot, allowed: string[], now=Date.now()/1000):ClientCostPeriods {
  const make = (rows:Summary[], original:ModelTokenBreakdown[]) => {
    const items:FloatingModelUsageItem[] = allowed.includes('codex') ? floatingTodayModelUsageItems(original,'gpt56Sol',{showPlaceholders:false,mergeAutoReview:false}).map(x=>({...x,key:'codex|'+x.key})) : [];
    for(const row of rows.filter(x=>allowed.includes(x.client))) items.push({key:row.client+'|'+row.model,
      label:claudeModelIdentity(row.model)?.label ?? row.model.replaceAll('-',' '),tokens:row.inputTokens+row.outputTokens,share:0,
      costUSD:(row.unpricedRequests??0)>0?null:row.apiCostUSD??null,usesIndependentQuota:false,referenceCostUSD:null,color:modelUsageColor(row.model)});
    const total=Math.max(1,items.reduce((n,x)=>n+x.tokens,0));return items.filter(x=>x.tokens>0).map(x=>({...x,share:x.tokens/total}));
  };
  const recent=codex.recentUsage24h.filter(x=>x.startUnix>=now-7*86400).flatMap(x=>x.modelBreakdowns??[]);
  return {lifetime:make(snapshot.summaries,codex.stats.modelBreakdowns??[]),today:make(snapshot.todaySummaries??[],codex.usageSummary?.todayModelBreakdowns??[]),sevenDay:make(snapshot.sevenDaySummaries??[],recent)};
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
  const recordedDays=projectClientDays(codex.activityDays,snapshot.dailyBuckets??[],allowed);
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
  const complete=new Set<string>(rows.filter(x=>x.cacheReadComplete).map(x=>x.client));
  rows.filter(x=>!x.cacheReadComplete).forEach(x=>complete.delete(x.client));
  function points(width:number, original:RecentUsagePoint[]) {
    const sums=new Map<number,RecentUsagePoint>(), unknown=new Set<number>();
    function add(t:number,tokens:number,calls:number,input:number,cached:number,output:number,known:boolean){
      const key=Math.floor(t/width)*width;
      const old=sums.get(key)??{startUnix:key,label:new Date(key*1000).toISOString(),tokens:0,calls:0,inputTokens:0,cachedInputTokens:0,outputTokens:0,cacheHitRate:null,fiveHourRemainingPercent:null,sevenDayRemainingPercent:null};
      old.tokens+=tokens;old.calls+=calls;old.inputTokens+=input;old.cachedInputTokens+=cached;old.outputTokens+=output;
      if(!known&&input>0)unknown.add(key);sums.set(key,old);
    }
    if(includes)original.forEach(x=>add(x.startUnix,x.tokens,x.calls,x.inputTokens,x.cachedInputTokens,x.outputTokens,x.cacheHitRate!==null));
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
    usageSummary:{...(codex.usageSummary??{}),totalTokens:stats.totalTokens,todayTokens,todayRequests:todayRows.reduce((n,x)=>n+x.requests,0),todayModelBreakdowns:[]},usageSummaryFresh:true,
    warnings:includes?codex.warnings:[]};
}
