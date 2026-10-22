import { BodySpeedTrend } from "./BodySpeedTrend";
import { createPortal } from "react-dom";
import { useBodySpeedDetailsRequests } from "./bodySpeedDetailsBridge";
import { invoke } from "@tauri-apps/api/core";
import { Fragment, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useObservedSpeedWindow } from "./observedSpeedWindow";
import { bodyTypeLabel } from "./bodySpeedQuality";
import { bodySpeedStatus, modelSpeedReadings, recentBodySpeedSamples, speedTimestamp } from "./bodySpeedPresentation";
import type { LiveThreadOption, ModelSpeedSummary, SpeedSample } from "../../types/live";
import type { CodexHomeSourceToken } from "../../types/platform";
export interface ObservedSpeedData {
    modelSpeeds?: ModelSpeedSummary[];
    modelSpeeds15m?: ModelSpeedSummary[];
    modelSpeeds30m?: ModelSpeedSummary[];
    speedSamples?: SpeedSample[];
    measurementStatus?: string;
    latestModelSpeeds30m?: ModelSpeedSummary[];
}
interface HistoryPage {
    samples: SpeedSample[];
    totalCount: number;
    nextOffset: number | null;
    asOf: number;
    retentionDays: number;
    error: string | null;
    threadTitles?: Record<string, string>;
}
function BodyTable({ samples, threads, threadTitles, compact = false }: {
    samples: SpeedSample[];
    threads: LiveThreadOption[];
    threadTitles?: Record<string, string>;
    compact?: boolean;
}) {
    const [expanded, setExpanded] = useState<string | null>(null);
    const titles = useMemo(() => new Map([...Object.entries(threadTitles ?? {}), ...threads.map(t => [t.id, t.title] as const)]), [threads, threadTitles]);
    return <div className="body-speed-table-scroll"><table className={`body-speed-table${compact ? " body-speed-table-compact" : ""}`}><thead><tr>{["采样时间", "会话 / 轮次", "正文 ID", "类型", "token", "秒", "TPS", "采样状态"].map(t => <th key={t}>{t}</th>)}</tr></thead><tbody>{samples.map(s => {
            const q = bodySpeedStatus(s), title = titles.get(s.threadId) || s.threadId.slice(0, 12);
            return <Fragment key={s.id}><tr><td><time title={new Date(s.endedAt * 1000).toLocaleString()}>{speedTimestamp(s.endedAt)}</time></td><td title={`${title}\n会话 ${s.threadId}\n轮次 ${s.turnId}`}><span className="body-speed-session">{title}</span><small>轮 {s.turnId.slice(-6)} · {s.model?.replace("gpt-", "") || "未知模型"}</small></td><td><button className="body-speed-id" title={s.itemId} aria-expanded={expanded === s.id} onClick={() => setExpanded(expanded === s.id ? null : s.id)}>{s.itemId.slice(-9)}</button></td><td>{bodyTypeLabel(s)}</td><td>{s.outputTokens.toLocaleString()}</td><td>{s.durationSeconds.toFixed(2)}</td><td className="body-speed-tps">{s.tokensPerSecond.toFixed(1)}</td><td><span data-confidence={q.confidence} title={q.reason || "计入模型均速"}>{q.label}</span></td></tr>{expanded === s.id && <tr className="body-speed-expanded"><td colSpan={8}><dl><dt>会话 ID</dt><dd>{s.threadId}</dd><dt>轮次 ID</dt><dd>{s.turnId}</dd><dt>正文 ID</dt><dd>{s.itemId}</dd></dl><span>{new Date(s.endedAt * 1000).toLocaleString()} · {q.reason ? `${q.reason}，不计均速` : "计入模型均速"}</span></td></tr>}</Fragment>;
        })}</tbody></table>{!samples.length && <p className="observed-speed-empty">等待正文完成</p>}</div>;
}
function BodyHistory({ sourceToken, threads, onClose }: {
    sourceToken: CodexHomeSourceToken;
    threads: LiveThreadOption[];
    onClose: () => void;
}) {
    const dialog = useRef<HTMLDialogElement>(null), anchor = useRef<number | null>(null);
    // The parent keys this panel by source identity. Live snapshot object churn
    // must not reread the history page on every dashboard refresh.
    const historySource = useRef(sourceToken).current;
    const requestedRetention = useRef<number | undefined>(undefined);
    const [page, setPage] = useState<HistoryPage | null>(null);
    const [offset, setOffset] = useState(0), [revision, setRevision] = useState(0);
    const [failure, setFailure] = useState<string | null>(null);
    useEffect(() => { dialog.current?.showModal(); return () => dialog.current?.close(); }, []);
    useEffect(() => {
        let disposed = false;
        void invoke<HistoryPage>("read_body_speed_history", {
            sourceToken: historySource, offset, limit: 50, asOf: anchor.current, retentionDays: requestedRetention.current,
        }).then(result => {
            if (disposed) return;
            anchor.current = result.asOf;
            requestedRetention.current = undefined;
            setPage(result); setFailure(null);
        }).catch(error => { if (!disposed) setFailure(String(error)); });
        return () => { disposed = true; };
    }, [historySource, offset, revision]);
    const refresh = () => { anchor.current = null; setOffset(0); setRevision(v => v + 1); };
    return <dialog ref={dialog} className="body-speed-history" onCancel={onClose} aria-label="全部正文记录">
        <header>
            <h3>正文记录 <small>{page?.totalCount ?? 0} 条</small></h3>
            <div>
                <label>保留 <select value={page?.retentionDays ?? 30} onChange={event => { requestedRetention.current = Number(event.target.value); refresh(); }}>
                    <option value={15}>15 天</option><option value={30}>30 天</option>
                </select></label>
                <button onClick={refresh}>刷新</button><button onClick={onClose}>关闭</button>
            </div>
        </header>
        <div className="body-speed-history-status"><span>最近 {page?.retentionDays ?? 30} 天已收集的正文</span><span>低置信度不计均速</span></div>
        {(failure || page?.error) && <p className="observed-speed-warning">{failure || page?.error}</p>}
        <div className="body-speed-history-content"><BodyTable samples={page?.samples ?? []} threads={threads} threadTitles={page?.threadTitles}/></div>
        <footer><span>点击正文 ID 查看完整定位</span><div>
            <button disabled={offset === 0} onClick={() => setOffset(Math.max(0, offset - 50))}>上一页</button>
            <span>{Math.floor(offset / 50) + 1} / {Math.max(1, Math.ceil((page?.totalCount ?? 0) / 50))}</span>
            <button disabled={page?.nextOffset == null} onClick={() => setOffset(page?.nextOffset ?? offset)}>下一页</button>
        </div></footer>
    </dialog>;
}

export function ObservedSpeedDetails({ data, threads = [], sourceToken = null, surface = "home" }: {
    data: ObservedSpeedData;
    threads?: LiveThreadOption[];
    sourceToken?: CodexHomeSourceToken | null;
    surface?: "home" | "sidebar";
}) {
    const [history, setHistory] = useState(false), [minutes, setMinutes] = useObservedSpeedWindow();
    const [detailsFailure, setDetailsFailure] = useState<string | null>(null);
    const sourceKey = sourceToken ? JSON.stringify(sourceToken) : "";
    const openHistory = useCallback(() => { setHistory(true); setDetailsFailure(null); }, []);
    const reportFailure = useCallback((error: string) => setDetailsFailure(`详情打开失败：${error}`), []);
    useEffect(() => { setHistory(false); setDetailsFailure(null); }, [sourceKey]);
    useBodySpeedDetailsRequests(surface === "home", sourceKey, openHistory, reportFailure);
    const openDetails = async () => {
        if (surface === "home") { openHistory(); return; }
        try { await invoke("open_body_speed_details"); setDetailsFailure(null); }
        catch (error) { reportFailure(String(error)); }
    };
    const limit = surface === "sidebar" ? 10 : 6;
    const recentModels = (minutes === 15 ? data.modelSpeeds15m : data.modelSpeeds30m) ?? [];
    const models = useMemo(() => modelSpeedReadings(recentModels, data.modelSpeeds ?? []), [recentModels, data.modelSpeeds]);
    const samples = useMemo(() => recentBodySpeedSamples(data.speedSamples ?? [], limit), [data.speedSamples, limit]);
    const titles = useMemo(() => new Map(threads.map(t => [t.id, t.title])), [threads]);
    return <section className={`observed-speed body-speed-surface-${surface}`} aria-label="正文测速" id="qs-section-speeds">
        <div className="observed-speed-heading body-speed-overview-heading">
            <h3>{surface === "sidebar" ? <>各模型最新速度 <small>正文 TPS</small></> : <>正文测速 <small>TPS · token/秒</small></>}</h3>
            <button className="body-speed-more-details" onClick={() => { void invoke("open_modeltrace").catch(error => setDetailsFailure(String(error))); }}>模型指纹 · 手动检测</button>
            {surface === "home" && <div className="observed-speed-window">{([15, 30] as const).map(v => <button key={v} type="button" aria-pressed={minutes === v} onClick={() => setMinutes(v)}>最近 {v} 分钟</button>)}</div>}
        </div>
        {surface === "home" ? <div className="body-speed-overview-models" aria-label="各模型平均速度">
            {models.map(m => <article className="body-speed-model" key={m.model} data-historical={m.historical}>
                <strong>{m.model}</strong><b>{m.tokensPerSecond.toFixed(1)} <small>TPS</small></b>
                <span>{m.historical ? "近7天均速" : `近${minutes}分钟均速`} · {m.sampleCount}条</span>
                <time title={m.lastMeasuredAt ? new Date(m.lastMeasuredAt * 1000).toLocaleString() : undefined}>末次 {speedTimestamp(m.lastMeasuredAt)}</time>
            </article>)}
            {!models.length && <p className="observed-speed-empty">暂无合格模型读数</p>}
        </div> : <div className="body-speed-sidebar-models" aria-label="各模型最新速度">
            <div className="body-speed-sidebar-model-head"><span>模型</span><span>最新</span><span>15min均速</span><span>30min均速</span></div>
            {(data.latestModelSpeeds30m ?? []).map(m => <div className="body-speed-sidebar-model-row" key={m.model}>
                <strong title={m.model}>{m.model.replace(/^gpt-/, "")}</strong><b title={`最新合格正文 · ${speedTimestamp(m.lastMeasuredAt)}`}>{m.tokensPerSecond.toFixed(1)}</b>
                <span>{data.modelSpeeds15m?.find(s => s.model === m.model)?.tokensPerSecond.toFixed(1) ?? "—"}</span>
                <span>{data.modelSpeeds30m?.find(s => s.model === m.model)?.tokensPerSecond.toFixed(1) ?? "—"}</span>
            </div>)}
            {!data.latestModelSpeeds30m?.length && <p className="observed-speed-empty">近30分钟暂无合格读数</p>}
        </div>}
        {surface === "home" && <BodySpeedTrend sourceToken={sourceToken} revision={(data.speedSamples ?? []).map(s => `${s.id}/${s.model}/${s.confidence}`).join("|")}/>}
        <div className="body-speed-recent-heading"><span>最近{limit}条{surface === "home" ? " · 已识别模型" : ""}</span>{surface === "home" && <button disabled={!sourceToken} onClick={() => void openDetails()}>查看详情</button>}</div>
        <ol className="body-speed-recent-list" aria-label="最近测速">{samples.map(s => {
            const status = bodySpeedStatus(s), title = titles.get(s.threadId) || s.threadId.slice(0, 12);
            return <li key={s.id} data-included={status.included} title={`会话 ${s.threadId}\n轮次 ${s.turnId}\n正文 ${s.itemId}\n${status.reason ?? "计入模型均速"}`}>
                <time className="body-speed-recent-time" title={new Date(s.endedAt * 1000).toLocaleString()}>{speedTimestamp(s.endedAt)}</time>
                <div className="body-speed-recent-source"><strong>{s.model?.replace(/^gpt-/, "")}</strong><small className="body-speed-recent-type">{bodyTypeLabel(s)}</small><small className="body-speed-recent-session" title={title}>{title}</small><small className="body-speed-recent-quantity">{s.outputTokens} token / {s.durationSeconds.toFixed(2)}秒</small></div>
                <b>{s.tokensPerSecond.toFixed(1)} <small>TPS</small></b>
                <span className="body-speed-recent-status" data-included={status.included}>{status.label}</span>
            </li>;
        })}</ol>
        {!samples.length && <p className="observed-speed-empty">等待带模型的正文测速</p>}
        {data.measurementStatus === "observed_storage_error" && <p className="observed-speed-warning">测速记录读写失败，原文件已保留。</p>}
        {surface === "sidebar" && <button className="body-speed-more-details" disabled={!sourceToken} onClick={() => void openDetails()}>打开详细信息 ↗</button>}
        {detailsFailure && <p className="observed-speed-warning" role="alert">{detailsFailure}</p>}
        {surface === "home" && history && sourceToken && createPortal(<BodyHistory key={sourceKey} sourceToken={sourceToken} threads={threads} onClose={() => setHistory(false)}/>, document.body)}
    </section>;
}
