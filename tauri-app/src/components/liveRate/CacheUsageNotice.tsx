import { useEffect, useState, useSyncExternalStore } from "react";
import type { CacheUsageAdvice } from "../../types/live";

const key = "cacheHitAdviceEnabled";
const changed = "cache-hit-advice-setting";
function enabled() {
  try { return localStorage.getItem(key) !== "false"; } catch { return true; }
}
function subscribe(update: () => void) {
  window.addEventListener("storage", update);
  window.addEventListener(changed, update);
  return () => { window.removeEventListener("storage", update); window.removeEventListener(changed, update); };
}

export function CacheUsageNotice({ advice }: { advice?: CacheUsageAdvice | null }) {
  const reminders = useSyncExternalStore(subscribe, enabled, () => true);
  const [dismissed, setDismissed] = useState(false);
  useEffect(() => { if (!advice?.low) setDismissed(false); }, [advice?.low]);
  const valid = advice && Number.isFinite(advice.hitRate) && advice.hitRate >= 0 && advice.hitRate <= 1;
  const warning = valid && advice.low && reminders && !dismissed;
  return <div style={{ padding: "8px 10px", borderRadius: 8, marginBlock: 6,
    background: warning ? "rgba(239,192,119,.10)" : "rgba(128,128,128,.06)", fontSize: 11 }}>
    <div style={{ display: "flex", flexWrap: "wrap", alignItems: "center", gap: 8 }}>
      <span>最近请求缓存命中率</span>
      <strong style={{ fontVariantNumeric: "tabular-nums" }}>{valid ? `${(advice.hitRate * 100).toFixed(1)}%` : "等待缓存数据"}</strong>
      <label style={{ marginLeft: "auto", display: "flex", alignItems: "center", gap: 4 }} title="输入至少 2 万 Token，单次请求命中低于 30% 时立即提醒；随实时监控运行。">
        <input type="checkbox" checked={reminders} onChange={event => {
          try { localStorage.setItem(key, String(event.target.checked)); } catch { return; }
          window.dispatchEvent(new Event(changed));
        }} />低命中提醒
      </label>
    </div>
    {warning && <div role="status" style={{ marginTop: 6, color: "#bc8734", display: "flex", alignItems: "start", gap: 8 }}>
      <span>本次请求缓存命中偏低 · 会话 {advice.threadId.slice(0, 8)}{(advice.affectedThreads ?? 0) > 1 ? ` 等 ${advice.affectedThreads} 个会话` : ""}<br />可检查是否切换了模型或上下文；这不代表缓存服务故障。</span>
      <button type="button" style={{ marginLeft: "auto", whiteSpace: "nowrap" }} onClick={() => setDismissed(true)}>收起</button>
    </div>}
  </div>;
}
