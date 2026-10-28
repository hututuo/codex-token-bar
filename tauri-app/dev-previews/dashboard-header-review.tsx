import React,{useMemo,useState} from 'react';
import {createRoot} from 'react-dom/client';
import {DashboardHeader} from '../src/components/DashboardHeader';
import {ClientScopeButtons} from '../src/multiClient/ClientScopeControls';
import {AgentSpeedReportingNotice,type AgentSpeedReportingStatus} from '../src/components/settings/AgentSpeedReporting';
import {QuotaStrip} from '../src/components/QuotaStrip';
import {StatsStrip} from '../src/components/StatsStrip';
import {clientCostPeriods} from '../src/multiClient/originalDashboardProjection';
import {defaultClientPreferences} from '../src/multiClient/MultiClientUsage';
import type {DashboardSnapshot,QuotaSnapshot} from '../src/types/dashboard';
import local from './dashboard-header.local.json';
import '../src/styles/global.css';
import '../src/multiClient/integratedClients.css';

// This development host mounts production components against a private,
// read-only local snapshot. No collectors, desktop RPC or reporter is started.
const nop=()=>{},done=async()=>{};
const captured=Date.parse(local.capturedAt)/1000;
const observedReporting:AgentSpeedReportingStatus={enabled:true,transport:'http',invitationHandled:true,username:'',phase:'running',message:'已参加 · 统计已上报',liveOutputTps:0,estimatedShare:0,lastReportAt:'2026-10-28T09:17:23Z',profileUrl:null,sources:[]};
const knownClients=[...new Set(local.clients.map(row=>row.client))];
const sum=(rows:typeof local.codexRows)=>rows.reduce((total,row)=>total+row.breakdown.totalTokens,0);
const codex={generatedAt:local.capturedAt,stats:{totalTokens:sum(local.codexRows),totalCalls:local.codexRows.reduce((n,r)=>n+r.breakdown.calls,0),...local.codexMetrics,peakThreadTokens:0,totalThreads:0,modelBreakdowns:local.codexRows},usageSummary:{todayModelBreakdowns:local.codexRows.filter(r=>r.eventStartUnix>=captured-86400)},recentUsage24h:local.codexRows.filter(r=>r.eventStartUnix>=captured-7*86400).map(row=>({startUnix:row.eventStartUnix,modelBreakdowns:[row]}))} as unknown as DashboardSnapshot;
const snapshot={preferences:defaultClientPreferences,summaries:local.clients,todaySummaries:local.todayClients,sevenDaySummaries:local.sevenDayClients,diagnostics:[],updatedAt:local.capturedAt};
const windows=[['5h',local.quota.five_hour_used_percent,local.quota.five_hour_resets_at],['7d',local.quota.seven_day_used_percent,local.quota.seven_day_resets_at]] as const;
const quotaItems=windows.filter(([,used])=>used!==null).map(([window,used,reset])=>({id:'codex:'+window,client:'codex',window,remaining:100-used!,resetsAt:reset?new Date(Number(reset)*1000).toISOString():null,source:'本地额度历史快照',status:''}));
const limit=(window:string)=>{const row=quotaItems.find(q=>q.window===window);return row?{label:window,availability:'measured',remainingPercent:row.remaining/100,usedPercent:1-row.remaining/100,resetsAt:row.resetsAt??'—'}:{label:window,availability:'absent',remainingPercent:null,usedPercent:null,resetsAt:'—'};};
const quota={fiveHour:limit('5h'),sevenDay:limit('7d'),paceLabel:'本地额度快照',resetCredit:{availableCount:1,status:'已读取',credits:[]}} as QuotaSnapshot;
function Review(){
 const [scope,setScope]=useState('all'),[nickname,setNickname]=useState(local.account.displayName),[cadence,setCadence]=useState(60000);
 const allowed=scope==='all'?['codex',...knownClients]:[scope];
 const costs=useMemo(()=>clientCostPeriods(codex,snapshot as never,allowed,captured),[scope]);
 const tokens=(allowed.includes('codex')?sum(local.codexRows):0)+local.clients.filter(r=>allowed.includes(r.client)).reduce((n,r)=>n+r.inputTokens+r.outputTokens,0);
 return <main className="app-shell"><section className="dashboard" style={{paddingTop:18}}>
  <p style={{fontSize:10,color:'var(--muted)',margin:'0 0 14px'}}>候选版真实组件渲染 · 本地数据快照 {new Date(local.capturedAt).toLocaleString()} · 本页不采集、不上报、不修改正式版设置</p>
  <DashboardHeader account={local.account} customAccountDisplayName={nickname} onCustomAccountDisplayNameChange={async value=>setNickname(value)}
   scopeControl={<div className="integrated-scope"><ClientScopeButtons value={scope} clients={knownClients} onChange={setScope}/></div>}
   reportingStatus={<AgentSpeedReportingNotice compact status={observedReporting} onRetry={nop} onOpenSettings={nop}/>}
   autostartStatus={{available:true,enabled:false,message:'预览'}} codexHome={{exists:true,path:'本地日志',source:'auto'}} generatedAt={local.capturedAt}
   usageSummaryFresh preciseDataFresh usageSummaryDataUpdatedAt={local.capturedAt} usageSummaryCheckedAt={local.capturedAt} aggregateCoveredAt={captured*1000}
   onCodexHomeChange={done} onCodexHomeReset={done} onCheckForUpdate={done} onExportCsv={nop} onExportPng={nop}
   onOpenProviderRepair={nop} onOpenSessionManagement={nop} onOpenSettings={nop} onRefresh={done} onToggleAutostart={nop} refreshing={false}
   appUpdateState={{kind:'idle',message:''}} threadDeleteBridgeStatus={{connected:false,debugPort:null,message:'未连接'}} autoResumeEnabled={false}/>
  {allowed.includes('codex')&&<div style={{marginTop:14}}><QuotaStrip snapshot={quota} clientItems={quotaItems} includesCodex quotaRefreshIntervalMs={cadence} onQuotaRefreshIntervalChange={async value=>setCadence(value)}/></div>}
  <div style={{marginTop:18}}><StatsStrip stats={{...codex.stats,totalTokens:tokens}} planLabel={local.account.planLabel} clientCosts={costs}/></div>
 </section></main>;
}
createRoot(document.getElementById('root')!).render(<Review/>);
