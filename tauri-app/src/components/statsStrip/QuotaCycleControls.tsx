import { useState } from "react";
import { QuotaCycleCalendar } from "./QuotaCycleCalendar";
import type { QuotaCycle } from "../../types/quota";
const date = (at: number) => new Date(at * 1000).toLocaleString("zh-CN", { month:"2-digit",day:"2-digit",hour:"2-digit",minute:"2-digit" });
const approximateDate = (lower: number, upper: number) => `${lower === upper ? "" : "约 "}${date(lower + (upper - lower) / 2)}`;
export function quotaCycleLabel(c: QuotaCycle): string {
  const start = c.startLowerUnix === null ? `从 ${date(c.firstObservedUnix)} 开始记录`
    : approximateDate(c.startLowerUnix, c.startUpperUnix ?? c.startLowerUnix);
  const end = c.current ? "至今" : approximateDate(c.endLowerUnix, c.endUpperUnix);
  return `${start} → ${end}${c.earlyEnd ? " · 提前重置（推测）" : ""}`;
}
export function quotaCycleErrorStatus(error: string): string {
  if (error.includes("未解决的校验异常")) return "来源待核验";
  if (error.includes("等待精准") || error.includes("等待完整聚合") || error.includes("正在更新")) return "资料正在更新";
  return "周期明细读取失败";
}
export function QuotaCycleControls({cycles, selected, onSelect, error}: {
  cycles: QuotaCycle[]; selected?: QuotaCycle; onSelect:(id:string)=>void; error?:string;
}) {
  const [expanded, setExpanded] = useState(false);
  return <div className="stats-quota-cycle-controls">
    <button type="button" className="quota-calendar-disclosure" aria-expanded={expanded} onClick={() => setExpanded(!expanded)}>
      {expanded ? "▾ 收起日历" : "▸ 选择周期"}
    </button>
    
    {selected ? <small className="quota-calendar-selection">{quotaCycleLabel(selected)}</small> : null}
    {error ? <small role="status" title={error}>{quotaCycleErrorStatus(error)}</small> : null}
    {expanded ? <QuotaCycleCalendar cycles={cycles} selected={selected} onSelect={onSelect} /> : null}
  </div>;
}
