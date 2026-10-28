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
export function isDistribution(p: SpeedTrendPoint): boolean {
    return Number.isFinite(p.bucketStart) && Number.isFinite(p.bucketEnd) && p.bucketEnd! > p.bucketStart &&
        Number.isFinite(p.lowerQuartile) && Number.isFinite(p.median) && Number.isFinite(p.upperQuartile) &&
        p.lowerQuartile! > 0 && p.lowerQuartile! <= p.median! && p.median! <= p.upperQuartile! &&
        (p.bucketCount ?? 0) >= 3 && p.sampleCount >= 6;
}
export function distributionResets(cycles: QuotaCycle[]): SpeedResetMarker[] {
    // Accepted cycle starts exclude withdrawn cuts. Schedules and unknown first starts are not resets.
    return cycles.flatMap(c => c.startUpperUnix != null && Number.isFinite(c.startUpperUnix) ? [{
        observedAt: c.startUpperUnix, previousAt: Number.isFinite(c.startLowerUnix) ? c.startLowerUnix! : c.startUpperUnix,
    }] : []).sort((a,b) => a.observedAt-b.observedAt);
}
export function trendPlot(points: SpeedTrendPoint[], asOf: number, windowSeconds: number, model: string | null) {
    const rows = points.filter(p => isDistribution(p) && p.bucketEnd! > asOf - windowSeconds && p.bucketStart < asOf && (model == null || p.model === model)).sort((a,b)=>a.bucketStart-b.bucketStart || a.model.localeCompare(b.model));
    const low = rows.length ? Math.min(...rows.map(p=>p.lowerQuartile!)) : 0;
    const high = rows.length ? Math.max(...rows.map(p=>p.upperQuartile!)) : 10;
    const padding = Math.max(3,(high-low)*.15);
    return { rows, minimum: Math.max(0,low-padding), maximum: Math.max(10,high+padding), last: rows.at(-1) };
}
export function distributionsAt(points: SpeedTrendPoint[], time: number) {
    return points.filter(p=>p.bucketStart <= time && time < p.bucketEnd!);
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
            if (!disposed) setResets(distributionResets(cycles));
        }).catch(()=>{ if (!disposed) setMarkerError(true); });
        return () => { disposed = true; };
    }, [key, scope, quotaUpdatedAt, visible]);
    useEffect(() => {
        if (!sourceToken || !visible) return;
        let disposed = false, busy = false;
        const read = async () => {
            if (busy || document.hidden) return; busy = true;
            try {
                const rows = await invoke<SpeedTrendPoint[]>("read_body_speed_trend", { sourceToken, days });
                if (!disposed) { setPoints(rows); setAsOf(Date.now() / 1000); setError(null); }
            } catch (e) { if (!disposed) setError(`分布读取失败：${String(e)}`); }
            finally { busy = false; }
        };
        const start = window.setTimeout(() => void read(), 150), timer = window.setInterval(() => void read(), 60_000);
        return () => { disposed = true; window.clearTimeout(start); window.clearInterval(timer); };
    }, [key, days, revision, visible]);
    const validPoints = useMemo(()=>points.filter(isDistribution),[points]);
    const models = useMemo(() => [...new Set(validPoints.filter(p=>p.bucketEnd! > asOf-windowSeconds && p.bucketStart<asOf).map(p=>p.model))].sort(), [validPoints, asOf, windowSeconds]);
    const preferred = preferredModel && models.includes(preferredModel) ? preferredModel : models[0];
    const modelKey = models.join("|");
    useEffect(() => { if (selectedModel !== "*" && (!selectedModel || !models.includes(selectedModel))) setSelectedModel(preferred ?? null); }, [modelKey, preferred, selectedModel]);
    const focus = selectedModel === "*" ? null : selectedModel && models.includes(selectedModel) ? selectedModel : preferred;
    const plot = useMemo(() => trendPlot(validPoints, asOf, windowSeconds, focus ?? null), [validPoints, asOf, windowSeconds, focus]);
    const visibleResets = useMemo(()=>resets.filter(r=>r.observedAt >= asOf-windowSeconds && r.observedAt<=asOf),[resets,asOf,windowSeconds]);
    const caption = `${days === 1 ? "30分钟" : days === 7 ? "2小时" : "6小时"}分布 · P25–P75 / 中位数 · TPS`;
    return <section className={`body-speed-trend ${compact ? `bst-${compact}` : ""}`} aria-label="模型速度分布">
        <header><strong>速度分布</strong><span>{caption}</span><div>{[86400,604800,2592000].map(value => <button key={value} aria-pressed={windowSeconds === value} onClick={() => setWindowSeconds(value)}>{value === 86400 ? "24小时" : value === 604800 ? "7天" : "30天"}</button>)}</div></header>
        <div className="bst-models"><button aria-pressed={focus == null} onClick={() => setSelectedModel("*")}>全部</button>{models.map(model => <button key={model} aria-pressed={focus === model} onClick={() => setSelectedModel(model)}><i style={{background:modelUsageColor(model)}}/>{model.replace(/^gpt-/, "")}</button>)}</div>
        <SpeedDistributionPlot points={plot.rows} minimum={plot.minimum} maximum={plot.maximum} asOf={asOf} windowSeconds={windowSeconds} days={days} resets={visibleResets} clipId={id}/>
        {focus && plot.last && <div className="bst-summary"><strong>最近区间中位数 {plot.last.median!.toFixed(1)} TPS{plot.last.isPartial ? " · 区间未满" : ""}</strong></div>}
        <p className="bst-explanation">色带为五分钟均速的中间50%，横线为中位数；悬停或点击查看数值。空档留空。</p>
        {visibleResets.length>0 && <p className="bst-explanation">蓝线为额度回升首次观测；实际重置可能更早。</p>}
        {markerError && <p role="status">额度标记暂不可用</p>}
        {error && <p role="status">{error}</p>}
    </section>;
}

// Selection stays in this small chart; a pointer move never repeats database reads/projection.
export function SpeedDistributionPlot({points,minimum,maximum,asOf,windowSeconds,days,resets,clipId}: {
    points: SpeedTrendPoint[]; minimum: number; maximum: number; asOf: number; windowSeconds: number;
    days: number; resets: SpeedResetMarker[]; clipId: string;
}) {
    const [selectedTime,setSelectedTime]=useState<number | null>(null);
    const left=44,right=785,top=21,bottom=157,start=asOf-windowSeconds;
    const x=(t:number)=>left+(t-start)/windowSeconds*(right-left);
    const y=(v:number)=>bottom-(v-minimum)/(maximum-minimum)*(bottom-top);
    const selected=selectedTime == null ? [] : distributionsAt(points,selectedTime);
    const select=(event:React.PointerEvent<SVGSVGElement>)=>{
        const bounds=event.currentTarget.getBoundingClientRect();
        if (!bounds.width) return;
        const position=(event.clientX-bounds.left)/bounds.width*800;
        setSelectedTime(position>=left && position<=right ? start+(position-left)/(right-left)*windowSeconds : null);
    };
    return <>
        <svg viewBox="0 0 800 188" role="img" aria-label="正文 TPS 的 P25–P75 分布带和中位数" onPointerMove={select} onPointerDown={select} onPointerLeave={()=>setSelectedTime(null)}>
            <defs><clipPath id={clipId}><rect x={left} y={top} width={right-left} height={bottom-top}/></clipPath></defs>
            {[0,1,2,3].map(tick=>{const value=minimum+(maximum-minimum)*tick/3,at=y(value);return <g key={tick}><line x1={left} x2={right} y1={at} y2={at} className="bst-grid"/><text x={left-7} y={at+3} textAnchor="end">{value.toFixed(0)}</text></g>;})}
            {[0,1,2,3,4].map(tick=>{const t=start+windowSeconds*tick/4;return <text key={tick} x={x(t)} y="180" textAnchor={tick===0 ? "start" : tick===4 ? "end" : "middle"}>{new Date(t*1000).toLocaleString("zh-CN",days===1 ? {hour:"2-digit",minute:"2-digit",hour12:false} : {month:"2-digit",day:"2-digit"})}</text>;})}
            <g clipPath={`url(#${clipId})`}>
                {resets.map(r=><g key={r.observedAt} className="bst-reset"><rect x={x(Math.max(start,r.previousAt))} y={top} width={Math.max(0,x(r.observedAt)-x(Math.max(start,r.previousAt)))} height={bottom-top} fill="#48bfff" fillOpacity=".07"/><line x1={x(r.observedAt)} x2={x(r.observedAt)} y1={top} y2={bottom} stroke="#48bfff" strokeDasharray="3 3" strokeWidth="1"/><title>{`额度回升首次观测 ${new Date(r.observedAt*1000).toLocaleString()}；可定位区间 ${new Date(r.previousAt*1000).toLocaleString()} 至该时刻`}</title></g>)}
                {points.map(p=>{
                    const color=modelUsageColor(p.model),a=x(p.bucketStart),b=x(p.bucketEnd!);
                    const labelX=Math.max(left+14,Math.min(right-14,(Math.max(left,a)+Math.min(right,b))/2));
                    return <g key={`${p.model}/${p.bucketStart}`} className="bst-distribution">
                        <title>{distributionLabel(p)}</title>
                        <rect className="bst-band" x={a} y={y(p.upperQuartile!)} width={Math.max(.5,b-a)} height={Math.max(.5,y(p.lowerQuartile!)-y(p.upperQuartile!))} fill={color} fillOpacity=".25"/>
                        <line className="bst-median" x1={a} x2={b} y1={y(p.median!)} y2={y(p.median!)} stroke={color} strokeWidth="2.1" strokeDasharray={p.isPartial ? "3 2" : undefined}/>
                        <text className="bst-median-label" x={labelX} y={Math.max(top+10,y(p.median!)-5)} textAnchor="middle">{p.median!.toFixed(1)}</text>
                    </g>;
                })}
            </g>
            {resets.length>0 && <text className="bst-reset-label" x={Math.min(right-120,Math.max(left,x(resets.at(-1)!.observedAt)+5))} y="12">额度回升 {new Date(resets.at(-1)!.observedAt*1000).toLocaleTimeString("zh-CN",{hour:"2-digit",minute:"2-digit",hour12:false})}</text>}
            {!points.length && <text x="410" y="90" textAnchor="middle">等待分布采样 · 至少3个五分钟桶、6段正文</text>}
        </svg>
        <div className="bst-selection" aria-live="polite">{selectedTime == null ? "\u00a0" : selected.length ? selected.map(p=><span key={`${p.model}/${p.bucketStart}`}>{distributionLabel(p)}</span>) : "该时段没有足够分布采样"}</div>
    </>;
}
export function distributionLabel(p:SpeedTrendPoint) {
    return `${new Date(p.bucketStart*1000).toLocaleString("zh-CN")}–${new Date(p.bucketEnd!*1000).toLocaleTimeString("zh-CN")} · ${p.model} · 中位数 ${p.median!.toFixed(1)} TPS · P25–P75 ${p.lowerQuartile!.toFixed(1)}–${p.upperQuartile!.toFixed(1)} · ${p.bucketCount}桶 / ${p.sampleCount}段 · 加权均速 ${p.tokensPerSecond.toFixed(1)} TPS${p.isPartial ? " · 区间未满" : ""}`;
}
export const BodySpeedTrend=memo(BodySpeedTrendView,(a,b)=>a.revision===b.revision && a.compact===b.compact && a.preferredModel===b.preferredModel && a.quotaUpdatedAt===b.quotaUpdatedAt && a.quotaIdentity?.scopeKey===b.quotaIdentity?.scopeKey && a.quotaIdentity?.plan===b.quotaIdentity?.plan && a.quotaIdentity?.limit===b.quotaIdentity?.limit && a.sourceToken?.canonicalHomeKey===b.sourceToken?.canonicalHomeKey && a.sourceToken?.physicalHomeKey===b.sourceToken?.physicalHomeKey && a.sourceToken?.transitionGeneration===b.sourceToken?.transitionGeneration);
