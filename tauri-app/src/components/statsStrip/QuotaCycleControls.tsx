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
export function quotaCycleCompactLabel(c: QuotaCycle): string {
  const start = c.startLowerUnix === null ? c.firstObservedUnix
    : c.startLowerUnix + ((c.startUpperUnix ?? c.startLowerUnix) - c.startLowerUnix) / 2;
  const end = c.endLowerUnix + (c.endUpperUnix - c.endLowerUnix) / 2;
  const day = (at: number) => new Date(at * 1000).toLocaleDateString("zh-CN", {month: "numeric", day: "numeric"});
  const time = (at: number) => new Date(at * 1000).toLocaleTimeString("zh-CN", {hour: "2-digit", minute: "2-digit", hour12: false});
  const approximate = c.startLowerUnix === null || c.startLowerUnix !== (c.startUpperUnix ?? c.startLowerUnix) ? "约 " : "";
  if (c.current) return `${approximate}${day(start)} 起`;
  const endApproximate = c.endLowerUnix !== c.endUpperUnix ? "约 " : "";
  if (new Date(start * 1000).toDateString() === new Date(end * 1000).toDateString()) {
    return `${approximate}${day(start)} ${time(start)}–${endApproximate}${time(end)}`;
  }
  return `${approximate}${day(start)}–${endApproximate}${day(end)}`;
}
export function QuotaCycleControls({cycles, selected, onSelect, error, expanded, onToggle}: {
  cycles: QuotaCycle[]; selected?: QuotaCycle; onSelect:(id:string)=>void; error?:string;
  expanded: boolean; onToggle: () => void;
}) {
  const current = cycles.find(c => c.current);
  return <div className="stats-quota-cycle-controls">
    <button type="button" className="quota-calendar-disclosure" aria-expanded={expanded} onClick={onToggle}
      title="选择周期，查看该周期的模型费用">
      {expanded ? "收起日历" : "历史周期"}
    </button>
    
    {selected ? <button type="button" className="quota-calendar-selection" title={quotaCycleLabel(selected)}
      aria-expanded={expanded} onClick={onToggle}>{quotaCycleCompactLabel(selected)}</button> : null}
    {selected && !selected.current && current ? <button type="button" className="quota-calendar-return"
      onClick={() => onSelect("current")}>回到本期</button> : null}
    {error ? <small role="status" title={error}>{quotaCycleErrorStatus(error)}</small> : null}
  </div>;
}
