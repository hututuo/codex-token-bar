import React, { useState } from "react";
import { createRoot } from "react-dom/client";
import { QuotaStrip } from "../src/components/QuotaStrip";
import { StatsStrip } from "../src/components/StatsStrip";
import type { QuotaItem } from "../src/multiClient/integratedClientModel";
import type { QuotaSnapshot } from "../src/types/dashboard";
import "../src/styles/global.css";

// Development-only rendering host. All observations are display fixtures, and
// no desktop commands, credentials, live reads or reports are invoked here.
const now = Date.now(), reset = (seconds: number) => new Date(now + seconds * 1000).toISOString();
const snapshot: QuotaSnapshot = {
  fiveHour: { label: "5h", availability: "absent", remainingPercent: null, usedPercent: null, resetsAt: "—" },
  sevenDay: { label: "7d", availability: "measured", remainingPercent: .72, usedPercent: .28, resetsAt: "3天后", resetsAtUnix: (now / 1000) + 259200 },
  paceLabel: "余量充足，可以冲", resetCredit: { availableCount: 3, status: "ready", credits: Array.from({length:3},(_,index)=>
    ({cardId:`preview-card-${index}`,status:"available",resetType:"codex_rate_limits",title:"额度重置卡",summary:"模拟重置卡",detailNote:"候选组件交互验证",associatedUser:"模拟账户",expiresAt:reset(86400*(index+1)),expiresAtUnix:now/1000+86400*(index+1),issuedAt:reset(-3600),grantedAtUnix:now/1000-3600,redeemStartedAt:"",redeemedAt:"",source:"fixture",profileImageUrl:"",shortId:`preview-${index}`})
  ) },
};
const items: QuotaItem[] = [
  { id:"codex:7d", client:"codex", window:"7d", remaining:72, resetsAt:reset(259200), source:"模拟 Codex 额度", status:"" },
  { id:"claudeCode:5h", client:"claudeCode", window:"5h", remaining:62, resetsAt:reset(7200), source:"模拟本地缓存", status:"" },
  { id:"claudeCode:7d", client:"claudeCode", window:"7d", remaining:84, resetsAt:reset(345600), source:"模拟本地缓存", status:"" },
];
const stats = {totalTokens:12800000,peakDayTokens:1630000,peakThreadTokens:326000,currentStreakDays:7,longestStreakDays:24,totalCalls:288,totalThreads:18,modelBreakdowns:[]};
function Fixture() {
  const [scope,setScope] = useState("all"), [cadence,setCadence] = useState(60000), [narrow,setNarrow] = useState(false);
  let quotas = scope === "claudeCode" ? items.filter(i=>i.client==="claudeCode") : items;
  if (scope === "many") quotas = [...items, ...Array.from({length:6},(_,index)=>({id:`codex:extra-${index}`,client:"codex",window:`窗口 ${index+1}`,remaining:index*17,resetsAt:reset(7200*(index+1)),source:"模拟额外窗口",status:""}))];
  if (scope === "missing") quotas = items.map(i=>i.client==="claudeCode" ? {...i, remaining:null, resetsAt:null, status:"未接入"} : i);
  return <main style={{width:"min(100% - 36px, 1080px)",margin:"32px auto"}}>
    <p style={{fontSize:11,color:"var(--muted)",margin:"0 0 18px"}}>候选版实际组件 · 模拟额度 · 不读取账户，不写账本</p>
    <h1 style={{fontSize:24,margin:"0 0 12px"}}>Codex Token Bar</h1>
    <nav aria-label="验证范围" style={{display:"flex",gap:8,flexWrap:"wrap",marginBottom:18}}>
      {[["codex","Codex"],["all","汇总"],["claudeCode","Claude"],["many","多窗口"],["missing","Claude 未接入"]].map(([id,label])=><button key={id} aria-pressed={scope===id} onClick={()=>setScope(id)} style={{padding:"7px 13px",borderRadius:8,border:"1px solid var(--line)",background:scope===id?"var(--accent)":"var(--panel)",color:scope===id?"white":"var(--text)"}}>{label}</button>)}
      <button onClick={()=>setNarrow(v=>!v)} style={{padding:"7px 13px",borderRadius:8,border:"1px solid var(--line)",background:"var(--panel)",color:"var(--text)"}}>窄窗口 {narrow?"✓":""}</button>
    </nav>
    <div style={{maxWidth:narrow?520:980,margin:"0 auto"}}>
      <QuotaStrip snapshot={snapshot} clientItems={scope==="codex"?undefined:quotas} includesCodex={scope!=="claudeCode"} quotaRefreshIntervalMs={cadence} onQuotaRefreshIntervalChange={value=>setCadence(value)}/>
      <StatsStrip stats={stats} planLabel="PRO" todayTokens={920000}/>
    </div>
  </main>;
}
createRoot(document.getElementById("root")!).render(<Fixture/>);
