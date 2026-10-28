import { useEffect,useState } from "react";
import type { ModelSpeedSummary } from "../types/live";
import { latestSidebarModelSpeeds } from "../components/liveRate/bodySpeedPresentation";
/** One deadline per expiring sample; no interval, log reads, or IPC. */
export function useRecentBodySpeeds(rows:ModelSpeedSummary[]) {
 const [now,setNow]=useState(()=>Date.now()/1000);
 const key=rows.map(r=>`${r.model}:${r.lastMeasuredAt}:${r.tokensPerSecond}:${r.sampleCount}`).join("|");
 useEffect(()=>{
  let timer:ReturnType<typeof setTimeout>|undefined,disposed=false;
  const update=()=>{
   if(disposed)return;
   const at=Date.now()/1000;setNow(at);
   const fresh=latestSidebarModelSpeeds(rows,at);
   if(fresh.length)timer=setTimeout(update,Math.max(1,Math.min(...fresh.map(r=>r.lastMeasuredAt!+1800.002))-at)*1000);
  };update();
  return()=>{disposed=true;if(timer!==undefined)clearTimeout(timer);};
 },[key]);
 return latestSidebarModelSpeeds(rows,now);
}
