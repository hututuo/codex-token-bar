import type { CSSProperties } from "react";
import type { LiveRateSnapshot } from "../../types/dashboard";
import { clamp } from "../../utils/format";

interface LiveRateMeterProps {
  fullScale: number;
  onFullScaleChange: (fullScale: number) => void;
  snapshot: LiveRateSnapshot;
}

export function LiveRateMeter({ fullScale, onFullScaleChange, snapshot }: LiveRateMeterProps) {
  const scaleLimit = sanitizeFullScale(fullScale);
  const progress = clamp(snapshot.tokensPerSecond / scaleLimit, 0, 1);
  const rangeFill = ((scaleLimit - 50) / 350) * 100;

  return (
    <div className="rate-meter">
      <div className="rate-meter-main">
        <div className="rate-readout">
          <strong>{snapshot.tokensPerSecond.toFixed(1)}</strong>
          <span>tok/s</span>
          <em>全会话输出</em>
        </div>
        <div className="rate-bar-block">
          <div className="rate-bar-label">
            <span>实时速率</span>
            <span>量程 {scaleLimit} tok/s</span>
          </div>
          <div className="rate-track" aria-hidden="true">
            <i style={{ width: `${Math.max(6, progress * 100)}%` }} />
          </div>
        </div>
      </div>
      <label className="rate-scale-slider">
        <span>满格</span>
        <input
          max="400"
          min="50"
          onChange={(event) => onFullScaleChange(Number(event.currentTarget.value))}
          step="10"
          style={{ "--range-fill": `${rangeFill}%` } as CSSProperties}
          type="range"
          value={scaleLimit}
        />
        <strong>{scaleLimit}</strong>
      </label>
    </div>
  );
}

function sanitizeFullScale(value: number): number {
  if (!Number.isFinite(value)) {
    return 200;
  }
  return Math.min(400, Math.max(50, Math.round(value / 10) * 10));
}
