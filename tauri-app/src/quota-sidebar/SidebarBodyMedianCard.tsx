import type { ModelSpeedSummary } from "../types/live";
import { memo, useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useDocumentVisible } from "../components/useDocumentVisible";
import { modelUsageColor } from "../components/modelUsagePresentation";
import type { SpeedTrendPoint } from "../components/liveRate/BodySpeedTrend";
import type { CodexHomeSourceToken } from "../types/platform";
import { medianBounds, medianInterval, medianSegments, sidebarBodyMedian, type MedianSnapshot, type MedianSeries } from "./sidebarBodyMedian";

interface Props { latest?:ModelSpeedSummary[]; sourceToken?: CodexHomeSourceToken|null; active: boolean; onOpen:()=>void }
/** One serial, cancellable polling loop while the rail is visible. Source keys
 * fence all late responses; high-frequency live snapshots do not restart it. */
export function SidebarBodyMedian({latest=[],sourceToken,active,onOpen}:Props) {
  const visible=useDocumentVisible(),key=JSON.stringify(sourceToken??null);
  const [result,setResult]=useState<{key:string;snapshot:MedianSnapshot|null;error:string|null}|null>(null);
  useEffect(()=>{
    if(!sourceToken||!active||!visible)return;
    let disposed=false;let timer:ReturnType<typeof window.setTimeout>|undefined;
    const read=async()=>{
      try {
        const result=await invoke<{points:SpeedTrendPoint[];asOf:number}>("read_sidebar_body_speed_buckets",{sourceToken});
        if(!disposed)setResult({key,snapshot:sidebarBodyMedian(result.points,result.asOf),error:null});
      }catch{if(!disposed)setResult({key,snapshot:null,error:"读取失败"});}
      if(!disposed)timer=window.setTimeout(()=>void read(),60_000);
    };
    // Avoid reads for accidental pointer passes; never perform IO on each frame.
    timer=window.setTimeout(()=>void read(),150);
    return()=>{disposed=true;if(timer!==undefined)window.clearTimeout(timer);};
  },[key,active,visible]);
  return <SidebarBodyMedianContent latest={latest} snapshot={result?.key===key?result.snapshot:null} error={result?.key===key?result.error:null} onOpen={onOpen}/>;
}
const description=(series:MedianSeries,end:number)=>series.model+" · "+series.slots.map((p,i)=>
  `${medianInterval(end-(5-i)*1800)} ${p?`中位数 ${p.median.toFixed(1)} TPS，${p.bucketCount}桶、${p.sampleCount}段正文`:"采样不足"}`).join("；")+"。各模型纵轴独立；缺样本不连线。";
export const SidebarBodyMedianContent=memo(function SidebarBodyMedianContent({snapshot,latest=[],error,onOpen}:{snapshot:MedianSnapshot|null;latest?:ModelSpeedSummary[];error:string|null;onOpen:()=>void}) {
  return <div className="qs-median-speeds"><button type="button" onClick={onOpen} title="最近3小时，每半小时一个中位数；当前未满区间不计。点击查看测速记录">
    <span className="qs-median-title">正文 TPS</span><span className="qs-median-caption">中位数 · 近3小时</span>
    {error&&<span className="qs-median-error" role="status">{error}</span>}
    {latest.length?latest.map(reading=>{
      const series=snapshot?.series.find(s=>s.model===reading.model);
      const current=series?.slots.at(-1),color=modelUsageColor(reading.model),bounds=series?medianBounds(series):{low:0,high:10};
      const x=(i:number)=>2+(i+.5)/6*62,y=(v:number)=>29-(v-bounds.low)/(bounds.high-bounds.low)*26;
      return <span className="qs-model-speed-block qs-median-model" key={reading.model} title={series?description(series,snapshot!.end):`${reading.model} 最新 ${reading.tokensPerSecond.toFixed(1)} TPS`}>
        <span className="qs-median-name"><i style={{background:color}}/>{reading.model.replace(/^gpt-/,"")}</span>
        <span className="qs-median-value"><b>{reading.tokensPerSecond.toFixed(1)}</b><small>最新</small></span>
        <svg viewBox="0 0 66 32" className="qs-median-line" aria-hidden="true">
          {(series?medianSegments(series):[]).map((part,i)=><g key={i}><polyline points={part.map(p=>`${x(p.index)},${y(p.point.median)}`).join(" ")} fill="none" stroke={color} strokeWidth="1.4" strokeLinejoin="round"/>{part.map(p=><circle key={p.index} cx={x(p.index)} cy={y(p.point.median)} r="1.5" fill={color}/>)}</g>)}
          {series?.slots.map((p,i)=>p?null:<line key={i} x1={x(i)-1.5} x2={x(i)+1.5} y1="30" y2="30" stroke="#ffffff50"/>)}
        </svg><span className="qs-median-time">中位 {current?current.median.toFixed(1):"—"}</span>
      </span>;
    }):<span className="qs-median-caption">等待采样</span>}
  </button></div>;
});
