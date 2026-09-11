import { useState } from "react";
import type { QuotaCycle } from "../../types/quota";
const colors = ["#65a9df", "#9b87db", "#54b49e", "#dca35f", "#ce84a9"];
const dayStart = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate());
const weekPosition = (d: Date, start: Date) => {
  const day = dayStart(d), next = addDays(day, 1);
  const index = Math.round((day.getTime() - start.getTime()) / 86400000);
  return Math.max(0, Math.min(7, index + (d.getTime() - day.getTime()) / (next.getTime() - day.getTime())));
};
const addDays = (d: Date, n: number) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n);
const midpoint = (a: number | null, b: number | null, fallback: number) => a === null ? fallback : a + ((b ?? a) - a) / 2;
export function QuotaCycleCalendar({ cycles, selected, onSelect }: { cycles: QuotaCycle[]; selected?: QuotaCycle; onSelect: (id: string) => void }) {
  const [month, setMonth] = useState(() => new Date((selected?.lastObservedUnix ?? Date.now() / 1000) * 1000));
  const first = new Date(month.getFullYear(), month.getMonth(), 1);
  const gridStart = addDays(first, -(first.getDay() + 6) % 7);
  const daysInMonth = new Date(month.getFullYear(), month.getMonth() + 1, 0).getDate();
  const weekCount = Math.ceil(((first.getDay() + 6) % 7 + daysInMonth) / 7);
  const ordered = [...cycles].reverse();
  return <div className="quota-cycle-calendar" aria-label="周期日历">
    <div className="quota-calendar-header">
      <button type="button" aria-label="上个月" onClick={() => setMonth(new Date(month.getFullYear(), month.getMonth() - 1, 1))}>‹</button>
      <strong>{first.toLocaleDateString("zh-CN", {year:"numeric",month:"long"})}</strong>
      <button type="button" aria-label="下个月" onClick={() => setMonth(new Date(month.getFullYear(), month.getMonth() + 1, 1))}>›</button>
      <button type="button" className="quota-calendar-current" onClick={() => {setMonth(new Date()); onSelect("current");}}>回到本期</button>
    </div>
    <div className="quota-calendar-weekdays">{["一","二","三","四","五","六","日"].map(d => <span key={d}>{d}</span>)}</div>
    {Array.from({length:weekCount}, (_, week) => {
      const start = addDays(gridStart, week * 7), end = addDays(start, 7);
      const segments = ordered.flatMap((cycle, index) => {
        const from = new Date(midpoint(cycle.startLowerUnix, cycle.startUpperUnix, cycle.firstObservedUnix) * 1000);
        const to = new Date((cycle.current ? Date.now() / 1000 : midpoint(cycle.endLowerUnix, cycle.endUpperUnix, cycle.lastObservedUnix)) * 1000);
        if (from >= end || to <= start) return [];
        const left = weekPosition(from, start);
        const right = weekPosition(to, start);
        return [{cycle,index,left,right}];
      });
      return <div className="quota-calendar-week" key={start.getTime()}>
        <div className="quota-calendar-bands">{segments.map(({cycle,index,left,right}) => <button key={cycle.id} type="button"
          aria-label={`${cycle.current ? "本期" : `第 ${index+1} 期`} · ${new Date(cycle.firstObservedUnix*1000).toLocaleDateString("zh-CN")}`}
          aria-pressed={selected?.id === cycle.id} title={`${cycle.current ? "本期" : `第 ${index+1} 期`} · 点击查看用量与模型明细`}
          style={{left:`${left / 7 * 100}%`,width:`${(right-left) / 7 * 100}%`,"--cycle-color":colors[index%colors.length]} as React.CSSProperties}
          onClick={() => onSelect(cycle.id)} />)}</div>
        <div className="quota-calendar-dates">{Array.from({length:7},(_,i) => {const day = addDays(start,i); return <span key={i} className={day.getMonth() !== first.getMonth() ? "outside" : ""}>{day.getDate()}</span>;})}</div>
      </div>;
    })}
    {cycles.length === 0 ? <p>暂无周期记录</p> : null}
  </div>;
}
