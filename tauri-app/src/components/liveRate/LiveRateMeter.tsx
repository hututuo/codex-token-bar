import type { CSSProperties } from "react";
import { ActivityRateUnitControl, useActivityRatePreferences } from "./ActivityRateUnits";
import { activityRateText, activityRateValue } from "./activityRatePresentation";
import type { LiveRateSnapshot } from "../../types/dashboard";
import { rateFillStyle, sanitizeRateFullScale } from "./rateDisplay";

interface LiveRateMeterProps {
  fullScale: number;
  liveRateEnabled: boolean;
  onFullScaleChange: (fullScale: number) => void;
  snapshot: LiveRateSnapshot;
}

export function LiveRateMeter({ fullScale, liveRateEnabled, onFullScaleChange, snapshot }: LiveRateMeterProps) {
  const { unit, fx } = useActivityRatePreferences();
  const scaleLimit = sanitizeFullScale(fullScale);
  const rangeFill = ((scaleLimit - 50) / 450) * 100;
  const rateLabel = activityRateText(liveRateEnabled ? activityRateValue(snapshot.tokensPerSecond, snapshot.modelRates, unit, fx) : 0, unit);

  return (
    <div className="rate-meter">
      <ActivityRateUnitControl/>
      <div className="rate-meter-main">
        <div className="rate-readout">
          <strong>{rateLabel}</strong>
          <span>{unit === "CN 元/s" ? "估算 CN 元/s" : unit}</span>
          <em>{liveRateEnabled ? "全会话活动估算" : "实时速率已关闭"}</em>
        </div>
        <div className="rate-bar-block">
          <div className="rate-bar-label">
            <span>实时速率</span>
            <span>量程 {scaleLimit} tok/s</span>
          </div>
          <div className="rate-track" aria-hidden="true">
            <i className="rate-fill" style={rateFillStyle(liveRateEnabled ? snapshot.tokensPerSecond : 0, scaleLimit, snapshot.modelRates)} />
          </div>
        </div>
      </div>
      <label className="rate-scale-slider">
        <span>满格</span>
        <input
          max="500"
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
