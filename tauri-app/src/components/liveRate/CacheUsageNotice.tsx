import type { CacheUsageAdvice } from "../../types/live";
import { cacheAdviceTitle, hasValidCacheHitRate } from "./cacheAdvicePresentation";
import { useCacheUsageAdvice } from "./useCacheUsageAdvice";

export function CacheUsageNotice({ advice }: { advice?: CacheUsageAdvice | null }) {
  const { enabled: reminders, warning, setEnabled, dismiss } = useCacheUsageAdvice(advice);
  const valid = hasValidCacheHitRate(advice);
  return <div style={{ padding: "8px 10px", borderRadius: 8, marginBlock: 6,
    background: warning ? "rgba(239,192,119,.10)" : "rgba(128,128,128,.06)", fontSize: 11 }}>
    <div style={{ display: "flex", flexWrap: "wrap", alignItems: "center", gap: 8 }}>
      <span>最近请求缓存命中率</span>
      <strong style={{ fontVariantNumeric: "tabular-nums" }}>{valid ? `${(advice.hitRate * 100).toFixed(1)}%` : "等待缓存数据"}</strong>
      <label style={{ marginLeft: "auto", display: "flex", alignItems: "center", gap: 4 }} title="输入至少 2 万 Token，单次请求命中低于 30% 时立即提醒；随实时监控运行。">
        <input type="checkbox" checked={reminders} onChange={event => setEnabled(event.target.checked)} />低命中提醒
      </label>
    </div>
    {warning && <div role="status" style={{ marginTop: 6, color: "#bc8734", display: "flex", alignItems: "start", gap: 8 }}>
      <span style={{ minWidth: 0, overflowWrap: "anywhere" }} title={`会话 ID：${warning.threadId}`}>本次请求缓存命中偏低 · {cacheAdviceTitle(warning)}{(warning.affectedThreads ?? 0) > 1 ? ` 等 ${warning.affectedThreads} 个会话` : ""}<br />可能与切换模型或上下文变化有关，请检查最近的相关操作。</span>
      <button type="button" aria-label="关闭本次缓存提醒" style={{ marginLeft: "auto", whiteSpace: "nowrap", minHeight: 28, padding: "4px 9px", border: "1px solid #bc8734", borderRadius: 6, background: "rgba(239,192,119,.18)", color: "inherit", fontWeight: 600 }} onClick={dismiss}>× 关闭提醒</button>
    </div>}
  </div>;
}
