import { invoke } from "@tauri-apps/api/core";
import { modelUsageColor } from "../modelUsagePresentation";
import { useEffect, useId, useMemo, useState } from "react";
import type { CodexHomeSourceToken } from "../../types/platform";

export interface SpeedTrendPoint { bucketStart: number; model: string; outputTokens: number; durationSeconds: number; sampleCount: number; tokensPerSecond: number }
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
export function trendPlot(points: SpeedTrendPoint[], asOf: number, windowSeconds: number, model: string | null) {
    const rows = points.filter(p => p.bucketStart >= asOf - windowSeconds && p.bucketStart <= asOf && (model == null || p.model === model) && Number.isFinite(p.tokensPerSecond) && p.tokensPerSecond > 0).sort((a,b)=>a.bucketStart-b.bucketStart);
    const rates = rows.map(p=>p.tokensPerSecond), low = rates.length ? Math.min(...rates) : 0, high = rates.length ? Math.max(...rates) : 10;
    const padding = Math.max(5,(high-low)*.2), first = rows[0], last = rows.at(-1);
    return { rows, minimum: Math.max(0,low-padding), maximum: Math.max(10,high+padding), last,
        change: model != null && first && last && first.bucketStart !== last.bucketStart ? (last.tokensPerSecond/first.tokensPerSecond-1)*100 : null };
}
export function BodySpeedTrend({ sourceToken, revision, compact, preferredModel }: { sourceToken: CodexHomeSourceToken | null; revision: string; compact?: "detail"; preferredModel?: string }) {
    const [windowSeconds, setWindowSeconds] = useState(86400);
    const days = windowSeconds <= 86400 ? 1 : windowSeconds === 604800 ? 7 : 30;
    const [selectedModel, setSelectedModel] = useState<string | null>(null);
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
    const rangePoints = points.filter(p => p.bucketStart >= asOf - windowSeconds);
    const models = [...new Set(rangePoints.map(p => p.model))].sort();
    const preferred = preferredModel && models.includes(preferredModel) ? preferredModel : models[0];
    const modelKey = models.join("|");
    useEffect(() => { if (selectedModel !== "*" && (!selectedModel || !models.includes(selectedModel))) setSelectedModel(preferred ?? null); }, [modelKey, preferred, selectedModel]);
    const focus = selectedModel === "*" ? null : selectedModel && models.includes(selectedModel) ? selectedModel : preferred;
    const plot = trendPlot(points,asOf,windowSeconds,focus ?? null), displayPoints = plot.rows;
    const segments = trendSegments(displayPoints, resolution);
    const left = 42, right = 785, top = 12, bottom = 145, span = windowSeconds, start = asOf - span;
    const { minimum, maximum, last, change } = plot;
    const x = (point: SpeedTrendPoint) => left + (point.bucketStart - start) / span * (right - left);
    const y = (point: SpeedTrendPoint) => bottom - (point.tokensPerSecond - minimum) / (maximum - minimum) * (bottom - top);
    const color = modelUsageColor;
    return <section className={`body-speed-trend ${compact ? `bst-${compact}` : ""}`} aria-label="模型速度变化">
        <header><strong>速度变化</strong><span>{days === 1 ? "每点为5分钟均速 · TPS" : days === 7 ? "30分钟汇总 · 底层5分钟" : "2小时汇总 · 底层5分钟"}</span><div>{[86400,604800,2592000].map(value => <button key={value} aria-pressed={windowSeconds === value} onClick={() => setWindowSeconds(value)}>{value === 86400 ? "24小时" : value === 604800 ? "7天" : "30天"}</button>)}</div></header>
        <div className="bst-models"><button aria-pressed={focus == null} onClick={() => setSelectedModel("*")}>全部</button>{models.map(model => <button key={model} aria-pressed={focus === model} onClick={() => setSelectedModel(model)}><i style={{background:color(model)}}/>{model.replace(/^gpt-/, "")}</button>)}</div>
        <svg viewBox="0 0 800 170" role="img" aria-label="按模型区分的平均 TPS 趋势"><defs><clipPath id={id}><rect x={left} y={top} width={right - left} height={bottom - top}/></clipPath></defs>
            {[0, 1, 2, 3].map(tick => { const rate = minimum + (maximum - minimum) * tick / 3, at = bottom - (bottom - top) * tick / 3; return <g key={tick}><line x1={left} x2={right} y1={at} y2={at} className="bst-grid"/><text x={left - 7} y={at + 3} textAnchor="end">{rate.toFixed(0)}</text></g>; })}
            {[0, 1, 2, 3, 4].map(tick => { const at = start + span * tick / 4; return <text key={tick} x={left + (right - left) * tick / 4} y={163} textAnchor={tick === 0 ? "start" : tick === 4 ? "end" : "middle"}>{new Date(at * 1000).toLocaleString("zh-CN", days === 1 ? { hour: "2-digit", minute: "2-digit", hour12: false } : { month: "2-digit", day: "2-digit" })}</text>; })}
            <g clipPath={`url(#${id})`}>{segments.map((segment, i) => <g key={`${segment[0].model}/${i}`}><polyline points={segment.map(p => `${x(p)},${y(p)}`).join(" ")} fill="none" stroke={color(segment[0].model)} strokeWidth="1.8"/>{segment.map(p => <circle key={`${p.model}/${p.bucketStart}`} cx={x(p)} cy={y(p)} r="2.4" fill={color(p.model)}><title>{p.model} · {new Date(p.bucketStart * 1000).toLocaleString()} · {p.tokensPerSecond.toFixed(1)} TPS · {p.sampleCount}段正文 · {p.outputTokens} token / {p.durationSeconds.toFixed(2)}秒</title></circle>)}</g>)}</g>
            {!displayPoints.length && <text x="410" y="80" textAnchor="middle">等待合格正文采样 · 无数据时留空</text>}
        </svg>
        {focus && last && <div className="bst-summary"><strong>最近 {last.tokensPerSecond.toFixed(1)} TPS</strong>{change != null && <span data-up={change>=0}>首尾 {change>=0 ? "+" : ""}{change.toFixed(1)}%</span>}</div>}
        {error && <p role="status">{error}</p>}
    </section>;
}
