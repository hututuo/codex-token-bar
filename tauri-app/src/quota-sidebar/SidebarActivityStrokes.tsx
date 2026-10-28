import type { ReactNode } from "react";
import { modelRateSlices } from "../components/liveRate/modelRatePresentation";
import type { sidebarRingResetTime } from "./detailsModel";

function ModelRateRingSegments({ rates, fraction }: { rates: import("../types/live").ModelRateContribution[]; fraction: number }) {
  const slices = modelRateSlices(rates.length ? rates : [{ model: "unknown", tokensPerSecond: 1 }]);
  const amount = Math.min(1, Math.max(0, fraction));
  if (!slices.length || amount <= 0) return null;
  let edge = 0;
  const endAngle = amount * Math.PI * 2 - Math.PI / 2;
  return <>
    {slices.map(slice => {
      const offset = edge; edge += slice.share;
      return <circle key={slice.model} cx="26" cy="26" r="22" fill="none" stroke={slice.color} strokeWidth="4" strokeLinecap="butt"
        strokeDasharray={`${138.23 * slice.share * amount} 138.23`} strokeDashoffset={-138.23 * offset * amount} transform="rotate(-90 26 26)"/>;
    })}
    {amount < 1 && <><circle cx="26" cy="4" r="2" fill={slices[0].color}/><circle cx={26 + Math.cos(endAngle) * 22} cy={26 + Math.sin(endAngle) * 22} r="2" fill={slices.at(-1)!.color}/></>}
  </>;
}

export function SidebarActivityRing({ label, percent, color, expected, reset, modelRates, morphID }: { morphID?: string; label: string; percent: number | null; color: string; modelRates?: import("../types/live").ModelRateContribution[]; expected?: number | null; reset?: ReturnType<typeof sidebarRingResetTime> }) {
  const title = [reset === null ? "重置时间未知" : reset?.title, expected != null ? `白线为均匀使用参考：预期剩余 ${Math.round(expected * 100)}%` : null].filter(Boolean).join("；");
  let offset=0;
  const segments=modelRates?modelRateSlices(modelRates.length?modelRates:[{model:"unknown",tokensPerSecond:1}]).map(slice=>{const start=offset;offset+=slice.share;return {id:slice.model,start,end:offset,color:slice.color};}):undefined;
  return <div className="qs-ring" data-known={percent !== null} title={title || undefined}><svg viewBox="0 0 52 52" aria-hidden="true" data-sidebar-stroke-source={morphID ? "" : undefined} data-stroke-inset={4/52} data-stroke-spec={JSON.stringify([{id:morphID,fraction:percent === null?null:percent/100,color,segments,trackColor:"#2d332e",trackOpacity:1,width:4*49/52}])}><circle cx="26" cy="26" r="22" className="qs-track" />{modelRates ? <ModelRateRingSegments rates={modelRates} fraction={(percent ?? 0) / 100}/> : <circle cx="26" cy="26" r="22" fill="none" stroke={color} strokeWidth="4" strokeLinecap="round" className="qs-ring-value" strokeDasharray="138.23" strokeDashoffset={138.23 * (1 - (percent ?? 0) / 100)} transform="rotate(-90 26 26)" />}{expected != null && <line className="qs-pace-tick" x1="26" y1="0" x2="26" y2="8" transform={`rotate(${expected * 360} 26 26)`} />}</svg><span className={reset !== undefined ? "qs-ring-center" : undefined}><span>{label}</span>{reset !== undefined && (reset ? <time className="qs-ring-reset" dateTime={reset.dateTime} aria-label={reset.title}><span>{reset.date}</span><span>{reset.time}</span></time> : <small className="qs-ring-reset-unknown">重置未知</small>)}</span></div>;
}

export function SidebarTaskRing({children}:{children:ReactNode}) {
  return <span className="qs-task-ring"><i className="qs-task-stroke" data-sidebar-stroke-source="" data-stroke-inset={1/49}
    data-stroke-spec={JSON.stringify([{id:"tasks",fraction:1,color:"#efc077",fillOpacity:.5,trackOpacity:0,width:2}])}/>{children}</span>;
}

export function SidebarModelShareStrip({models,title}:{models:readonly {key:string;share:number;color:string}[];title:string}) {
  let offset=0;
  const segments=models.map(item=>{const start=offset;offset+=item.share;return {id:item.key,start,end:offset,color:item.color};});
  return <div className="qs-model-strip" title={title} aria-label={title} data-sidebar-stroke-source=""
    data-stroke-spec={JSON.stringify([{id:"models",shape:"strip",fraction:1,color:"#888",segments}])}>
    {models.map(item=><i key={item.key} style={{flexGrow:item.share,background:item.color}}/>)}</div>;
}
