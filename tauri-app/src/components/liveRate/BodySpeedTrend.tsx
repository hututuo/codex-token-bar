import { invoke } from "@tauri-apps/api/core";
import { useEffect, useId, useMemo, useState } from "react";
import type { CodexHomeSourceToken } from "../../types/platform";

export interface SpeedTrendPoint { bucketStart: number; model: string; outputTokens: number; durationSeconds: number; sampleCount: number; tokensPerSecond: number }
const colors = ["#4e80ef", "#d08747", "#47a794", "#ad72cc", "#df748f", "#749a46", "#55a9ca", "#bc8a31"];
export function trendSegments(points: SpeedTrendPoint[], width: number) {
    const result: SpeedTrendPoint[][] = [];
    for (const model of [...new Set(points.map(p => p.model))].sort()) {
        let segment: SpeedTrendPoint[] = [];
        for (const point of points.filter(p => p.model === model && Number.isFinite(p.tokensPerSecond) && p.tokensPerSecond > 0).sort((a, b) => a.bucketStart - b.bucketStart)) {
            if (segment.length && point.bucketStart - segment.at(-1)!.bucketStart > width) { result.push(segment); segment = []; }
            segment.push(point);
        }
        if (segment.length) result.push(segment);
    }
    return result;
}
export function BodySpeedTrend({ sourceToken, revision, compact }: { sourceToken: CodexHomeSourceToken | null; revision: string; compact?: "detail" | "rail" }) {
    const [days, setDays] = useState(1);
    const [points, setPoints] = useState<SpeedTrendPoint[]>([]);
    const [error, setError] = useState<string | null>(null);
    const [asOf, setAsOf] = useState(Date.now() / 1000);
    const key = JSON.stringify(sourceToken), id = useId();
    useEffect(() => { setPoints([]); setError(null); }, [key]);
    useEffect(() => {
        if (!sourceToken) return;
        let disposed = false, busy = false;
        const read = async () => {
            if (busy) return; busy = true;
            try {
                const rows = await invoke<SpeedTrendPoint[]>("read_body_speed_trend", { sourceToken, days });
                if (!disposed) { setPoints(rows); setAsOf(Date.now() / 1000); setError(null); }
            } catch (e) { if (!disposed) setError(`趋势读取失败：${String(e)}`); }
            finally { busy = false; }
        };
        const start = window.setTimeout(() => void read(), 150), timer = window.setInterval(() => void read(), 60_000);
        return () => { disposed = true; window.clearTimeout(start); window.clearInterval(timer); };
    }, [key, days, revision]);
    const resolution = days === 1 ? 300 : days === 7 ? 1800 : 7200;
    const displayPoints = useMemo(() => compact === "rail" ? points.filter(p => p.bucketStart >= asOf - 1800) : points, [points, compact, asOf]);
    const segments = useMemo(() => trendSegments(displayPoints, resolution), [displayPoints, resolution]);
    const models = [...new Set(points.map(p => p.model))].sort();
    const left = 42, right = 785, top = 12, bottom = 145, span = compact === "rail" ? 1800 : days * 86400, start = asOf - span;
    const maximum = Math.max(10, ...displayPoints.map(p => p.tokensPerSecond)) * 1.12;
    const x = (point: SpeedTrendPoint) => left + (point.bucketStart - start) / span * (right - left);
    const y = (point: SpeedTrendPoint) => bottom - point.tokensPerSecond / maximum * (bottom - top);
    const color = (model: string) => colors[models.indexOf(model) % colors.length];
    return <section className={`body-speed-trend ${compact ? `bst-${compact}` : ""}`} aria-label="模型速度变化">
        {compact !== "rail" && <header><strong>速度变化</strong><span>{days === 1 ? "每5分钟平均 TPS" : days === 7 ? "30分钟汇总 · 底层5分钟" : "2小时汇总 · 底层5分钟"}</span><div>{[1, 7, 30].map(value => <button key={value} aria-pressed={days === value} onClick={() => setDays(value)}>{value === 1 ? "24小时" : `${value}天`}</button>)}</div></header>}
        <svg viewBox="0 0 800 170" role="img" aria-label="按模型区分的平均 TPS 趋势"><defs><clipPath id={id}><rect x={left} y={top} width={right - left} height={bottom - top}/></clipPath></defs>
            {[0, 1, 2, 3].map(tick => { const rate = maximum * tick / 3, at = bottom - (bottom - top) * tick / 3; return <g key={tick}><line x1={left} x2={right} y1={at} y2={at} className="bst-grid"/><text x={left - 7} y={at + 3} textAnchor="end">{rate.toFixed(0)}</text></g>; })}
            {[0, 1, 2, 3, 4].map(tick => { const at = start + span * tick / 4; return <text key={tick} x={left + (right - left) * tick / 4} y={163} textAnchor={tick === 0 ? "start" : tick === 4 ? "end" : "middle"}>{new Date(at * 1000).toLocaleString("zh-CN", days === 1 ? { hour: "2-digit", minute: "2-digit", hour12: false } : { month: "2-digit", day: "2-digit" })}</text>; })}
            <g clipPath={`url(#${id})`}>{segments.map((segment, i) => <g key={`${segment[0].model}/${i}`}><polyline points={segment.map(p => `${x(p)},${y(p)}`).join(" ")} fill="none" stroke={color(segment[0].model)} strokeWidth="1.8"/>{segment.map(p => <circle key={`${p.model}/${p.bucketStart}`} cx={x(p)} cy={y(p)} r="2.4" fill={color(p.model)}><title>{p.model} · {new Date(p.bucketStart * 1000).toLocaleString()} · {p.tokensPerSecond.toFixed(1)} TPS · {p.sampleCount}段正文 · {p.outputTokens} token / {p.durationSeconds.toFixed(2)}秒</title></circle>)}</g>)}</g>
            {!displayPoints.length && compact !== "rail" && <text x="410" y="80" textAnchor="middle">等待合格正文采样 · 无数据时留空</text>}
        </svg>
        <div className="bst-legend">{models.map(model => <span key={model}><i style={{ background: color(model) }}/>{model.replace(/^gpt-/, "")}</span>)}</div>
        {error && <p role="status">{error}</p>}
    </section>;
}
