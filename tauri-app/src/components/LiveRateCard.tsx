import type { CSSProperties } from "react";
import type { LiveRateSnapshot, PlatformCapabilities } from "../types/dashboard";
import type { FloatingWindowSettings } from "../floating/floatingSettings";
import { clamp, formatTokens } from "../utils/format";

interface LiveRateCardProps {
  floatingSettings: FloatingWindowSettings;
  floatingVisible: boolean;
  onFloatingOpacityChange: (opacity: number) => void;
  onFloatingScaleChange: (scale: number) => void;
  onToggleFloating: () => void;
  onToggleStatusTray: () => void;
  platform: PlatformCapabilities;
  snapshot: LiveRateSnapshot;
  statusTrayLiveTextEnabled: boolean;
}

export function LiveRateCard({
  floatingSettings,
  floatingVisible,
  onFloatingOpacityChange,
  onFloatingScaleChange,
  onToggleFloating,
  onToggleStatusTray,
  platform,
  snapshot,
  statusTrayLiveTextEnabled,
}: LiveRateCardProps) {
  const progress = clamp(snapshot.tokensPerSecond / snapshot.maxTokensPerSecond, 0, 1);
  const opacityPercent = Math.round(floatingSettings.opacity * 100);
  const scalePercent = Math.round(floatingSettings.scale * 100);
  const scaleLimit = Math.round(snapshot.maxTokensPerSecond);
  const opacityFill = ((opacityPercent - 40) / 60) * 100;
  const scaleFill = ((scalePercent - 90) / 48) * 100;
  const floatingAvailable = platform.floatingWindow.available;
  const floatingButtonLabel = floatingAvailable
    ? `显示：${floatingVisible ? "悬浮窗" : "关闭"}`
    : "悬浮窗待接入";
  const statusTrayAvailable = platform.statusTray.available;
  const statusTrayButtonLabel = statusTrayAvailable
    ? `状态栏数字：${statusTrayLiveTextEnabled ? "开" : "关"}`
    : "状态栏待接入";

  return (
    <section className="live-card" aria-label="实时速率">
      <div className="section-title-row">
        <div>
          <h2>全会话实时速度</h2>
          <span>正在汇总全会话输出</span>
        </div>
      </div>

      <div className="live-grid">
        <div className="live-left">
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

          <div className="session-row">
            <button className="session-chip" type="button">选中会话</button>
            <span>{snapshot.threadTitle}</span>
            <strong>{snapshot.preciseEnabled ? "精准 token 统计" : "估算 token 统计"}</strong>
          </div>
        </div>

        <div className="settings-panel">
          <div className="settings-topline">
            <span className="settings-label">显示设置</span>
            <div className="settings-actions">
              <button
                className="live-toggle-button"
                disabled={!floatingAvailable}
                onClick={onToggleFloating}
                title={platform.floatingWindow.note}
                type="button"
              >
                {floatingButtonLabel}
              </button>
              <button
                className="live-toggle-button"
                disabled={!statusTrayAvailable}
                onClick={onToggleStatusTray}
                title={platform.statusTrayLiveText.note}
                type="button"
              >
                {statusTrayButtonLabel}
              </button>
            </div>
          </div>
          <label className="setting-slider">
            <span>透明度</span>
            <input
              max="100"
              min="40"
              onChange={(event) => onFloatingOpacityChange(Number(event.currentTarget.value) / 100)}
              style={{ "--range-fill": `${opacityFill}%` } as CSSProperties}
              type="range"
              value={opacityPercent}
            />
            <strong>{opacityPercent}%</strong>
          </label>
          <label className="setting-slider">
            <span>悬浮窗大小</span>
            <input
              max="138"
              min="90"
              onChange={(event) => onFloatingScaleChange(Number(event.currentTarget.value) / 100)}
              style={{ "--range-fill": `${scaleFill}%` } as CSSProperties}
              type="range"
              value={scalePercent}
            />
            <strong>{scalePercent}%</strong>
          </label>
        </div>
      </div>
    </section>
  );
}
