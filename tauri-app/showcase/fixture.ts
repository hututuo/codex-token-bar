// Owner-authorized local capture. No live reads, credentials or raw messages.
import realData from './real-data.json';
import {emptyFloatingPanelSnapshot} from '../src/api/fallback/liveFallback';
import {emptyAccountQuotaBundle} from '../src/api/fallback/quotaFallback';
import {compactQuotaLabel,expectedRemainingPercentByEvenPace} from '../src/utils/quota';
import {compactResetCreditRateBarSuffix,compactResetCreditStandaloneSuffix} from '../src/surfaces/compactPanelLabels';
import {formatTokens} from '../src/utils/format';
const captured:any=realData;
export const now=captured.capturedAtUnix;
export const capturedAtLabel=new Date(now*1000).toLocaleString('zh-CN',{timeZone:'Asia/Shanghai',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hour12:false});
export const models=captured.models;
export const samples=captured.samples;
export const threads=captured.threads;
export const speeds=captured.modelSpeeds15m;
export const officialRadar=captured.officialRadar;
export const crowdRadar=captured.crowdRadar;
export const recent=captured.recent;
export const days=captured.days;
export const quota:any={...emptyAccountQuotaBundle(),...captured.quota};
quota.quota.paceLabel=`7d 剩 ${Math.round((quota.quota.sevenDay.remainingPercent??0)*100)}%`;
export const snapshot:any={...emptyFloatingPanelSnapshot,
  tokensPerSecond:captured.activityRate??0,liveRateAvailable:captured.activityRate!==null,
  trendLabel:quota.quota.paceLabel,totalTokensLabel:formatTokens(captured.total.totalTokens),
  todayTokensLabel:formatTokens(captured.today.totalTokens),requestsLabel:String(captured.today.calls),
  todayModelBreakdowns:models,
  fiveHourAvailability:quota.quota.fiveHour.availability,fiveHourRemainingPercent:quota.quota.fiveHour.remainingPercent,
  fiveHourExpectedRemainingPercent:expectedRemainingPercentByEvenPace(quota.quota.fiveHour,now),fiveHourLabel:compactQuotaLabel(quota.quota.fiveHour),
  sevenDayAvailability:quota.quota.sevenDay.availability,sevenDayRemainingPercent:quota.quota.sevenDay.remainingPercent,
  sevenDayExpectedRemainingPercent:expectedRemainingPercentByEvenPace(quota.quota.sevenDay,now),sevenDayLabel:compactQuotaLabel(quota.quota.sevenDay),
  resetCreditRateBarLabel:compactResetCreditRateBarSuffix(quota.quota.resetCredit),resetCreditStandaloneLabel:compactResetCreditStandaloneSuffix(quota.quota.resetCredit),
  unreadSummary:{active:false,count:0,label:'未读状态未纳入快照',detail:'本页为采集时刻的统计快照',source:'pending'},
  speedSamples:samples,modelSpeeds:speeds,modelSpeeds15m:captured.modelSpeeds15m,modelSpeeds30m:captured.modelSpeeds30m,
  latestModelSpeeds30m:captured.latestModelSpeeds30m};
export const data:any={snapshot,quota,runningThreads:captured.runningThreads,
  trend:recent.recentUsage24h.map((point:any)=>({at:point.startUnix,tokens:point.tokens,five:point.fiveHourRemainingPercent,seven:point.sevenDayRemainingPercent}))};
