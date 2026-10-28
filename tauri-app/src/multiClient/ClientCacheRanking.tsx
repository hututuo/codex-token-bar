import { useEffect, useState } from "react";
import { callCommandStrict } from "../api/command";
import { isTauriRuntimeAvailable } from "../platform/runtime";
import { clientNames, useMultiClientUsage, type UsageClient } from "./MultiClientUsage";
import { formatTokens } from "../utils/format";
interface Request { eventID:string;sessionID:string;model:string;timestamp:number;inputTokens:number;outputTokens:number;cacheReadTokens:number|null;cacheWriteTokens:number|null;cacheHitRate:number|null }
interface Session { sessionID:string;requests:number;lowHitRequests:number;zeroHitRequests:number;cacheHitRate:number|null;lastSeen:number }
interface Projection { requests:Request[];sessions:Session[];matchingRequestCount:number;requestLimit:number;hasMoreRequests:boolean }
const empty:Projection={requests:[],sessions:[],matchingRequestCount:0,requestLimit:0,hasMoreRequests:false};
const rate=(value:number|null)=>value===null||value===undefined?"缓存未知":(value*100).toFixed(1)+"%";
export function ClientCacheRanking({client}:{client:string}) {
  const {snapshot}=useMultiClientUsage();
  const [data,setData]=useState(empty),[issue,setIssue]=useState(""),[detail,setDetail]=useState(false),[limit,setLimit]=useState(200);
  useEffect(()=>{
    if(!isTauriRuntimeAvailable())return;
    let active=true;
    void callCommandStrict<Projection>("read_multi_client_cache_rankings",{client,limit}).then(value=>{if(active){setData(value);setIssue("");}}).catch(()=>{if(active)setIssue("本地缓存排行暂不可用");});
    return()=>{active=false;};
  },[client,limit,snapshot.updatedAt]);
  const title=clientNames[client as UsageClient]??client;
  return <section className="ranking-section">
    <div style={{display:"flex",alignItems:"center",justifyContent:"space-between"}}><h2>缓存命中排行 · {title}</h2><button type="button" onClick={()=>setDetail(true)}>查看请求明细</button></div>
    <p className="muted">按会话加权 · 缓存读取 / 总输入 · 缓存写入不算命中</p>
    {issue&&<p role="status">{issue}</p>}
    {!issue&&!data.sessions.length&&<p className="muted">暂无可比较的本地用量记录</p>}
    <div>{data.sessions.slice(0,10).map(row=><div key={row.sessionID} style={{display:"flex",alignItems:"center",gap:14,paddingBlock:7}}><code>{row.sessionID.slice(-12)}</code><span className="muted">{row.requests} 请求 · {row.lowHitRequests} 次低命中 · {row.zeroHitRequests} 次零命中</span><strong style={{marginLeft:"auto"}}>{rate(row.cacheHitRate)}</strong></div>)}</div>
    {detail&&<div className="client-cache-dialog-backdrop" onClick={()=>setDetail(false)}><section role="dialog" aria-modal="true" aria-label={title+"请求用量"} onClick={event=>event.stopPropagation()} className="client-cache-dialog">
      <div style={{display:"flex",justifyContent:"space-between"}}><h2>{title} · 请求用量</h2><button type="button" onClick={()=>setDetail(false)}>关闭</button></div>
      <p className="muted">请求级记录；当前账本未保留可靠的整轮边界，因此不冒充单轮排行。</p>
      <div style={{overflowY:"auto",minHeight:0}}>{data.requests.map(row=><div key={row.eventID} style={{paddingBlock:10,borderBottom:"1px solid var(--line)"}}><div>{new Date(row.timestamp*1000).toLocaleString()} · {row.model} · <strong>{rate(row.cacheHitRate)}</strong></div><small className="muted">会话 {row.sessionID} · 请求 {row.eventID}</small><div>输入 {formatTokens(row.inputTokens)} · 缓存读 {row.cacheReadTokens===null?"未知":formatTokens(row.cacheReadTokens)} · 缓存写 {row.cacheWriteTokens===null?"未知":formatTokens(row.cacheWriteTokens)} · 输出 {formatTokens(row.outputTokens)}</div></div>)}</div>
      {data.hasMoreRequests&&<p>已加载 {data.requests.length} / {data.matchingRequestCount} 条。{limit<5000&&<button type="button" onClick={()=>setLimit(Math.min(5000,limit+500))}>加载更多</button>}</p>}
    </section></div>}
  </section>;
}
