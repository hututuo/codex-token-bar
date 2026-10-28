import type { SpeedTrendPoint } from "../components/liveRate/BodySpeedTrend";
export interface MedianPoint { start: number; median: number; lower: number; upper: number; bucketCount: number; sampleCount: number }
export interface MedianSeries { model: string; slots: (MedianPoint | null)[] }
export interface MedianSnapshot { end: number; series: MedianSeries[] }
/** Same statistic as the home distribution: equal-weight 5m bucket rates, not
 * response-sample median or rolling average. Six completed fixed half-hours. */
export function sidebarBodyMedian(rows: SpeedTrendPoint[], now: number): MedianSnapshot {
  if (!Number.isFinite(now) || now < 0 || now >= Number.MAX_SAFE_INTEGER - 10800) return {end:0,series:[]};
  const end=Math.floor(now/1800)*1800, start=end-10800;
  const models=new Map<string,Map<number,SpeedTrendPoint>>();
  for (const row of rows) {
    if (!Number.isSafeInteger(row.bucketStart) || row.bucketStart<start || row.bucketStart>=end || row.bucketStart%300!==0 || !row.model ||
        !Number.isFinite(row.outputTokens) || row.outputTokens<=0 || !Number.isFinite(row.durationSeconds) || row.durationSeconds<=0 ||
        !Number.isSafeInteger(row.sampleCount) || row.sampleCount<=0 || !Number.isFinite(row.outputTokens/row.durationSeconds)) continue;
    let bucket=models.get(row.model);if(!bucket){bucket=new Map();models.set(row.model,bucket);}bucket.set(row.bucketStart,row);
  }
  return {end,series:[...models.keys()].sort().map(model=>({model,slots:Array.from({length:6},(_,i)=>{
    const at=start+i*1800, group=[...models.get(model)!.values()].filter(r=>r.bucketStart>=at&&r.bucketStart<at+1800);
    const count=group.reduce((n,r)=>n+r.sampleCount,0);if(group.length<3||count<6||!Number.isSafeInteger(count))return null;
    const rates=group.map(r=>r.outputTokens/r.durationSeconds).sort((a,b)=>a-b);
    const q=(p:number)=>{const k=(rates.length-1)*p,a=Math.floor(k),b=Math.ceil(k);return rates[a]+(rates[b]-rates[a])*(k-a);};
    return {start:at,median:q(.5),lower:q(.25),upper:q(.75),bucketCount:group.length,sampleCount:count};
  })}))};
}
export function medianBounds(series:MedianSeries) {
  const rows=series.slots.filter((p):p is MedianPoint=>p!==null);
  const low=rows.length?Math.min(...rows.map(p=>p.lower)):0,high=rows.length?Math.max(...rows.map(p=>p.upper)):10,pad=Math.max(5,(high-low)*.2);
  return {low:Math.max(0,Math.floor((low-pad)/5)*5),high:Math.max(10,Math.ceil((high+pad)/5)*5)};
}
export function medianInterval(end:number) {
  const fmt=(n:number)=>new Date(n*1000).toLocaleTimeString("zh-CN",{hour:"2-digit",minute:"2-digit",hour12:false});
  return `${fmt(end-1800)}–${fmt(end)}`;
}
