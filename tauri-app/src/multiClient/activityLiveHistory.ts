import type {ActivityModelRate} from './activitySpeedMode';

export interface ActivityLivePoint { time:number; rate:number; modelRates:ActivityModelRate[] }
export interface ActivityLiveSeries { client:string; points:ActivityLivePoint[] }
export const ACTIVITY_LIVE_SECONDS=180;
export const MAX_ACTIVITY_LIVE_POINTS=2048;
const clients=['codex','claudeCode','claudeDesktop','deepseek','gemini','opencode'];
/** Bounded display-only memory. No storage, commands, timers, or database access. */
export class ActivityLiveHistory {
  private rows=new Map<string,ActivityLivePoint[]>();
  private sourceKey:string|undefined;
  selectSource(key:string){if(this.sourceKey!==key){this.rows.clear();this.sourceKey=key;}}
  clear(){this.rows.clear();}
  record(time:number, available:Record<string,boolean>, rates:readonly {client:string;model:string;outputTps:number}[]){
    if(!Number.isFinite(time))return;
    for(const client of clients){
      const modelRates=rates.filter(r=>r.client===client&&Number.isFinite(r.outputTps)&&r.outputTps>1e-9).map(r=>({model:r.model,tokensPerSecond:r.outputTps}));
      const rate=modelRates.reduce((sum,r)=>sum+r.tokensPerSecond,0);
      if(!Number.isFinite(rate)||!available[client]||(!rate&&!this.rows.has(client)))continue;
      let points=this.rows.get(client)??[];
      const last=points.at(-1);
      if(last&&time<=last.time)continue;
      points=points.filter(p=>p.time>=time-ACTIVITY_LIVE_SECONDS);
      const point={time,rate,modelRates};
      points.push(point);
      // Retain original receipts, including multiple points within one second.
      if(points.length>MAX_ACTIVITY_LIVE_POINTS)points=points.slice(-MAX_ACTIVITY_LIVE_POINTS);
      this.rows.set(client,points);
    }
  }
  snapshot(now:number,allowed:readonly string[]):ActivityLiveSeries[]{
    if(!Number.isFinite(now))return [];
    return [...this.rows].filter(([client])=>allowed.includes(client)).map(([client,points])=>({client,points:points.filter(p=>p.time>=now-ACTIVITY_LIVE_SECONDS&&p.time<=now)})).filter(row=>row.points.length>0).sort((a,b)=>a.client.localeCompare(b.client));
  }
}

export function liveChartCeiling(value:number){
  if(!Number.isFinite(value)||value<=0)return 10;
  const magnitude=10**Math.floor(Math.log10(Math.max(10,value*1.12)));
  const fraction=Math.max(10,value*1.12)/magnitude;
  return ([1,1.2,1.5,2,2.5,3,4,5,6,8,10].find(step=>fraction<=step)??10)*magnitude;
}

/** Shape-preserving cubic connections. Every sample remains an exact endpoint;
 * controls stay between adjacent values, so interpolation creates no extra peaks.
 * Missing/invalid receipts split paths rather than bridge an unknown interval.
 */
export function activityLivePaths(points:readonly {time:number;value:number}[],x:(time:number)=>number,y:(value:number)=>number,baseline:number){
  const runs:{time:number;value:number}[][]=[];
  let disconnected=false;
  for(const point of points){
    if(!Number.isFinite(point.time)||!Number.isFinite(point.value)||point.value<0){disconnected=true;continue;}
    const previous=runs.at(-1)?.at(-1);
    if(disconnected||!previous||point.time-previous.time>3.5)runs.push([]);
    else if(point.time<=previous.time)continue;
    disconnected=false;
    runs.at(-1)!.push(point);
  }
  return runs.map(run=>{
    const p=run.map(point=>({x:x(point.time),y:y(point.value)}));
    const delta=p.slice(1).map((point,i)=>(point.y-p[i].y)/(point.x-p[i].x));
    const slope=p.map((_,i)=>{
      if(!delta.length)return 0;
      if(i===0)return delta[0];if(i===p.length-1)return delta.at(-1)!;
      const a=delta[i-1],b=delta[i];
      if(a*b<=0)return 0;
      const before=p[i].x-p[i-1].x,after=p[i+1].x-p[i].x;
      const w1=2*after+before,w2=after+2*before;
      return (w1+w2)/(w1/a+w2/b);
    });
    let line=`M${p[0].x},${p[0].y}`;
    for(let i=0;i<p.length-1;i++){
      const a=p[i],b=p[i+1],width=(b.x-a.x)/3;
      const clamp=(v:number)=>Math.max(Math.min(a.y,b.y),Math.min(Math.max(a.y,b.y),v));
      line+=` C${a.x+width},${clamp(a.y+slope[i]*width)} ${b.x-width},${clamp(b.y-slope[i+1]*width)} ${b.x},${b.y}`;
    }
    return {line,area:`${line} L${p.at(-1)!.x},${baseline} L${p[0].x},${baseline} Z`};
  });
}
