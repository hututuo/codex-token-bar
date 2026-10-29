import { useSpeedPalette } from "./useSpeedPalette";
import { useDocumentVisible } from "../useDocumentVisible";
import { invoke } from "@tauri-apps/api/core";
import { modelUsageColor } from "../modelUsagePresentation";
import { memo, useEffect, useId, useMemo, useState } from "react";
import type { CodexHomeSourceToken } from "../../types/platform";
import type { QuotaAttributionIdentity, QuotaCycle } from "../../types/quota";

export interface SpeedTrendPoint {
    bucketStart: number; model: string; outputTokens: number; durationSeconds: number;
    sampleCount: number; tokensPerSecond: number;
    bucketEnd?: number | null; lowerQuartile?: number | null; median?: number | null;
    upperQuartile?: number | null; bucketCount?: number | null; isPartial?: boolean | null;
}
export interface SpeedResetMarker { observedAt: number; previousAt: number }
export function speedTrendResets(cycles: QuotaCycle[]): SpeedResetMarker[] {
    // Accepted cycle starts exclude withdrawn cuts. Schedules and unknown first starts are not resets.
    return cycles.flatMap(c => c.startUpperUnix != null && Number.isFinite(c.startUpperUnix) ? [{
        observedAt: c.startUpperUnix, previousAt: Number.isFinite(c.startLowerUnix) ? c.startLowerUnix! : c.startUpperUnix,
    }] : []).sort((a,b) => a.observedAt-b.observedAt);
}
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
    const rows = points.filter(p => Number.isFinite(p.tokensPerSecond) && p.tokensPerSecond > 0 && p.bucketStart >= asOf - windowSeconds && p.bucketStart <= asOf && (model == null || p.model === model)).sort((a,b)=>a.bucketStart-b.bucketStart || a.model.localeCompare(b.model));
    const low = rows.length ? Math.min(...rows.map(p=>p.tokensPerSecond)) : 0;
    const high = rows.length ? Math.max(...rows.map(p=>p.tokensPerSecond)) : 10;
    const padding = Math.max(5,(high-low)*.2);
    return { rows, minimum: Math.max(0,low-padding), maximum: Math.max(10,high+padding), last: rows.at(-1) };
}
interface TrendProps {
    sourceToken: CodexHomeSourceToken | null; revision: string; compact?: "detail"; preferredModel?: string;
    quotaIdentity?: QuotaAttributionIdentity | null; quotaUpdatedAt?: string | null;
}
function BodySpeedTrendView({ sourceToken, revision, compact, preferredModel, quotaIdentity, quotaUpdatedAt }: TrendProps) {
    useSpeedPalette();
    const visible = useDocumentVisible();
    const [windowSeconds, setWindowSeconds] = useState(86400);
    const days = windowSeconds === 86400 ? 1 : windowSeconds === 604800 ? 7 : 30;
    const [selectedModel, setSelectedModel] = useState<string | null>(null);
    const [points, setPoints] = useState<SpeedTrendPoint[]>([]);
    const [resets, setResets] = useState<SpeedResetMarker[]>([]);
    const [error, setError] = useState<string | null>(null);
    const [markerError, setMarkerError] = useState(false);
    const [asOf, setAsOf] = useState(Date.now() / 1000);
    const key = JSON.stringify(sourceToken), id = useId();
    const scope = quotaIdentity ? `${quotaIdentity.scopeKey}|${quotaIdentity.plan}|${quotaIdentity.limit}` : null;
    useEffect(() => { setPoints([]); setError(null); }, [key]);
    useEffect(() => {
        setResets([]); setMarkerError(false);
        if (!sourceToken || !scope || !visible) return;
        let disposed = false;
        // Local accepted-cycle read only, driven by existing quota refreshes. No quota request/timer.
        void invoke<QuotaCycle[]>("read_quota_cycles", { sourceToken, expectedScope: scope }).then(cycles => {
            if (!disposed) setResets(speedTrendResets(cycles));
        }).catch(()=>{ if (!disposed) setMarkerError(true); });
        return () => { disposed = true; };
    }, [key, scope, quotaUpdatedAt, visible]);
    useEffect(() => {
        if (!sourceToken || !visible) return;
        let disposed = false, busy = false;
        const read = async () => {
            if (busy || document.hidden) return; busy = true;
            try {
                const rows = await invoke<SpeedTrendPoint[]>("read_body_speed_trend", { sourceToken, days, curve: true });
                if (!disposed) { setPoints(rows); setAsOf(Date.now() / 1000); setError(null); }
            } catch (e) { if (!disposed) setError(`趋势读取失败：${String(e)}`); }
            finally { busy = false; }
        };
        const start = window.setTimeout(() => void read(), 150), timer = window.setInterval(() => void read(), 60_000);
        return () => { disposed = true; window.clearTimeout(start); window.clearInterval(timer); };
    }, [key, days, revision, visible]);
    const validPoints = useMemo(()=>points.filter(p=>Number.isFinite(p.tokensPerSecond)&&p.tokensPerSecond>0),[points]);
    const models = useMemo(() => [...new Set(validPoints.filter(p=>p.bucketStart >= asOf-windowSeconds && p.bucketStart<=asOf).map(p=>p.model))].sort(), [validPoints, asOf, windowSeconds]);
    const preferred = preferredModel && models.includes(preferredModel) ? preferredModel : models[0];
    const modelKey = models.join("|");
    useEffect(() => { if (selectedModel !== "*" && (!selectedModel || !models.includes(selectedModel))) setSelectedModel(preferred ?? null); }, [modelKey, preferred, selectedModel]);
    const focus = selectedModel === "*" ? null : selectedModel && models.includes(selectedModel) ? selectedModel : preferred;
    const plot = useMemo(() => trendPlot(validPoints, asOf, windowSeconds, focus ?? null), [validPoints, asOf, windowSeconds, focus]);
    const visibleResets = useMemo(()=>resets.filter(r=>r.observedAt >= asOf-windowSeconds && r.observedAt<=asOf),[resets,asOf,windowSeconds]);
    const caption = `${days === 1 ? "5分钟" : days === 7 ? "30分钟" : "2小时"}加权均速 · TPS`;
    return <section className={`body-speed-trend ${compact ? `bst-${compact}` : ""}`} aria-label="模型速度变化">
        <header><strong>速度变化</strong><span>{caption}</span><div>{[86400,604800,2592000].map(value => <button key={value} aria-pressed={windowSeconds === value} onClick={() => setWindowSeconds(value)}>{value === 86400 ? "24小时" : value === 604800 ? "7天" : "30天"}</button>)}</div></header>
        <div className="bst-models"><button aria-pressed={focus == null} onClick={() => setSelectedModel("*")}>全部</button>{models.map(model => <button key={model} aria-pressed={focus === model} onClick={() => setSelectedModel(model)}><i style={{background:modelUsageColor(model)}}/>{model.replace(/^gpt-/, "")}</button>)}</div>
        <SpeedTrendPlot points={plot.rows} minimum={plot.minimum} maximum={plot.maximum} asOf={asOf} windowSeconds={windowSeconds} days={days} resets={visibleResets} clipId={id}/>
        {focus && plot.last && <div className="bst-summary"><strong>最近区间均速 {plot.last.tokensPerSecond.toFixed(1)} TPS</strong></div>}
        <p className="bst-explanation">悬停或点击查看时间、Token、耗时和正文段数；无采样的时段断线。</p>
        {visibleResets.length>0 && <p className="bst-explanation">蓝线为额度回升首次观测；实际重置可能更早。</p>}
        {markerError && <p role="status">额度标记暂不可用</p>}
        {error && <p role="status">{error}</p>}
    </section>;
}

// Selection stays in this small chart; a pointer move never repeats database reads/projection.
export function SpeedTrendPlot({points,minimum,maximum,asOf,windowSeconds,days,resets,clipId}: {
    points: SpeedTrendPoint[]; minimum: number; maximum: number; asOf: number; windowSeconds: number;
    days: number; resets: SpeedResetMarker[]; clipId: string;
}) {
    const [selectedTime,setSelectedTime]=useState<number | null>(null);
    const left=44,right=785,top=21,bottom=157,start=asOf-windowSeconds;
    const x=(t:number)=>left+(t-start)/windowSeconds*(right-left);
    const y=(v:number)=>bottom-(v-minimum)/(maximum-minimum)*(bottom-top);
    const resolution=days===1?300:days===7?1800:7200;
    const segments=useMemo(()=>trendSegments(points,resolution),[points,resolution]);
    const selected=selectedTime == null ? [] : points.filter(p=>p.bucketStart<=selectedTime&&selectedTime<p.bucketStart+resolution);
    const palette=useSpeedPalette();
    // Hover only updates the small readout, not all historical point/title nodes.
    const curves=useMemo(()=>(segments.map((segment,index)=><g key={`${segment[0].model}/${index}`} className="bst-curve-segment">
                    <polyline points={segment.map(p=>`${x(p.bucketStart)},${y(p.tokensPerSecond)}`).join(" ")} fill="none" stroke={modelUsageColor(segment[0].model)} strokeWidth="1.8"/>
                    {segment.map(p=><circle key={`${p.model}/${p.bucketStart}`} cx={x(p.bucketStart)} cy={y(p.tokensPerSecond)} r="2.2" fill={modelUsageColor(p.model)}><title>{curveLabel(p)}</title></circle>)}
                </g>)),[segments,minimum,maximum,start,windowSeconds,palette]);
    const select=(event:React.PointerEvent<SVGSVGElement>)=>{
        const bounds=event.currentTarget.getBoundingClientRect();
        if (!bounds.width) return;
        const position=(event.clientX-bounds.left)/bounds.width*800;
        setSelectedTime(position>=left && position<=right ? start+(position-left)/(right-left)*windowSeconds : null);
    };
    return <>
        <svg viewBox="0 0 800 188" role="img" aria-label="按模型区分的平均 TPS 趋势" onPointerMove={select} onPointerDown={select} onPointerLeave={()=>setSelectedTime(null)}>
            <defs><clipPath id={clipId}><rect x={left} y={top} width={right-left} height={bottom-top}/></clipPath></defs>
            {[0,1,2,3].map(tick=>{const value=minimum+(maximum-minimum)*tick/3,at=y(value);return <g key={tick}><line x1={left} x2={right} y1={at} y2={at} className="bst-grid"/><text x={left-7} y={at+3} textAnchor="end">{value.toFixed(0)}</text></g>;})}
            {[0,1,2,3,4].map(tick=>{const t=start+windowSeconds*tick/4;return <text key={tick} x={x(t)} y="180" textAnchor={tick===0 ? "start" : tick===4 ? "end" : "middle"}>{new Date(t*1000).toLocaleString("zh-CN",days===1 ? {hour:"2-digit",minute:"2-digit",hour12:false} : {month:"2-digit",day:"2-digit"})}</text>;})}
            <g clipPath={`url(#${clipId})`}>
                {resets.map(r=><g key={r.observedAt} className="bst-reset"><rect x={x(Math.max(start,r.previousAt))} y={top} width={Math.max(0,x(r.observedAt)-x(Math.max(start,r.previousAt)))} height={bottom-top} fill="#48bfff" fillOpacity=".07"/><line x1={x(r.observedAt)} x2={x(r.observedAt)} y1={top} y2={bottom} stroke="#48bfff" strokeDasharray="3 3" strokeWidth="1"/><title>{`额度回升首次观测 ${new Date(r.observedAt*1000).toLocaleString()}；可定位区间 ${new Date(r.previousAt*1000).toLocaleString()} 至该时刻`}</title></g>)}
                {curves}
            </g>
            {resets.length>0 && <text className="bst-reset-label" x={Math.min(right-120,Math.max(left,x(resets.at(-1)!.observedAt)+5))} y="12">额度回升 {new Date(resets.at(-1)!.observedAt*1000).toLocaleTimeString("zh-CN",{hour:"2-digit",minute:"2-digit",hour12:false})}</text>}
            {!points.length && <text x="410" y="90" textAnchor="middle">等待合格正文采样 · 无数据时留空</text>}
        </svg>
        <div className="bst-selection" aria-live="polite">{selectedTime == null ? "\u00a0" : selected.length ? selected.map(p=><span key={`${p.model}/${p.bucketStart}`}>{curveLabel(p)}</span>) : "该时段没有合格采样"}</div>
    </>;
}
export function curveLabel(p:SpeedTrendPoint) {
    return `${new Date(p.bucketStart*1000).toLocaleString("zh-CN")} · ${p.model} · ${p.tokensPerSecond.toFixed(1)} TPS · ${p.sampleCount}段正文 · ${p.outputTokens} token / ${p.durationSeconds.toFixed(2)}秒`;
}
export const BodySpeedTrend=memo(BodySpeedTrendView,(a,b)=>a.revision===b.revision && a.compact===b.compact && a.preferredModel===b.preferredModel && a.quotaUpdatedAt===b.quotaUpdatedAt && a.quotaIdentity?.scopeKey===b.quotaIdentity?.scopeKey && a.quotaIdentity?.plan===b.quotaIdentity?.plan && a.quotaIdentity?.limit===b.quotaIdentity?.limit && a.sourceToken?.canonicalHomeKey===b.sourceToken?.canonicalHomeKey && a.sourceToken?.physicalHomeKey===b.sourceToken?.physicalHomeKey && a.sourceToken?.transitionGeneration===b.sourceToken?.transitionGeneration);
