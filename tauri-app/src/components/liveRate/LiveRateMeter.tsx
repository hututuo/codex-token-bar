import type { LiveRateSnapshot } from "../../types/dashboard";
import { clamp, formatTokens } from "../../utils/format";

interface LiveRateMeterProps {
  snapshot: LiveRateSnapshot;
}

export function LiveRateMeter({ snapshot }: LiveRateMeterProps) {
  const progress = clamp(snapshot.tokensPerSecond / snapshot.maxTokensPerSecond, 0, 1);
  const scaleLimit = Math.round(snapshot.maxTokensPerSecond);

  return (
    <>
      <div className="rate-meter">
        <div className="rate-readout">
          <div>
            <strong>{snapshot.tokensPerSecond.toFixed(1)}</strong>
            <span>tok/s</span>
          </div>
          <em>全会话输出</em>
        </div>
        <div className="rate-bar-block">
          <div className="rate-bar-label">
            <span>速率</span>
            <span>满格 {scaleLimit}</span>
          </div>
          <div className="rate-track" aria-hidden="true">
            <i style={{ width: `${Math.max(6, progress * 100)}%` }} />
          </div>
        </div>
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
      </div>
    </>
  );
}
