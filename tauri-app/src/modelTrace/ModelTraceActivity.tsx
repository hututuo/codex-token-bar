import { useEffect, useMemo, useState } from "react";
import { HeatmapGrid } from "../components/tokenActivity/HeatmapGrid";
import { buildCalendarDays, buildMonthMarkers } from "../components/tokenActivity/calendar";
import type { ActivityDay } from "../types/dashboard";
import { readHistory } from "./client";
import { dateKey, dayPresentation, modelLabel, statusLabel, summarize } from "./model";
import type { TraceRun } from "./types";
import { useModelTrace } from "./useModelTrace";

const RECORDS_PER_PAGE = 9;

export function ModelTraceActivity() {
  const {snapshot, error: snapshotError} = useModelTrace();
  const [runs, setRuns] = useState<TraceRun[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const today = dateKey(Date.now() / 1000);
  const days = useMemo(() => buildCalendarDays([{date: today, tokens: 0, calls: 0, cacheHitRate: 0, fiveHourRemainingPercent: null, sevenDayRemainingPercent: null}]), [today]);
  useEffect(() => {
    let disposed = false;
    let retry: ReturnType<typeof setTimeout> | undefined;
    setRuns([]); setError(null); setLoading(true);
    if (!snapshot) return;
    const scope = snapshot.scopeKey;
    const start = new Date(`${days[0].date}T00:00:00`);
    const end = new Date(`${today}T00:00:00`); end.setDate(end.getDate() + 1);
    const load = async () => {
      try {
        const collected: TraceRun[] = [];
        let offset = 0;
        while (!disposed) {
          const page = await readHistory(Math.floor(start.getTime() / 1000), Math.floor(end.getTime() / 1000), offset);
          if (disposed) return;
          if (page.scopeKey !== scope) throw new Error("数据来源已改变，正在重新读取检测历史");
          collected.push(...page.runs);
          if (!page.hasMore) break;
          if (!page.runs.length) throw new Error("检测历史分页没有继续前进");
          offset += page.runs.length;
        }
        if (!disposed) {setRuns(collected); setError(null);}
      } catch (reason) {
        if (!disposed) {
          setError(String(reason));
          retry = setTimeout(() => void load(), 5_000);
        }
      } finally {if (!disposed) setLoading(false);}
    };
    void load();
    return () => {disposed = true; clearTimeout(retry);};
  }, [snapshot?.scopeKey, snapshot?.latest?.id, snapshot?.latest?.completedAt, today, days]);
  return <ModelTraceActivityView key={snapshot?.scopeKey ?? "loading"} runs={runs} days={days} error={error || snapshotError} loading={loading && !snapshotError} />;
}

export function ModelTraceActivityView({runs, days, error, loading}: {
  runs: TraceRun[]; days: ActivityDay[]; error: string | null; loading: boolean;
}) {
  const [rangeStart, setRangeStart] = useState<string | null>(null);
  const [rangeEnd, setRangeEnd] = useState<string | null>(null);
  const [hovered, setHovered] = useState<ActivityDay | null>(null);
  const [listLimit, setListLimit] = useState(RECORDS_PER_PAGE);
  const byDay = useMemo(() => {
    const map = new Map<string, TraceRun[]>();
    for (const run of runs) {const key = dateKey(run.startedAt); map.set(key, [...(map.get(key) ?? []), run]);}
    return map;
  }, [runs]);
  const selected = useMemo(() => runs.filter(run => !rangeStart || (dateKey(run.startedAt) >= rangeStart && dateKey(run.startedAt) <= (rangeEnd ?? rangeStart))), [runs, rangeStart, rangeEnd]);
  const summary = summarize(selected);
  function chooseDate(date: string) {
    setListLimit(RECORDS_PER_PAGE);
    if (!rangeStart || rangeEnd) {setRangeStart(date);setRangeEnd(null);}
    else {setRangeStart(date < rangeStart ? date : rangeStart);setRangeEnd(date < rangeStart ? rangeStart : date);}
  }
  return <div className="modeltrace-activity" aria-label="模型检测历史" aria-busy={loading}>
      <HeatmapGrid days={days.map(day => ({day, intensity: 0}))} mode="daily" priceModel="gpt56Sol" monthMarkers={buildMonthMarkers(days)}
        onDateSelect={chooseDate} onDayHover={setHovered} hoveredDate={hovered?.date ?? null} rangeStart={rangeStart} rangeEnd={rangeEnd}
        accessibleLabel="过去一年模型检测；方向键移动，Enter 或空格选择日期"
        cellPresentation={day => {const view = dayPresentation(byDay.get(day.date) ?? []); return {...view, label: `${day.date}：${view.label}`};}} />
      <div className="modeltrace-legend-row"><div className="chart-legend modeltrace-legend"><span className="chart-legend-item"><i className="legend-dot" style={{background: "var(--green)"}} />相符</span><span className="chart-legend-item"><i className="legend-dot" style={{background: "var(--orange)"}} />不符</span><span className="chart-legend-item"><i className="legend-dot" style={{background: "linear-gradient(135deg,var(--green) 50%,var(--orange) 50%)"}} />混合</span><span className="chart-legend-item" title="失败、取消、中断、缺测或无法判定"><i className="legend-dot" style={{background: "var(--muted)"}} />其他</span><span className="chart-legend-item"><i className="legend-dot" style={{background: "var(--heatmap-empty)"}} />未检测</span></div>
        {rangeStart && <button className="toolbar-button modeltrace-clear" type="button" onClick={() => {setRangeStart(null);setRangeEnd(null);setListLimit(RECORDS_PER_PAGE);}}>清除选择</button>}</div>
      <div className="range-summary modeltrace-history-summary">
        {error ? <span className="modeltrace-error" role="alert" title={error}>{error}</span>
          : loading ? <span role="status">正在读取检测历史…</span>
          : <span title={rangeStart ? `${rangeStart}${rangeEnd ? ` 至 ${rangeEnd}` : ""}` : "点击日期查看当天，点击第二个日期查看范围"}>{rangeStart ? `${rangeStart}${rangeEnd ? ` 至 ${rangeEnd}` : ""}` : "过去一年"} · 相符 {summary.matches} · 不符 {summary.differs} · 其他 {summary.other}</span>}
        <strong title="所选日期范围全部模型的相符轮次 / 可判定轮次；其他轮次不计入分母。"><em>相符 / 可判定</em>{loading || error ? "—" : summary.ratio}</strong></div>
      <details className="modeltrace-records" onToggle={event => {if (!event.currentTarget.open) setListLimit(RECORDS_PER_PAGE);}}>
        <summary><span className="modeltrace-records-heading">检测记录 <span className="modeltrace-record-count">{loading || error ? "—" : selected.length}</span></span></summary>
        {!loading && !error && !selected.length && <p className="modeltrace-empty">当前范围没有检测记录。</p>}
        <div className="modeltrace-records-scroll"><ul className="modeltrace-history-list" aria-label="检测记录列表">{selected.slice(0, listLimit).map(run => {
          const date = new Date(run.startedAt * 1000);
          const minute = `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
          return <li className="modeltrace-record-row" key={run.id}><time dateTime={date.toISOString()} title={`${dateKey(run.startedAt)} ${minute}`}>{dateKey(run.startedAt).slice(5)} {minute}</time><span className="modeltrace-record-model" title={modelLabel(run.model)}>{modelLabel(run.model)}</span><span className="modeltrace-badge" data-status={run.status}>{statusLabel(run.status)}</span></li>;
        })}</ul></div>
        {selected.length > listLimit && <button className="live-reset-button modeltrace-more" type="button" onClick={() => setListLimit(value => value + RECORDS_PER_PAGE)}>继续加载<span>· 再显示 3 行</span></button>}
      </details>
  </div>;
}
