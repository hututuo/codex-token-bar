import { localAgentSpeedHistory } from "./speedDisplayHistory";
import { SpeedDisplayControls } from "./SpeedDisplayControls";
import { memo, useEffect, useMemo, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import type { CodexHomeSourceToken } from "../../types/platform";
import type { ModelRateContribution } from "../../types/live";
import { ActivityRateUnitControl, useActivityRatePreferences } from "./ActivityRateUnits";
import { activityRateText, activityRateValue, type ActivityRateHistoryPoint, type ActivityRateUnit } from "./activityRatePresentation";

export function LiveActivityRateHistory({ snapshot, sourceToken }: {
  snapshot: { tokensPerSecond: number; modelRates?: ModelRateContribution[]; speedDisplayMode?: "activity" | "agentSpeed" };
  sourceToken?: CodexHomeSourceToken | null;
}) {
  const { unit, fx } = useActivityRatePreferences();
  const [points, setPoints] = useState<ActivityRateHistoryPoint[]>([]);
  const [error, setError] = useState(false);
  const key = JSON.stringify(sourceToken ?? null);
  useEffect(() => {
    setPoints([]); setError(false);
    if (!sourceToken || snapshot.speedDisplayMode === "agentSpeed") return;
    let disposed = false, busy = false;
    const refresh = async () => {
      if (busy || document.hidden) return;
      busy = true;
      try {
        const next = await invoke<ActivityRateHistoryPoint[]>("read_activity_rate_history", { sourceToken });
        if (!disposed && Array.isArray(next)) { setPoints(next); setError(false); }
      } catch { if (!disposed) setError(true); }
      finally { busy = false; }
    };
    void refresh(); const timer = setInterval(() => void refresh(), 5000);
    return () => { disposed = true; clearInterval(timer); };
  }, [key, snapshot.speedDisplayMode]);
  useEffect(() => {
    if (snapshot.speedDisplayMode === "agentSpeed") localAgentSpeedHistory.record(Date.now() / 1000, snapshot.modelRates ?? []);
  }, [snapshot.speedDisplayMode, snapshot.modelRates]);
  useEffect(() => {
    if (snapshot.speedDisplayMode !== "agentSpeed") return;
    const refresh = () => setPoints(localAgentSpeedHistory.points());
    refresh(); const timer = setInterval(refresh, 5000);
    return () => clearInterval(timer);
  }, [snapshot.speedDisplayMode]);
  const value = activityRateValue(snapshot.tokensPerSecond, snapshot.modelRates, unit, fx);
  return <section className="activity-rate-panel" aria-label="全会话活动速率">
    <header><strong>{snapshot.speedDisplayMode === "agentSpeed" ? "榜单口径 · 本地活动截止" : "全会话活动速率"}</strong><ActivityRateUnitControl/></header>
    <div className="activity-rate-reading"><b>{activityRateText(value, unit)}</b><span>{unit === "CN 元/s" ? "估算 CN 元/s" : unit}</span></div>
    <SpeedDisplayControls/>
    {snapshot.speedDisplayMode === "agentSpeed" && <small>停止或错误即归零 · 日志 20 秒未更新归零 · 上报保持标准口径</small>}
    <ActivityRatePlot points={points} unit={unit} fx={fx}/>
    {error && <small>速率历史暂不可用</small>}
    {unit === "CN 元/s" && <small>输出单价折算 · 1 USD = {fx.toFixed(2)} 元{value === null ? " · 部分模型缺少单价" : ""}</small>}
  </section>;
}
const ActivityRatePlot = memo(function ActivityRatePlot({ points, unit, fx }: { points: ActivityRateHistoryPoint[]; unit: ActivityRateUnit; fx: number }) {
  const [hover, setHover] = useState<number | null>(null);
  const prepared = useMemo(() => {
    const end = Date.now() / 1000, start = end - 1800;
    const rows = points.filter(p => p.start >= start && p.start <= end).map(p => ({ at: p.start + 2.5,
      value: activityRateValue(p.modelRates.reduce((n,r)=>n+r.tokensPerSecond,0), p.modelRates, unit, fx) }));
    const ceiling = Math.max(unit === "tok/s" ? 1 : .0001, ...rows.map(r => (r.value ?? 0) * 1.12));
    const x = (at: number) => 55 + (at - start) / 1800 * 445;
    const y = (value: number) => 150 - value / ceiling * 132;
    let path = "", previous: number | null = null;
    for (const row of rows) {
      if (row.value === null) { previous = null; continue; }
      path += `${previous === null || row.at - previous > 5.1 ? "M" : "L"}${x(row.at).toFixed(2)},${y(row.value).toFixed(2)} `;
      previous = row.at;
    }
    return { start, end, ceiling, rows, x, y, path };
  }, [points, unit, fx]);
  const selected = hover === null ? null : prepared.rows[hover];
  const time = (at: number) => new Date(at*1000).toLocaleTimeString("zh-CN", { hour12:false });
  return <div className="activity-rate-plot">
    <div className="activity-rate-plot-heading"><span>近30分钟 · 5秒均值</span><span>{selected ? `${time(selected.at)} · ${activityRateText(selected.value,unit)} ${unit}` : ""}</span></div>
    <svg viewBox="0 0 520 182" role="img" aria-label={`近30分钟活动速率，${unit}`} onPointerLeave={()=>setHover(null)} onPointerMove={e=>{
      if (!prepared.rows.length) return;
      const rect=e.currentTarget.getBoundingClientRect();
      const target=prepared.start+((e.clientX-rect.left)/rect.width*520-55)/445*1800;
      let closest=0; for(let i=1;i<prepared.rows.length;i++)if(Math.abs(prepared.rows[i].at-target)<Math.abs(prepared.rows[closest].at-target))closest=i;
      setHover(closest);
    }}>
      {[0,.5,1].map(f=><g key={f}><line x1="55" x2="500" y1={prepared.y(prepared.ceiling*f)} y2={prepared.y(prepared.ceiling*f)} className="activity-rate-grid"/><text x="48" y={prepared.y(prepared.ceiling*f)+3} textAnchor="end">{activityRateText(prepared.ceiling*f,unit)}</text></g>)}
      <path d={prepared.path} className="activity-rate-line"/>
      {selected?.value !== null && selected && <circle cx={prepared.x(selected.at)} cy={prepared.y(selected.value!)} r="3" className="activity-rate-point"/>}
      {[0,.5,1].map(f=><text key={f} x={55+445*f} y="176" textAnchor={f===0?"start":f===1?"end":"middle"}>{time(prepared.start+1800*f).slice(0,5)}</text>)}
    </svg>
    {!points.length ? <small>等待采集 · 启动前的时间留空</small> : prepared.rows.length > 0 && prepared.rows.every(r=>r.value===null) && <small>部分模型缺少单价，未做金额换算</small>}
  </div>;
});
