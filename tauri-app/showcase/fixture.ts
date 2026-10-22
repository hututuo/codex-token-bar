// Public, synthetic demonstration data only. No Codex Home, account, or network reads.
import {emptyFloatingPanelSnapshot} from '../src/api/fallback/liveFallback';
import {emptyAccountQuotaBundle} from '../src/api/fallback/quotaFallback';
export const now = Math.floor(Date.now()/1000);
const breakdown = (input:number, cached:number, output:number, calls=24) => ({inputTokens:input,cachedInputTokens:cached,outputTokens:output,totalTokens:input+output,calls});
export const models = [
  {model:'gpt-6.1-sol',breakdown:breakdown(1850000,1632000,128000)},
  {model:'gpt-6-luna',breakdown:breakdown(840000,720000,96000)},
  {model:'gpt-6-astra',breakdown:breakdown(420000,355000,56000)},
];
export const speeds = ['gpt-6.1-sol','gpt-6-luna','gpt-6-astra'].map((model,i)=>({model,tokensPerSecond:[48.6,83.2,39.7][i],sampleCount:[12,18,8][i],lastMeasuredAt:now-i*40,outputTokens:Math.round([48.6,83.2,39.7][i]*60),durationSeconds:60}));
export const samples = Array.from({length:10},(_,i)=>{
  const durationSeconds=[12.4,8.2,18.6,6.9,15.3,.12,9.1,11.2,4.5,7.2][i];
  const model=speeds[i%3].model;
  const outputTokens=Math.round(durationSeconds*speeds[i%3].tokensPerSecond);
  return {id:`demo-body-${i}`,threadId:`demo-session-${i%3}`,turnId:`demo-turn-000${i+1}`,itemId:`demo-message-000${i+1}`,model,startedAt:now-i*32-durationSeconds,endedAt:now-i*32,outputTokens,outputCharacters:outputTokens*3,outputBytes:outputTokens*5,chunkCount:1,durationSeconds,tokensPerSecond:outputTokens/durationSeconds,confidence:i===5?'low':'high',source:'completed_body',measurementKind:'completed_body',tokenizer:'o200k_base',bodyPhase:i%2?'final_answer':'commentary',qualityReason:i===5?'duration_too_short':null};
});
export const threads = ['优化设置面板','整理项目文档','检查窗口布局'].map((title,i)=>({id:`demo-session-${i}`,title,subtitle:'演示会话',updatedAt:new Date().toISOString(),tokensUsed:10000}));
export const snapshot:any = {...emptyFloatingPanelSnapshot,tokensPerSecond:76.4,liveRateAvailable:true,trendLabel:'额度使用平稳',totalTokensLabel:'12.8亿',todayTokensLabel:'339万',requestsLabel:'72',todayModelBreakdowns:models,fiveHourAvailability:'measured' as const,fiveHourRemainingPercent:.76,fiveHourExpectedRemainingPercent:68,fiveHourLabel:'5h 76%',sevenDayAvailability:'measured' as const,sevenDayRemainingPercent:.58,sevenDayExpectedRemainingPercent:52,sevenDayLabel:'7d 58%',resetCreditLabel:'重置卡 2',resetCreditStandaloneLabel:'重置卡 2',unreadSummary:{active:true,count:1,label:'1 个任务待查看',detail:'',source:'local'},speedSamples:samples,modelSpeeds:speeds,modelSpeeds15m:speeds,modelSpeeds30m:speeds,latestModelSpeeds30m:speeds.map(s=>({...s,sampleCount:1}))};
export const quota=emptyAccountQuotaBundle();
quota.account={displayName:'演示账号',planLabel:'Pro'};
quota.quota.fiveHour={label:'5h',availability:'measured',remainingPercent:.76,usedPercent:.24,resetsAt:new Date((now+7200)*1000).toISOString(),resetsAtUnix:now+7200};
quota.quota.sevenDay={label:'7d',availability:'measured',remainingPercent:.58,usedPercent:.42,resetsAt:new Date((now+3*86400)*1000).toISOString(),resetsAtUnix:now+3*86400};
quota.quota.resetCredit={updatedAt:new Date(now*1000).toISOString(),availableCount:2,status:'2 张可用',credits:[1,2].map(i=>({cardId:`demo-credit-${i}`,title:`演示重置卡 ${i}`,summary:"演示数据",resetType:"sevenDay",redeemStartedAt:"",source:"演示",detailNote:"模拟卡片，不可兑换",associatedUser:"演示账号",profileImageUrl:"",shortId:`demo-${i}`,status:'可用',issuedAt:new Date((now-86400*i)*1000).toISOString(),expiresAt:new Date((now+86400*(10+i))*1000).toISOString(),redeemedAt:''}))};
export const data:any={snapshot,quota,runningThreads:{total:5,mainThreads:2,subagents:3,status:'ready' as const,mainModels:[],subagentModels:[],groups:[{mainThread:{threadId:"demo-session-0",title:"优化设置面板",model:"gpt-6.1-sol",reasoningEffort:"high"},subagents:[{threadId:"demo-agent-1",title:"核对交互边界",model:"gpt-6-luna",reasoningEffort:"max"},{threadId:"demo-agent-2",title:"检查布局",model:"gpt-6-luna",reasoningEffort:"max"}]},{mainThread:{threadId:"demo-session-1",title:"整理项目文档",model:"gpt-6-astra",reasoningEffort:"high"},subagents:[{threadId:"demo-agent-3",title:"核对功能清单",model:"gpt-6-luna",reasoningEffort:"max"}]}],unassignedSubagents:[],updatedAt:new Date().toISOString(),detail:'演示数据',livenessLeaseHours:24},trend:[]};
export function points(count:number,step:number){return Array.from({length:count},(_,i)=>{
  const at=now-(count-1-i)*step;
  const fiveStart=now-10800,sevenStart=now-4*86400;
  const elapsed5=((at-fiveStart)%18000+18000)%18000;
  const elapsed7=((at-sevenStart)%604800+604800)%604800;
  const active=i%37<28;
  const input=active?Math.round(18000+Math.abs(Math.sin(i*.21)*Math.cos(i*.053))*180000):0;
  const output=active?Math.round(input*.065):0;
  const hit=i%83===0?.128:.82+.13*Math.abs(Math.sin(i*.19));
  return {label:new Date(at*1000).toISOString(),startUnix:at,tokens:input+output,calls:active?2+i%7:0,inputTokens:input,cachedInputTokens:Math.round(input*hit),outputTokens:output,cacheHitRate:active?hit:null,fiveHourRemainingPercent:1-.4*elapsed5/18000,sevenDayRemainingPercent:1-.735*elapsed7/604800,fiveHourCycleId:`demo-5h-${Math.floor((at-fiveStart)/18000)}`,sevenDayCycleId:`demo-7d-${Math.floor((at-sevenStart)/604800)}`,modelBreakdowns:[{model:'gpt-6.1-sol',breakdown:breakdown(input,Math.round(input*hit),output,active?3:0)}]};
});}
export const recent={recentUsage24h:points(288,300),recentUsage7d:points(168,3600),recentUsage30d:points(120,21600)};
export const days=Array.from({length:365},(_,i)=>({date:new Date((now-(364-i)*86400)*1000).toISOString().slice(0,10),tokens:i%11===0?0:Math.round((.2+Math.abs(Math.sin(i*.43)*Math.cos(i*.11)))*5500000),calls:i%11===0?0:40+i%190,cacheHitRate:.8+.18*Math.abs(Math.sin(i*.3)),fiveHourRemainingPercent:.7,sevenDayRemainingPercent:.5,modelBreakdowns:models}));
