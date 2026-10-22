import type { CacheUsageAdvice } from "../../types/live";
import { cacheAdviceTitle, hasValidCacheHitRate } from "./cacheAdvicePresentation";
import { CACHE_MISS_REMINDER_ENABLED } from "./feature";
import { useCacheUsageAdvice } from "./useCacheUsageAdvice";

/** Temporary reminder only: consumes the existing snapshot, without a scanner or side-store. */
export function CacheUsageNotice({ advice }: { advice?: CacheUsageAdvice | null }) {
  const { enabled, warning, setEnabled, dismiss } = useCacheUsageAdvice(advice);
  if (!CACHE_MISS_REMINDER_ENABLED) return null;
  return <div style={{ padding: "8px 10px", borderRadius: 8, marginBlock: 6,
    background: warning ? "rgba(239,192,119,.10)" : "rgba(128,128,128,.06)", fontSize: 11 }}>
    <div style={{ display: "flex", flexWrap: "wrap", alignItems: "center", gap: 8 }}>
      <label style={{ display: "flex", alignItems: "center", gap: 4 }}
        title="输入至少 2 万 Token、单次请求命中低于 30% 时提醒；新上下文首次请求不提醒。">
        <input type="checkbox" checked={enabled} onChange={event => setEnabled(event.target.checked)} />低命中提醒
      </label>
      {hasValidCacheHitRate(advice) && <span style={{ marginLeft: "auto", fontVariantNumeric: "tabular-nums" }}>最近请求 {(advice.hitRate * 100).toFixed(1)}%</span>}
    </div>
    {warning && <div role="status" style={{ marginTop: 6, display: "flex", alignItems: "start", gap: 8 }}>
      <span style={{ minWidth: 0, overflowWrap: "anywhere" }}>
        <strong>缓存命中偏低 · {(warning.hitRate * 100).toFixed(1)}%</strong><br />
        {cacheAdviceTitle(warning)}<br />
        本次请求复用较少，等待、切换模型或上下文变化都可能影响缓存。
      </span>
      <button type="button" aria-label="关闭本次缓存提醒" onClick={dismiss}
        style={{ marginLeft: "auto", whiteSpace: "nowrap", minHeight: 28, padding: "4px 9px",
          border: "1px solid #bc8734", borderRadius: 6, background: "rgba(239,192,119,.18)", color: "inherit" }}>× 关闭提醒</button>
    </div>}
  </div>;
}
