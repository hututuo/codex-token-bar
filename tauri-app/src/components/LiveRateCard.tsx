import type { LiveRateSnapshot } from "../types/dashboard";
import { clamp, formatTokens } from "../utils/format";

interface LiveRateCardProps {
  snapshot: LiveRateSnapshot;
}

export function LiveRateCard({ snapshot }: LiveRateCardProps) {
  const progress = clamp(snapshot.tokensPerSecond / snapshot.maxTokensPerSecond, 0, 1);

  return (
    <section className="live-card" aria-label="实时速率">
      <div className="section-title-row">
        <div>
          <h2>全会话实时速度</h2>
          <span>正在汇总全会话输出</span>
        </div>
        <button className="toolbar-button" type="button">
          重置整体速率
        </button>
      </div>

      <div className="live-grid">
        <div className="rate-meter">
          <strong>{snapshot.tokensPerSecond.toFixed(1)}</strong>
          <span>tokens / second</span>
          <div className="vertical-fill" style={{ height: `${Math.max(8, progress * 100)}%` }} />
        </div>

        <div className="rate-details">
          <div className="metric-card">
            <strong>{snapshot.tokensPerSecond.toFixed(1)}</strong>
            <span>全会话 tok/s</span>
          </div>
          <div className="metric-card">
            <strong>{formatTokens(snapshot.totalTokensToday)}</strong>
            <span>今日 token</span>
          </div>
          <div className="metric-card">
            <strong>{snapshot.requestsToday}</strong>
            <span>今日请求</span>
          </div>
          <div className="session-row">
            <button className="toolbar-button toolbar-button--wide" type="button">
              选中会话
            </button>
            <span>{snapshot.threadTitle}</span>
            <strong>{snapshot.preciseEnabled ? "精准 token 统计" : "估算 token 统计"}</strong>
          </div>
        </div>

        <div className="settings-panel">
          <button className="toolbar-button toolbar-button--wide" type="button">
            显示：悬浮窗
          </button>
          <button className="toolbar-button toolbar-button--wide" type="button">
            状态栏
          </button>
          <label>
            <span>悬浮窗透明度</span>
            <input max="100" min="40" type="range" value="92" readOnly />
          </label>
          <label>
            <span>悬浮窗大小</span>
            <input max="138" min="90" type="range" value="104" readOnly />
          </label>
        </div>
      </div>
    </section>
  );
}
