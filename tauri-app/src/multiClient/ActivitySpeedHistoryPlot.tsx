import {memo,useId,useMemo,useState} from "react";
import {activityChartPoints,type ActivityTrendPoint} from "./activitySpeedChart";
import {modelUsageColor} from "../components/modelUsagePresentation";
import {useSpeedPalette} from "../components/liveRate/useSpeedPalette";
import {activityRateText,activityRateValue,type ActivityRateUnit} from "../components/liveRate/activityRatePresentation";
export interface ActivityHistorySeries {
  dimensions:{client:string;model:string;displayMode:string;sourceIdentity?:string;estimatorId?:string;estimatorVersion?:string;metricKind?:string};
  halfMinuteTrend?:ActivityTrendPoint[];
}
/** The dashboard and third-level activity-rate section share this numeric-only plot. */
export const ActivitySpeedHistoryPlot=memo(function ActivitySpeedHistoryPlot({rows,asOf,windowSeconds=43200,unit="tok/s",fx=7.2}:{rows:ActivityHistorySeries[];asOf:number;windowSeconds?:number;unit?:ActivityRateUnit;fx?:number}){
  const palette=useSpeedPalette(),clipId=useId();
  const [selectedBucket,setSelectedBucket]=useState<number|null>(null);
  const start=asOf-windowSeconds,left=44,right=785,top=16,bottom=160;
  const prepared=useMemo(()=>rows.filter(row=>row.dimensions.displayMode==="agentSpeed").flatMap(row=>{
    const rawPoints=activityChartPoints(row.halfMinuteTrend??[],asOf,windowSeconds,30);
    if(!rawPoints.length)return [];
    const factor=activityRateValue(1,[{model:row.dimensions.model,tokensPerSecond:1}],unit,fx);
    return [{row,key:JSON.stringify(row.dimensions),missingPrice:factor===null,points:factor===null?[]:rawPoints.map(p=>({...p,value:p.rate*factor}))}];
  }),[rows,asOf,windowSeconds,unit,fx]);
  const maximum=useMemo(()=>Math.max(unit==="tok/s"?1:.0001,prepared.reduce((max,s)=>s.points.reduce((value,p)=>Math.max(value,p.value*1.12),max),0)),[prepared,unit]);
  const markAllPoints=useMemo(()=>prepared.reduce((n,s)=>n+s.points.length,0)<=1500,[prepared]);
  const x=(t:number)=>left+(t-start)/windowSeconds*(right-left),y=(v:number)=>bottom-v/maximum*(bottom-top);
  const curves=useMemo(()=>prepared.map(({row,key,points})=>{
    let previous:number|undefined;
    const path=points.map(p=>{const command=previous===p.segment?"L":"M";previous=p.segment;return `${command}${x(p.bucketStart)},${y(p.value)}`;}).join(" ");
    const color=modelUsageColor(row.dimensions.model);
    return <g key={key} data-activity-model={row.dimensions.model}><path d={path} fill="none" stroke={color} strokeWidth="1.4"/>{points.filter((p,index)=>markAllPoints||(points[index-1]?.segment!==p.segment&&points[index+1]?.segment!==p.segment)).map(p=><circle key={p.bucketStart} cx={x(p.bucketStart)} cy={y(p.value)} r="1.35" fill={color}><title>{`${new Date(p.bucketStart*1000).toLocaleString("zh-CN")} · ${row.dimensions.model} · ${activityRateText(p.value,unit)} ${unit}`}</title></circle>)}</g>;
  }),[prepared,start,windowSeconds,maximum,unit,palette,markAllPoints]);
  const selected=selectedBucket===null?[]:prepared.flatMap(s=>s.points.filter(p=>p.bucketStart===selectedBucket).map(p=>({row:s.row,...p})));
  const time=(stamp:number)=>new Date(stamp*1000).toLocaleTimeString("zh-CN",{hour:"2-digit",minute:"2-digit",hour12:false});
  return <div className="activity-history-plot">
    <svg viewBox="0 0 800 188" role="img" aria-label={`${windowSeconds===86400?"全天":"近12小时"}活动速率，每30秒一个点`} style={{width:"100%",display:"block"}} onPointerLeave={()=>setSelectedBucket(null)} onPointerMove={event=>{
      const bounds=event.currentTarget.getBoundingClientRect();if(!bounds.width)return;
      const coordinate=(event.clientX-bounds.left)/bounds.width*800;
      setSelectedBucket(coordinate<left||coordinate>right?null:Math.floor((start+(coordinate-left)/(right-left)*windowSeconds)/30)*30);
    }}>
      <defs><clipPath id={clipId}><rect x={left} y={top} width={right-left} height={bottom-top}/></clipPath></defs>
      {[0,.5,1].map(f=><g key={f}><line x1={left} x2={right} y1={y(maximum*f)} y2={y(maximum*f)} stroke="currentColor" opacity=".1"/><text x={left-7} y={y(maximum*f)+3} textAnchor="end" fill="currentColor" opacity=".7" fontSize="10">{activityRateText(maximum*f,unit)}</text></g>)}
      {[0,1,2,3,4].map(tick=><text key={tick} x={left+(right-left)*tick/4} y="181" textAnchor={tick===0?"start":tick===4?"end":"middle"} fontSize="10" fill="currentColor" opacity=".75">{time(start+windowSeconds*tick/4)}</text>)}
      {!prepared.some(s=>s.points.length)&&<text x="410" y="90" textAnchor="middle" fill="currentColor" opacity=".6" fontSize="11">暂无 Agent Speed 活动速率记录</text>}
      <g clipPath={`url(#${clipId})`}>{curves}{selectedBucket!==null&&selected.length>0&&<line x1={x(selectedBucket)} x2={x(selectedBucket)} y1={top} y2={bottom} stroke="currentColor" opacity=".4" strokeDasharray="3 3"/>}</g>
    </svg>
    <div className="activity-history-legend">{[...new Set(prepared.map(({row})=>row.dimensions.model))].sort().map(model=><span key={model} style={{color:modelUsageColor(model)}}><i/>{model.replace(/^gpt-/,"")}</span>)}</div>
    <div style={{minHeight:22,fontSize:10,fontVariantNumeric:"tabular-nums"}} aria-live="polite">{selectedBucket===null?"悬停查看每30秒平均速率":selected.length?selected.map(p=><span key={JSON.stringify(p.row.dimensions)} style={{display:"block",color:modelUsageColor(p.row.dimensions.model)}}>{new Date(p.bucketStart*1000).toLocaleTimeString("zh-CN",{hour12:false})} · {p.row.dimensions.model.replace(/^gpt-/,"")} · {activityRateText(p.value,unit)} {unit}</span>):"该时段没有活动采样"}</div>
    {prepared.some(s=>s.missingPrice)&&<small>部分模型缺少输出单价，未换算该模型。</small>}
  </div>;
});
