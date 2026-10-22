import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useCallback, useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import type { CodexHomeSourceToken } from "../types/platform";

interface Candidate { model: string; displayName: string; probability: number }
interface Run { id: string; model: string; startedAt: number; completedAt: number | null; status: string; attempts: number; validSamples: number; message: string | null; attribution: { prediction: string; candidates: Candidate[] } | null }
interface AutoSettings { enabled: boolean; intervalHours: number; nextRunAt: number | null }
interface Snapshot { scopeKey: string; busy: boolean; models: string[]; runs: Run[]; settings: AutoSettings }
const status = (value: string) => ({ running: "检测中", completed: "已完成", cancelled: "已停止", interrupted: "已中断", failed: "未完成" }[value] ?? value);
const time = (value: number) => new Date(value * 1000).toLocaleString("zh-CN", { month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hour12: false });

export function ModelTraceContent({ sourceToken, onClose, compact = false }: { sourceToken: CodexHomeSourceToken; onClose?: () => void; compact?: boolean }) {
    const source = useRef(sourceToken).current;
    const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
    const [model, setModel] = useState("gpt-6.1-sol");
    const [selected, setSelected] = useState<string | null>(null);
    const [error, setError] = useState<string | null>(null);
    const [pending, setPending] = useState(false);
    const flight = useRef(false), mounted = useRef(false);
    const refresh = useCallback(async () => {
        if (flight.current) return;
        flight.current = true;
        try { const next = await invoke<Snapshot>("read_modeltrace_snapshot", { sourceToken: source }); if (mounted.current) { setSnapshot(next); setError(null); } }
        catch (e) { if (mounted.current) setError(String(e)); }
        finally { flight.current = false; }
    }, [source]);
    useEffect(() => {
        mounted.current = true; void refresh();
        const listener = listen("modeltrace-updated", () => void refresh());
        return () => { mounted.current = false; void listener.then(stop => stop()); };
    }, [refresh]);
    useEffect(() => { const timer = window.setInterval(() => void refresh(), snapshot?.busy ? 2_000 : 30_000); return () => window.clearInterval(timer); }, [refresh, snapshot?.busy]);
    const action = async (command: string, args: Record<string, unknown> = {}) => {
        setPending(true);
        try { await invoke(command, { sourceToken: source, ...args }); await refresh(); }
        catch (e) { setError(String(e)); }
        finally { setPending(false); }
    };
    const busy = pending || snapshot?.busy;
    const run = snapshot?.runs.find(r => r.id === selected) ?? snapshot?.runs[0];
    return <section className={compact ? "mt-sidebar" : "mt-content"} aria-label="模型指纹参考">
        <header><div><h2>模型指纹参考</h2><p>ModelTrace · 三份独立回答并行检测</p></div>{onClose && <button onClick={onClose} aria-label="关闭模型指纹">关闭</button>}</header>
        <div className="mt-actions"><label>请求模型 <select value={model} disabled={!!busy} onChange={e => setModel(e.target.value)}>{(snapshot?.models ?? ["gpt-6.1-sol"]).map(m => <option key={m}>{m}</option>)}</select></label><span>light · low</span><div className="mt-spacer"/>{snapshot?.busy ? <button disabled={pending} onClick={() => void action("cancel_modeltrace")}>停止</button> : <button className="mt-primary" disabled={!!busy || !snapshot} onClick={() => { setSelected(null); void action("start_modeltrace", { model }); }}>并行检测 3 次</button>}</div>
        <p className="mt-note">消耗当前 Codex 配置的额度。6.1 Sol 尚未收录，结果仅供特征比较，不能确认身份或排除 Luna。</p>
        {error && <p className="mt-error" role="alert">{error}</p>}
        <div className="mt-results"><nav aria-label="检测记录">{compact ? <label>检测记录 <select aria-label="选择检测记录" value={run?.id ?? ""} disabled={!snapshot?.runs.length} onChange={e => setSelected(e.target.value)}>{snapshot?.runs.length ? snapshot.runs.map(r => <option value={r.id} key={r.id}>{time(r.startedAt)} · {status(r.status)}</option>) : <option value="">暂无记录</option>}</select></label> : <><h3>检测记录</h3>{snapshot?.runs.map(r => <button key={r.id} aria-current={run?.id === r.id} onClick={() => setSelected(r.id)}><span>{time(r.startedAt)} · {status(r.status)}</span><strong>{r.model}</strong>{r.attribution && <small>更接近 {r.attribution.prediction}</small>}</button>)}{!snapshot?.runs.length && <p>暂无记录</p>}</>}</nav>
            <section aria-label="检测结果">{run ? <><div className="mt-result-title"><strong>{status(run.status)}</strong><span>已请求 {run.attempts}/3 · 有效 {run.validSamples}/3</span></div>{run.attribution?.candidates.slice(0, 5).map(c => <div className="mt-candidate" key={c.model}><div><span>{c.displayName}</span><strong>{(c.probability * 100).toFixed(1)}%</strong></div><meter value={c.probability} min={0} max={1} aria-label={`${c.displayName} 相对匹配分值`}/></div>)}{run.attribution && <p>相对匹配分值 · 不是身份正确率</p>}{run.message && <p>{run.message}</p>}</> : <p>选择模型后手动开始检测</p>}</section>
        </div>
        <footer><label className="mt-toggle"><input type="checkbox" checked={snapshot?.settings.enabled ?? false} disabled={!snapshot || pending} onChange={e => void action("save_modeltrace_auto_settings", { enabled: e.target.checked, intervalHours: snapshot?.settings.intervalHours ?? 24 })}/>自动检测</label><select aria-label="自动检测频率" value={snapshot?.settings.intervalHours ?? 24} disabled={!snapshot || pending} onChange={e => void action("save_modeltrace_auto_settings", { enabled: snapshot?.settings.enabled ?? false, intervalHours: Number(e.target.value) })}>{[1, 6, 12, 24, 48, 168].map(hours => <option key={hours} value={hours}>{hours === 24 ? "每天一次" : `每 ${hours} 小时`}</option>)}</select><span>默认关闭 · 每次并行请求 3 次</span></footer>
        {snapshot?.settings.enabled && snapshot.settings.nextRunAt && <p className="mt-note">下次：{time(snapshot.settings.nextRunAt)} · 默认 6.1 Sol / light</p>}
    </section>;
}

function ModelTracePanel({ sourceToken, onClose }: { sourceToken: CodexHomeSourceToken; onClose: () => void }) {
    const dialog = useRef<HTMLDialogElement>(null);
    useEffect(() => { const element = dialog.current; element?.showModal(); return () => element?.close(); }, []);
    return <dialog className="mt-panel" ref={dialog} onCancel={onClose}><ModelTraceContent sourceToken={sourceToken} onClose={onClose}/></dialog>;
}

/** Main-window modal host; the sidebar mounts the same content in its own page. */
export function ModelTraceHost({ sourceToken }: { sourceToken: CodexHomeSourceToken | null }) {
    const [open, setOpen] = useState(false);
    const key = JSON.stringify(sourceToken);
    useEffect(() => {
        setOpen(false);
        if (!sourceToken) return;
        let disposed = false;
        const take = () => { void invoke<boolean>("take_modeltrace_open_request").then(pending => { if (!disposed && pending) setOpen(true); }).catch(() => {}); };
        const listener = listen("modeltrace-open", take).then(stop => { if (disposed) stop(); else take(); return stop; });
        return () => { disposed = true; void listener.then(stop => stop()); };
    }, [key]);
    return open && sourceToken ? createPortal(<ModelTracePanel key={key} sourceToken={sourceToken} onClose={() => setOpen(false)}/>, document.body) : null;
}
