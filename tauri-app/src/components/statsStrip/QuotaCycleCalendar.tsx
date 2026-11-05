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
export function localDayKey(date: Date): string {
  return `${date.getFullYear()}-${String(date.getMonth()+1).padStart(2,'0')}-${String(date.getDate()).padStart(2,'0')}`;
}
type CalendarProps = {
  cycles: QuotaCycle[]; selected?: QuotaCycle; onSelect: (id: string) => void; daySelection?: never;
} | {
  cycles?: never; selected?: never; onSelect?: never;
  daySelection: { selected: Date | null; onSelect: (date: Date) => void; now: Date };
};
export function QuotaCycleCalendar({ cycles = [], selected, onSelect, daySelection }: CalendarProps) {
  const now = daySelection?.now ?? new Date();
  const [month, setMonth] = useState(() => daySelection?.selected ?? new Date((selected?.lastObservedUnix ?? now.getTime() / 1000) * 1000));
  const first = new Date(month.getFullYear(), month.getMonth(), 1);
  const gridStart = addDays(first, -(first.getDay() + 6) % 7);
  const daysInMonth = new Date(month.getFullYear(), month.getMonth() + 1, 0).getDate();
  const weekCount = Math.ceil(((first.getDay() + 6) % 7 + daysInMonth) / 7);
  const ordered = [...cycles].reverse();
  return <div className={`quota-cycle-calendar${daySelection ? " model-day-calendar" : ""}`} aria-label={daySelection ? "单日金额日历" : "周期日历"}>
    <div className="quota-calendar-header">
      <button type="button" aria-label={daySelection ? "单日日历上个月" : "上个月"} onClick={() => setMonth(new Date(month.getFullYear(), month.getMonth() - 1, 1))}>‹</button>
      <strong>{first.toLocaleDateString("zh-CN", {year:"numeric",month:"long"})}</strong>
      <button type="button" aria-label={daySelection ? "单日日历下个月" : "下个月"}
        disabled={Boolean(daySelection && first.getFullYear() === now.getFullYear() && first.getMonth() === now.getMonth())}
        onClick={() => setMonth(new Date(month.getFullYear(), month.getMonth() + 1, 1))}>›</button>
      {daySelection ? <>
        <label className="quota-calendar-day-jump">跳转日期 <input type="date" aria-label="选择历史日期"
          max={localDayKey(now)} value={localDayKey(daySelection.selected ?? now)}
          onChange={event => {
            const [year, month, day] = event.target.value.split('-').map(Number);
            const date = new Date(year, month - 1, day);
            if (localDayKey(date) === event.target.value && date <= dayStart(now)) {
              setMonth(date); daySelection.onSelect(date);
            }
          }} /></label>
        <button type="button" onClick={() => {setMonth(now); daySelection.onSelect(dayStart(now));}}>今天</button>
      </> : <button type="button" className="quota-calendar-current" onClick={() => {setMonth(now); onSelect?.("current");}}>回到本期</button>}
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
          onClick={() => onSelect?.(cycle.id)} />)}</div>
        <div className={`quota-calendar-dates${daySelection ? " quota-calendar-day-selection" : ""}`}>{Array.from({length:7},(_,i) => {
          const day = addDays(start,i), key = localDayKey(day);
          const outside = day.getMonth() !== first.getMonth() ? "outside" : "";
          return daySelection ? <button key={key} type="button" aria-label={`${key}的模型金额`}
            aria-pressed={daySelection.selected !== null && key === localDayKey(daySelection.selected)}
            disabled={day > dayStart(now)} className={outside} onClick={() => daySelection.onSelect(day)}>{day.getDate()}</button>
            : <span key={i} className={outside}>{day.getDate()}</span>;
        })}</div>
      </div>;
    })}
    {!daySelection && cycles.length === 0 ? <p>暂无周期记录</p> : null}
  </div>;
}
