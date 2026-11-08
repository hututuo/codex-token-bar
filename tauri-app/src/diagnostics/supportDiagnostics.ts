import { invoke } from "@tauri-apps/api/core";
import { isTauriRuntimeAvailable } from "../platform/runtime";

/** Numeric observation only; no command args, error prose, source path or text. */
export function recordDiagnosticProgress(progress:{completed?:number;total?:number|null;phase?:string}|null) {
  if (!progress || !isTauriRuntimeAvailable()) return;
  const count=(n:number|undefined|null)=>typeof n==="number"&&Number.isSafeInteger(n)&&n>=0?n:0;
  void invoke("record_diagnostic_progress",{completed:count(progress.completed),total:count(progress.total),
    finished:progress.phase==="complete"||progress.phase==="ready",failed:progress.phase==="failed"||progress.phase==="error"}).catch(()=>{});
}
