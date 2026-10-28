import { useSyncExternalStore } from "react";
import { callCommandStrict } from "../../api/command";
import { isTauriRuntimeAvailable } from "../../platform/runtime";
import type { AgentSpeedReportingStatus } from "./AgentSpeedReporting";

const initial: AgentSpeedReportingStatus = {
  enabled:false, transport:"http", invitationHandled:true, username:"", phase:"off", message:"未参加 · 采集与上报已关闭",
  liveOutputTps:0, estimatedShare:0, lastReportAt:null, profileUrl:null, sources:[],
};
let current=initial, timer:ReturnType<typeof setTimeout>|undefined, pending=false, revision=0;
const listeners=new Set<()=>void>();
export function publishAgentSpeedStatus(next:AgentSpeedReportingStatus) {
  current=next; revision+=1; for (const listener of listeners) listener();
}
async function poll() {
  if (!listeners.size || pending || !isTauriRuntimeAvailable()) return;
  pending=true;
  const before=revision;
  try { const next=await callCommandStrict<AgentSpeedReportingStatus>("read_agent_speed_reporting_status"); if(revision===before) publishAgentSpeedStatus(next); }
  catch { if(revision===before && current.enabled) publishAgentSpeedStatus({...current,phase:"error",message:"无法读取本地上报状态，请重试"}); }
  finally {
    pending=false;
    if(listeners.size) timer=setTimeout(()=>void poll(),document.hidden?30_000:5_000);
  }
}
function resumeVisible() {
  if(!document.hidden) { clearTimeout(timer); void poll(); }
}
function subscribe(listener:()=>void) {
  listeners.add(listener);
  if(listeners.size===1 && isTauriRuntimeAvailable()) {
    document.addEventListener("visibilitychange",resumeVisible); void poll();
  }
  return ()=>{
    listeners.delete(listener);
    if(!listeners.size) { clearTimeout(timer); document.removeEventListener("visibilitychange",resumeVisible); }
  };
}
export function useAgentSpeedStatus() {
  return useSyncExternalStore(subscribe,()=>current,()=>initial);
}
