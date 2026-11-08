import { useState } from "react";
import { invoke } from "@tauri-apps/api/core";

export function DiagnosticsExportButton() {
  const [busy,setBusy]=useState(false),[message,setMessage]=useState("");
  async function exportBundle() {
    if(busy)return;
    setBusy(true);setMessage("正在采集诊断信息…");
    let timer:ReturnType<typeof setTimeout>|undefined;
    try {
      const path=await Promise.race([
        invoke<string>("export_diagnostics"),
        new Promise<never>((_,reject)=>{timer=setTimeout(()=>reject(new Error("timeout")),30000);}),
      ]);
      setMessage(`诊断包已保存：${path}。请查看后再决定是否发送。`);
    }catch{setMessage("导出未完成。可使用安装目录中的独立诊断工具，主界面无需启动。");}
    finally{clearTimeout(timer);setBusy(false);}
  }
  return <div className="diagnostic-export">
    <button type="button" disabled={busy} onClick={()=>void exportBundle()}>{busy?"正在生成诊断包…":"导出升级与运行诊断包"}</button>
    <small style={{display:"block",marginTop:6}}>保存到下载文件夹；不含密钥、对话或原始路径，不会自动上传。</small>
    {message&&<p role="status" style={{overflowWrap:"anywhere",fontSize:12}}>{message}</p>}
  </div>;
}
