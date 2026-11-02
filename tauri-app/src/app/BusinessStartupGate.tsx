import { useEffect, useRef, useState, type ReactNode } from "react";
import { callCommandStrict } from "../api/command";
import { isTauriRuntimeAvailable } from "../platform/runtime";
import { listen } from "@tauri-apps/api/event";

export interface BusinessStartupState { phase:"preparing"|"ready"|"ready_with_pending_recovery"|"error"; message:string|null }
interface BusinessStartupViewState extends BusinessStartupState { statusReadFailed?:boolean }
export function BusinessStartupScreen({state,onRetry,retryLabel="重试"}:{state:BusinessStartupViewState;onRetry:()=>void;retryLabel?:string}) {
  return <section className="business-startup" role={state.phase === "error"?"alert":"status"}>
    <h2>Codex Token Bar</h2>
    <strong>{state.statusReadFailed?"无法读取账本准备状态":state.phase === "error"?"账本准备未完成":"正在准备本地账本"}</strong>
    {state.phase !== "error" && <progress aria-label="本地账本准备进度"/>}
    <p>{state.message || "首次升级可能需要几分钟，正在后台备份并核对旧账本。完成后自动进入主页。"}</p>
    <p>{state.statusReadFailed?"确认账本状态后再加载此窗口。":"原始账本和备份保留，准备完成前暂停业务写入。"}</p>
    {state.phase === "error" && <button type="button" onClick={onRetry}>{state.statusReadFailed?"重新读取":retryLabel}</button>}
  </section>;
}
export function BusinessStartupGate({children}:{children:ReactNode}) {
  const runtime=typeof window !== "undefined" && isTauriRuntimeAvailable();
  const mainWindow=typeof window === "undefined" || (new URLSearchParams(window.location.search).get("surface") ?? "main") === "main";
  const [state,setState]=useState<BusinessStartupViewState>({phase:runtime?"preparing":"ready",message:null});
  const latestState=useRef(state); latestState.current=state;
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
        if(next.phase === "preparing" || next.phase === "ready_with_pending_recovery") timer=setTimeout(()=>void read(token),next.phase === "preparing"?1000:5000);
      } catch(error) {
        if(!disposed && token===generation) setState(previous=>previous.phase === "ready_with_pending_recovery"
          ? {...previous,message:String(error),statusReadFailed:true}
          : {phase:"error",message:String(error),statusReadFailed:true});
      }
    }
    retry.current=()=>{
      if(!latestState.current.statusReadFailed && !mainWindow) {
        void callCommandStrict("show_dashboard_window").catch(error=>{
          if(!disposed) setState(previous=>({...previous,message:String(error)}));
        });
        return;
      }
      const command=latestState.current.statusReadFailed?"read_business_startup_state":"retry_business_startup";
      clearTimeout(timer); generation+=1;
      if(latestState.current.phase !== "ready_with_pending_recovery") setState({phase:"preparing",message:null});
      void read(generation,command);
    };
    void read(generation);
    void listen<BusinessStartupState>("business-startup-state-changed",event=>{
      if(disposed) return;
      clearTimeout(timer); generation+=1; setState(event.payload);
      if(event.payload.phase === "preparing" || event.payload.phase === "ready_with_pending_recovery") void read(generation);
    }).then(stop=>{if(disposed)stop();else unlisten=stop;}).catch(()=>{});
    return ()=>{disposed=true;generation+=1;clearTimeout(timer);retry.current=()=>{};unlisten?.();};
  },[runtime,mainWindow]);
  return state.phase === "ready" || state.phase === "ready_with_pending_recovery"?<>
    {state.phase === "ready_with_pending_recovery" && mainWindow && <aside className="business-recovery-notice" role="status">
      <span>旧账可读，部分恢复尚未完成；新写入暂缓。{state.message}</span>
      <button type="button" onClick={()=>retry.current()}>重试恢复</button>
    </aside>}
    {children}
  </>:<BusinessStartupScreen state={state} onRetry={()=>retry.current()} retryLabel={mainWindow?"重试":"打开主窗口重试"}/>;
}
