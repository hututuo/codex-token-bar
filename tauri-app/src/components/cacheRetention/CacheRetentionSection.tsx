import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import type { CodexHomeSourceToken } from "../../types/dashboard";
import { readCacheRetentionSnapshot, refreshCacheRetentionSnapshot, type CacheRetentionSnapshot } from "../../api/cacheRetentionClient";
import { calculateCacheRetention, formatRetentionCoverage, formatRetentionMinutes, formatRetentionRecommendation, formatRetentionRisk } from "../../domain/cacheRetention/analysis";
import type { CacheRetentionAnalysis } from "../../domain/cacheRetention/types";
import { desktopPlatform } from "../../platform/desktop";
import { emitPlatformEventTo, listenToEvent } from "../../platform/desktopBridge";
import { CacheRetentionChart } from "./CacheRetentionChart";

const OPEN_EVENT = "open-cache-retention-chart";
const RetentionContext = createContext<{ analysis: CacheRetentionAnalysis; open: () => void } | null>(null);

export function useRetentionRecommendation() { return useContext(RetentionContext); }

export async function openRetentionFromSurface() {
  await desktopPlatform.showDashboardWindow();
  await emitPlatformEventTo("main", OPEN_EVENT, "open-cache-retention-chart");
}

export function CacheRetentionProvider({ sourceToken, children }: { sourceToken: CodexHomeSourceToken | null; children: ReactNode }) {
  // A keyed owner clears every old-home fact synchronously on a source change.
  return <RetentionOwner key={JSON.stringify(sourceToken)} sourceToken={sourceToken}>{children}</RetentionOwner>;
}

function RetentionOwner({ sourceToken, children }: { sourceToken: CodexHomeSourceToken | null; children: ReactNode }) {
  const [all, setAll] = useState<CacheRetentionSnapshot | null>(null);
  const [scoped, setScoped] = useState<CacheRetentionSnapshot | null>(null);
  const [days, setDays] = useState<number | null>(null);
  const [model, setModel] = useState<string | null>(null);
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState("正在读取本机续问历史");
  const alive = useRef(true), loading = useRef(false), request = useRef(0);
  const allAnalysis = useMemo(() => calculateCacheRetention(all?.points ?? []), [all]);
  const snapshot = days === null && model === null ? all : scoped;
  const analysis = useMemo(() => calculateCacheRetention(snapshot?.points ?? []), [snapshot]);

  const refresh = useCallback(async () => {
    if (!sourceToken || loading.current) return;
    loading.current = true; setBusy(true); setStatus("正在更新本机续问历史，图表仍可查看");
    try {
      const result = await refreshCacheRetentionSnapshot(sourceToken);
      if (!alive.current) return;
      setAll(result);
      setStatus(result.failures ? `已更新可读取历史 · ${result.failures} 个来源稍后重试` : "本机历史已更新");
    } catch (error) {
      if (alive.current) setStatus(`续问建议暂未更新：${String(error)}`);
    } finally {
      loading.current = false;
      if (alive.current) setBusy(false);
    }
  }, [sourceToken]);

  useEffect(() => {
    alive.current = true;
    if (!sourceToken) { setStatus("请先选择 Codex 数据目录"); return; }
    void readCacheRetentionSnapshot(sourceToken).then(result => {
      if (alive.current && !loading.current) setAll(result);
    }).catch(() => {}).finally(() => { if (alive.current) void refresh(); });
    const timer = window.setInterval(() => { if (!document.hidden) void refresh(); }, 180_000);
    return () => { alive.current = false; window.clearInterval(timer); };
  }, [sourceToken, refresh]);

  useEffect(() => {
    const id = ++request.current;
    setScoped(null);
    if (days === null && model === null || !sourceToken) return;
    void readCacheRetentionSnapshot(sourceToken, days, model).then(result => {
      if (alive.current && id === request.current) setScoped(result);
    }).catch(error => { if (alive.current && id === request.current) setStatus(String(error)); });
  }, [days, model, sourceToken, all?.revision]);

  useEffect(() => {
    let stop: (() => void) | undefined, disposed = false;
    void listenToEvent(OPEN_EVENT, () => setOpen(true)).then(unlisten => { if (disposed) unlisten(); else stop = unlisten; });
    return () => { disposed = true; stop?.(); };
  }, []);

  useEffect(() => {
    if (!open) return;
    const previous = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    const close = (event: KeyboardEvent) => {
      if (event.key === "Escape") setOpen(false);
      if (event.key !== "Tab") return;
      const dialog = document.querySelector<HTMLElement>(".retention-dialog");
      const items = dialog?.querySelectorAll<HTMLElement>('button:not(:disabled),select,a[href],input:not(:disabled)');
      if (!items?.length) return;
      const first = items[0]!, last = items[items.length - 1]!;
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
    };
    window.addEventListener("keydown", close);
    return () => { window.removeEventListener("keydown", close); previous?.focus(); };
  }, [open]);

  return <RetentionContext.Provider value={{ analysis: allAnalysis, open: () => setOpen(true) }}>
    {children}
    {open && <div className="retention-overlay" onClick={event => { if (event.target === event.currentTarget) setOpen(false); }}>
      <section role="dialog" aria-modal="true" aria-labelledby="retention-heading" className="retention-dialog">
        <header className="retention-header"><div><small>本机历史 · 缓存续问建议</small><h2 id="retention-heading">隔多久续问，更容易命中缓存？</h2></div><button autoFocus type="button" onClick={() => setOpen(false)} aria-label="关闭续问图表">关闭 ×</button></header>
        <p className="retention-subtitle">每个点是一轮续问：上一轮结束到本轮开始的间隔，对应本轮首个请求的命中率。</p>
        <div className="retention-controls"><label>模型 <select value={model ?? ""} onChange={event => setModel(event.target.value || null)}><option value="">全部模型</option>{(all?.models ?? []).map(value => <option key={value}>{value}</option>)}</select></label><label>时间 <select value={days ?? "all"} onChange={event => setDays(event.target.value === "all" ? null : Number(event.target.value))}><option value="all">全部历史</option><option value="30">最近 30 天</option><option value="7">最近 7 天</option></select></label><button type="button" disabled={busy || !sourceToken} onClick={() => void refresh()}>{busy ? "正在更新…" : "更新历史"}</button><span>{status}</span></div>
        <div className="retention-lines"><div className="retention-line retention-recommended"><span>推荐续问线</span><strong>{analysis.earlierDecline ? `约 ${formatRetentionMinutes(analysis.earlierDecline.microseconds)}以内` : "样本还不足以给出建议"}</strong><small>尽量在这之前继续聊；高命中比例第一次明显下降的位置。</small></div><div className="retention-line retention-risk"><span>最晚参考线</span><strong>{analysis.dropMicroseconds === null ? "暂未找到明显分界" : `约 ${formatRetentionMinutes(analysis.dropMicroseconds)}`}</strong><small>超过这里，低命中更常见；它不是缓存有效期的保证。</small></div></div>
        {snapshot === null ? <div className="retention-empty">正在读取所选范围…</div> : analysis.p95State === "range_too_large" ? <div className="retention-empty">所选范围超过 100,000 轮，请选择模型或缩短时间范围。</div> : snapshot.points.length === 0 ? <div className="retention-empty">这个范围还没有可绘制的相邻轮次。历史会继续保留，后续请求将自动加入。</div> : <CacheRetentionChart points={snapshot.points} analysis={analysis} />}
        <footer className="retention-footer"><strong>{analysis.count.toLocaleString()} 轮续问 · {new Set(snapshot?.points.map(point => point.sessionKey) ?? []).size} 个主会话</strong><span>{formatRetentionCoverage(analysis)}</span><span>主会话累计 {all?.ownRoundCount.toLocaleString() ?? "—"} 轮；排除子 agent，fork 仅排除继承部分。所有 owner 合并统计。</span><span>建议随所选模型与时间范围重新计算，只反映本机历史。</span></footer>
      </section>
    </div>}
  </RetentionContext.Provider>;
}

export function CacheRetentionHomeCard() {
  const retention = useRetentionRecommendation();
  if (!retention) return null;
  return <section className="retention-home-card"><div><small>缓存续问建议</small><strong>{formatRetentionRecommendation(retention.analysis)}</strong><span>{formatRetentionRisk(retention.analysis)}</span></div><button type="button" onClick={retention.open}>打开续问图表 ↗</button></section>;
}
