import { useState } from "react";
import { formatTokens } from "../utils/format";
export interface TrendPoint { at: number; tokens: number; five: number | null; seven: number | null }
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
export function SidebarTrend({points}: {points: TrendPoint[]}) {
  const [selected, setSelected] = useState<number | null>(null);
  if (!points.length) return <p className="qs-muted">最近 24 小时趋势待读取</p>;
  const max = Math.max(1, ...points.map(point => point.tokens));
  const index = selected === null ? points.length - 1 : Math.min(selected, points.length - 1);
  const point = points[index];
  const hasFive = points.some(point => point.five !== null);
  return <section className="qs-mini-trend">
    <div className="qs-section-heading"><h3>最近 24 小时</h3><span>Token / 剩余额度 · 点击查看</span></div>
    <svg preserveAspectRatio="none" viewBox="0 0 340 90" role="img" aria-label="最近24小时Token与剩余额度趋势" onClick={event => {
      const bounds = event.currentTarget.getBoundingClientRect();
      setSelected(Math.max(0, Math.min(points.length - 1, Math.round((event.clientX - bounds.left) / bounds.width * (points.length - 1)))));
    }}>
      <path d="M0,4H340 M0,44H340 M0,84H340" stroke="#ffffff12" fill="none" />
      <path d={trendPath(points, "tokens", max)} stroke="#78b7ff" />
      {hasFive && <path d={trendPath(points, "five", 1)} stroke="#b6ef75" />}
      <path d={trendPath(points, "seven", 1)} stroke="#b4acff" />
      {selected !== null && <path d={`M${index / Math.max(1,points.length-1)*340},0v88`} stroke="#ffffff99" strokeDasharray="2 3" />}
    </svg>
    <div className="qs-trend-legend"><time>{new Date(point.at*1000).toLocaleTimeString("zh-CN",{hour:"2-digit",minute:"2-digit",hour12:false})}</time><span style={{color:"#78b7ff"}}>{formatTokens(point.tokens)} Token / 5分</span>{hasFive && <span style={{color:"#b6ef75"}}>5h {point.five === null ? "—" : `${Math.round(point.five*100)}%`}</span>}<span style={{color:"#b4acff"}}>7d {point.seven === null ? "—" : `${Math.round(point.seven*100)}%`}</span></div>
  </section>;
}
