import { useState } from "react";
import { formatTokens } from "../utils/format";
import type { QuotaHistoryPoint } from "../types/quota";
export interface TrendPoint { at: number; tokens: number; five: number | null; seven: number | null }
export function buildSidebarTrend(tokens: readonly [number, number][], quota: readonly QuotaHistoryPoint[]): TrendPoint[] {
  const bucket = (at: number) => Math.floor(at / 300);
  const byTime = new Map(quota.map(point => [bucket(point.startUnix), point]));
  return tokens.map(([at, count]) => ({ at, tokens: count,
    five: byTime.get(bucket(at))?.fiveHourRemainingPercent ?? null,
    seven: byTime.get(bucket(at))?.sevenDayRemainingPercent ?? null }));
}
export function isolatedQuotaPoints(points: TrendPoint[], metric: "five" | "seven") {
  const valid = (index: number) => points[index]?.[metric] !== null && Number.isFinite(points[index]?.[metric]);
  return points.flatMap((point, index) => valid(index) && !valid(index - 1) && !valid(index + 1)
    ? [{ index, value: point[metric]! }] : []);
}
export function trendPath(points: TrendPoint[], metric: "tokens" | "five" | "seven", maximum: number): string {
  let path = ""; let connected = false;
  points.forEach((point, index) => {
    const value = point[metric];
    if (value === null || !Number.isFinite(value)) { connected = false; return; }
    const x = index / Math.max(1, points.length - 1) * 340;
    const y = 84 - Math.max(0, Math.min(1, value / maximum)) * 80;
    path += `${connected ? "L" : "M"}${x.toFixed(2)},${y.toFixed(2)} `; connected = true;
  });
  return path;
}
export function SidebarTrend({points, tokenLabel = "Token"}: {points: TrendPoint[]; tokenLabel?: string}) {
  const [selected, setSelected] = useState<number | null>(null);
  if (!points.length) return <p className="qs-muted">最近 24 小时趋势待读取</p>;
  const max = Math.max(1, ...points.map(point => point.tokens));
  const index = selected === null ? points.length - 1 : Math.min(selected, points.length - 1);
  const point = points[index];
  const hasFive = points.some(point => point.five !== null && Number.isFinite(point.five));
  const hasSeven = points.some(point => point.seven !== null && Number.isFinite(point.seven));
  return <section className="qs-mini-trend">
    <div className="qs-section-heading"><h3>最近 24 小时</h3><span>{tokenLabel} / Codex 剩余额度 · 点击查看</span></div>
    <svg preserveAspectRatio="none" viewBox="0 0 340 90" role="img" aria-label="最近24小时Token与剩余额度趋势" onClick={event => {
      const bounds = event.currentTarget.getBoundingClientRect();
      setSelected(Math.max(0, Math.min(points.length - 1, Math.round((event.clientX - bounds.left) / bounds.width * (points.length - 1)))));
    }}>
      <path d="M0,4H340 M0,44H340 M0,84H340" stroke="#ffffff12" fill="none" />
      <path d={trendPath(points, "tokens", max)} stroke="#78b7ff" />
      {hasFive && <path d={trendPath(points, "five", 1)} stroke="#b6ef75" />}
      {hasSeven && <path d={trendPath(points, "seven", 1)} stroke="#b4acff" />}
      {(["five", "seven"] as const).flatMap(metric => isolatedQuotaPoints(points, metric).map(({index, value}) =>
        <circle key={`${metric}:${index}`} cx={index / Math.max(1, points.length - 1) * 340} cy={84 - Math.max(0, Math.min(1, value)) * 80} r={1.8} fill={metric === "five" ? "#b6ef75" : "#b4acff"} />))}
      {selected !== null && <path d={`M${index / Math.max(1,points.length-1)*340},0v88`} stroke="#ffffff99" strokeDasharray="2 3" />}
    </svg>
    <div className="qs-trend-legend"><time>{new Date(point.at*1000).toLocaleTimeString("zh-CN",{hour:"2-digit",minute:"2-digit",hour12:false})}</time><span style={{color:"#78b7ff"}}>{formatTokens(point.tokens)} {tokenLabel} / 5分</span>{hasFive && <span style={{color:"#b6ef75"}}>5h {point.five === null ? "—" : `${Math.round(point.five*100)}%`}</span>}{hasSeven && <span style={{color:"#b4acff"}}>7d {point.seven === null ? "—" : `${Math.round(point.seven*100)}%`}</span>}</div>
    {!hasFive && !hasSeven && <p className="qs-muted">Codex 额度暂无历史采样</p>}
  </section>;
}
