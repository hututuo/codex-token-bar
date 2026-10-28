import { useEffect, useRef, useState, type ReactNode } from "react";
import { callCommandStrict } from "../api/command";
import { isTauriRuntimeAvailable } from "../platform/runtime";
import { listen } from "@tauri-apps/api/event";

export interface BusinessStartupState { phase:"preparing"|"ready"|"error"; message:string|null }
export function BusinessStartupScreen({state,onRetry}:{state:BusinessStartupState;onRetry:()=>void}) {
  return <section className="business-startup" role={state.phase === "error"?"alert":"status"}>
    <h2>Codex Token Bar</h2>
    <strong>{state.phase === "error"?"账本准备未完成":"正在准备本地账本"}</strong>
    {state.phase !== "error" && <progress aria-label="本地账本准备进度"/>}
    <p>{state.message || "首次升级可能需要几分钟，正在后台备份并核对旧账本。完成后自动进入主页。"}</p>
    <p>原始账本和备份保留，准备完成前暂停业务写入。</p>
    {state.phase === "error" && <button type="button" onClick={onRetry}>重试</button>}
  </section>;
}
export function BusinessStartupGate({children}:{children:ReactNode}) {
  const runtime=typeof window !== "undefined" && isTauriRuntimeAvailable();
  const [state,setState]=useState<BusinessStartupState>({phase:runtime?"preparing":"ready",message:null});
  const retry=useRef<()=>void>(()=>{});
  useEffect(()=>{
    if(!runtime) return;
    let disposed=false, generation=0, timer:ReturnType<typeof setTimeout>|undefined;
    let unlisten:(()=>void)|undefined;
    async function read(token:number,command="read_business_startup_state") {
      try {
        const next=await callCommandStrict<BusinessStartupState>(command);
        if(disposed || token!==generation) return;
        setState(next);
        if(next.phase === "preparing") timer=setTimeout(()=>void read(token),1000);
      } catch(error) {
        if(!disposed && token===generation) setState({phase:"error",message:String(error)});
      }
    }
    retry.current=()=>{
      clearTimeout(timer); generation+=1;
      setState({phase:"preparing",message:null}); void read(generation,"retry_business_startup");
    };
    void read(generation);
    void listen<BusinessStartupState>("business-startup-state-changed",event=>{
      if(disposed) return;
      clearTimeout(timer); generation+=1; setState(event.payload);
      if(event.payload.phase === "preparing") void read(generation);
    }).then(stop=>{if(disposed)stop();else unlisten=stop;}).catch(()=>{});
    return ()=>{disposed=true;generation+=1;clearTimeout(timer);retry.current=()=>{};unlisten?.();};
  },[runtime]);
  return state.phase === "ready"?<>{children}</>:<BusinessStartupScreen state={state} onRetry={()=>retry.current()}/>;
}
