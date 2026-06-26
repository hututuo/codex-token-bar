import type { CSSProperties } from "react";
import type { LiveRateSnapshot } from "../../types/dashboard";
import { formatLiveRateValue, rateFillStyle, sanitizeRateFullScale } from "./rateDisplay";

interface LiveRateMeterProps {
  fullScale: number;
  liveRateEnabled: boolean;
  onFullScaleChange: (fullScale: number) => void;
  snapshot: LiveRateSnapshot;
}

export function LiveRateMeter({ fullScale, liveRateEnabled, onFullScaleChange, snapshot }: LiveRateMeterProps) {
  const scaleLimit = sanitizeFullScale(fullScale);
  const rangeFill = ((scaleLimit - 50) / 350) * 100;
  const rateLabel = liveRateEnabled ? formatLiveRateValue(snapshot.tokensPerSecond) : "0.0";

  return (
    <div className="rate-meter">
      <div className="rate-meter-main">
        <div className="rate-readout">
          <strong>{rateLabel}</strong>
          <span>tok/s</span>
          <em>{liveRateEnabled ? "含输出与工具输入流" : "实时速率已关闭"}</em>
        </div>
        <div className="rate-bar-block">
          <div className="rate-bar-label">
            <span>实时速率</span>
            <span>量程 {scaleLimit} tok/s</span>
          </div>
          <div className="rate-track" aria-hidden="true">
            <i className="rate-fill" style={rateFillStyle(liveRateEnabled ? snapshot.tokensPerSecond : 0, scaleLimit)} />
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
  return sanitizeRateFullScale(value);
}
