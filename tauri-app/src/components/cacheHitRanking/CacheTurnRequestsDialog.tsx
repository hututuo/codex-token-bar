import { useEffect, useRef, useState } from "react";
import { readCacheTurnRequests } from "../../api/dashboardClient";
import type { CacheRequestUsage, TurnCacheUsage } from "../../types/usage";
import type { CodexHomeSourceToken } from "../../types/platform";
import { cacheHitRate, uncachedInputTokens } from "./model";
import { modelUsageColor } from "../modelUsagePresentation";

const PAGE_SIZE = 100;
const timeFormat = new Intl.DateTimeFormat("zh-CN", {
  month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false,
});
const numbers = new Intl.NumberFormat("zh-CN");
export type CacheRequestLoader = typeof readCacheTurnRequests;

export function CacheTurnRequestsDialog({ turn, sourceToken, onClose, loadRequests = readCacheTurnRequests }: {
  turn: TurnCacheUsage; sourceToken: CodexHomeSourceToken; onClose: () => void; loadRequests?: CacheRequestLoader;
}) {
  const [rows, setRows] = useState<CacheRequestUsage[]>([]);
  const [loading, setLoading] = useState(true);
  const [hasMore, setHasMore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [refresh, setRefresh] = useState(0);
  const generation = useRef(0);
  const panel = useRef<HTMLDivElement>(null);
  const closeButton = useRef<HTMLButtonElement>(null);
  const sourceKey = JSON.stringify(sourceToken);

  useEffect(() => {
    const current = ++generation.current;
    setRows([]); setLoading(true); setError(null); setHasMore(false);
    void loadRequests(sourceToken, turn.id, 0, PAGE_SIZE + 1).then((result) => {
      if (generation.current !== current) return;
      setRows(result.slice(0, PAGE_SIZE)); setHasMore(result.length > PAGE_SIZE);
    }).catch((cause: unknown) => {
      if (generation.current === current) setError(String(cause));
    }).finally(() => {
      if (generation.current === current) setLoading(false);
    });
    return () => { generation.current += 1; };
  }, [sourceKey, turn.id, turn.requestCount, refresh, loadRequests]);

  useEffect(() => {
    closeButton.current?.focus();
    const handler = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault(); event.stopImmediatePropagation(); onClose();
      } else if (event.key === "Tab") {
        const buttons = Array.from(panel.current?.querySelectorAll<HTMLButtonElement>("button:not(:disabled)") ?? []);
        const first = buttons[0]; const last = buttons.at(-1);
        if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
        else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
      }
    };
    window.addEventListener("keydown", handler, true);
    return () => window.removeEventListener("keydown", handler, true);
  }, [onClose]);

  async function more() {
    if (loading) return;
    const current = generation.current;
    setLoading(true); setError(null);
    try {
      const result = await loadRequests(sourceToken, turn.id, rows.length, PAGE_SIZE + 1);
      if (generation.current !== current) return;
      setRows((previous) => [...previous, ...result.slice(0, PAGE_SIZE)]);
      setHasMore(result.length > PAGE_SIZE);
    } catch (cause) {
      if (generation.current === current) setError(String(cause));
    } finally {
      if (generation.current === current) setLoading(false);
    }
  }

  return <div className="codex-radar-detail-layer cache-request-layer" onMouseDown={(event) => {
    if (event.target === event.currentTarget) onClose();
  }}>
    <div ref={panel} className="cache-request-panel" role="dialog" aria-modal="true" aria-label="本轮请求明细">
      <header className="cache-request-header">
        <div><h2>本轮请求明细</h2><p>{turn.sessionTitle} · 第 {turn.turnIndexInSession} 轮</p></div>
        <button type="button" disabled={loading} onClick={() => setRefresh((value) => value + 1)}>刷新</button>
        <button type="button" ref={closeButton} onClick={onClose} aria-label="关闭本轮请求明细">关闭</button>
      </header>
      <div className="cache-request-summary">
        <strong>整轮加权 {(cacheHitRate(turn.breakdown) * 100).toFixed(2)}%</strong>
        <span>{turn.requestCount ?? "—"} 次请求 · 低命中 {turn.lowHitCount ?? 0} 次 · 零命中 {turn.zeroHitCount ?? 0} 次</span>
      </div>
      <p className="cache-request-definition">低命中：输入 ≥ 2 万且命中率 &lt; 30%。零命中：有输入且缓存命中为 0；符合低命中条件的零命中也计入低命中次数。输出已含思考，不重复相加。</p>
      <div className="cache-request-table-scroll">
        <table><thead><tr><th>时间 / 模型</th><th>输入</th><th>缓存命中</th><th>未命中</th><th>输出</th><th>总量</th><th>命中率</th></tr></thead>
          <tbody>{rows.map((row) => {
            const usage = row.breakdown;
            const zero = usage.inputTokens > 0 && usage.cachedInputTokens === 0;
            const low = usage.inputTokens >= 20_000 && cacheHitRate(usage) < 0.3;
            return <tr key={row.id}>
              <td><time dateTime={row.timestamp}>{timeFormat.format(new Date(row.timestamp))}</time><small><span style={{ color: modelUsageColor(row.model) }}>{row.model ?? "未知模型"}</span>{zero ? <b className="cache-request-zero">零命中</b> : low ? <b className="cache-request-low">低命中</b> : null}</small></td>
              <td>{numbers.format(usage.inputTokens)}</td><td>{numbers.format(usage.cachedInputTokens)}</td>
              <td>{numbers.format(uncachedInputTokens(usage))}</td><td>{numbers.format(usage.outputTokens)}</td>
              <td>{numbers.format(usage.totalTokens)}</td><td>{usage.inputTokens > 0 ? `${(cacheHitRate(usage) * 100).toFixed(2)}%` : "—"}</td>
            </tr>;
          })}</tbody>
        </table>
        {!loading && !error && rows.length === 0 && <p>暂未找到可用的请求记录；请等待精确索引更新后重试。</p>}
      </div>
      {error && <p role="alert" className="cache-request-error">请求明细读取失败：{error}</p>}
      <footer><span aria-live="polite">{loading ? "正在读取…" : `已显示 ${rows.length} 次请求`}</span>
        {hasMore && <button type="button" onClick={() => void more()} disabled={loading}>继续加载</button>}
      </footer>
    </div>
  </div>;
}
