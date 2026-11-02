import { useEffect, useRef, useState, type ReactNode } from "react";
import { callCommandStrict } from "../api/command";
import { isTauriRuntimeAvailable } from "../platform/runtime";
import { listen } from "@tauri-apps/api/event";
import { BusinessRecoveryActions } from "./BusinessRecoveryActions";

export interface BusinessStartupState { phase:"preparing"|"ready"|"error"; message:string|null }
interface BusinessStartupViewState extends BusinessStartupState { statusReadFailed?:boolean }
export function BusinessStartupScreen({state,onRetry,retryLabel="重试账本准备"}:{state:BusinessStartupViewState;onRetry:()=>void|Promise<void>;retryLabel?:string}) {
  return <section className="business-startup" role={state.phase === "error"?"alert":"status"}>
    <h2>Codex Token Bar</h2>
    <strong>{state.statusReadFailed?"无法读取账本准备状态":state.phase === "error"?"账本准备未完成":"正在准备本地账本"}</strong>
    {state.phase !== "error" && <progress aria-label="本地账本准备进度"/>}
    <p className="business-startup-message" tabIndex={0} aria-label="账本准备详情">{state.message || "首次升级可能需要几分钟，正在后台备份并核对旧账本。完成后自动进入主页。"}</p>
    <p>{state.statusReadFailed?"确认账本状态后再加载此窗口。":"原始账本和备份保留，准备完成前暂停业务写入。"}</p>
    {state.statusReadFailed
      ? <button type="button" onClick={onRetry}>重新读取</button>
      : <BusinessRecoveryActions onRetry={onRetry} retryLabel={retryLabel} preparing={state.phase === "preparing"}/>}
  </section>;
}
export function BusinessStartupGate({children}:{children:ReactNode}) {
  const runtime=typeof window !== "undefined" && isTauriRuntimeAvailable();
  const mainWindow=typeof window === "undefined" || (new URLSearchParams(window.location.search).get("surface") ?? "main") === "main";
  const [state,setState]=useState<BusinessStartupViewState>({phase:runtime?"preparing":"ready",message:null});
  const latestState=useRef(state); latestState.current=state;
  const retry=useRef<()=>void|Promise<void>>(()=>{});
  useEffect(()=>{
    if(!runtime) return;
    let disposed=false, actionPending=false, generation=0, timer:ReturnType<typeof setTimeout>|undefined;
    let unlisten:(()=>void)|undefined;
    async function read(token:number,command="read_business_startup_state") {
      try {
        const next=await callCommandStrict<BusinessStartupState>(command);
        if(disposed || token!==generation) return;
        if(next.phase !== "preparing") actionPending=false;
        setState(next);
        if(next.phase === "preparing") timer=setTimeout(()=>void read(token),1000);
      } catch(error) {
        if(!disposed && token===generation) {
          actionPending=false;
          setState({phase:"error",message:String(error),statusReadFailed:true});
        }
      }
    }
    retry.current=()=>{
      if(actionPending) return;
      if(!latestState.current.statusReadFailed && !mainWindow) {
        void callCommandStrict("show_dashboard_window").catch(error=>{
          if(!disposed) setState(previous=>({...previous,message:String(error)}));
        });
        return;
      }
      const command=latestState.current.statusReadFailed?"read_business_startup_state":"retry_business_startup";
      actionPending=true;
      clearTimeout(timer); generation+=1;
      setState({phase:"preparing",message:null}); return read(generation,command);
    };
    void read(generation);
    const release=(stop:()=>void)=>{try{void Promise.resolve(stop()).catch(()=>{});}catch{/* Already disposed. */}};
    void listen<BusinessStartupState>("business-startup-state-changed",event=>{
      if(disposed) return;
      if(event.payload.phase !== "preparing") actionPending=false;
      clearTimeout(timer); generation+=1; setState(event.payload);
      if(event.payload.phase === "preparing") void read(generation);
    }).then(stop=>{if(disposed)release(stop);else unlisten=stop;}).catch(()=>{});
    return ()=>{disposed=true;generation+=1;clearTimeout(timer);retry.current=()=>{};if(unlisten)release(unlisten);};
  },[runtime,mainWindow]);
  return state.phase === "ready"?<>{children}</>:<BusinessStartupScreen state={state} onRetry={()=>retry.current()} retryLabel={mainWindow?"重试账本准备":"打开主窗口重试"}/>;
}
