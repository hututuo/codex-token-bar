import type { CSSProperties } from "react";
import type { FloatingWindowSettings } from "../../floating/floatingSettings";
import type { FloatingUnreadEffect, PlatformCapabilities } from "../../types/dashboard";

const UNREAD_EFFECT_OPTIONS: Array<{ value: FloatingUnreadEffect; label: string }> = [
  { value: "off", label: "关" },
  { value: "ripple", label: "涟漪" },
  { value: "shimmer", label: "扫光" },
];

interface LiveRateSettingsPanelProps {
  floatingSettings: FloatingWindowSettings;
  floatingEnabled: boolean;
  onFloatingGradientChange: (patch: Partial<Pick<FloatingWindowSettings, "gradientStart" | "gradientEnd" | "gradientDirection" | "gradientType">>) => void;
  onFloatingOpacityChange: (opacity: number) => void;
  onFloatingScaleChange: (scale: number) => void;
  onFloatingUnreadEffectChange: (effect: FloatingUnreadEffect) => void;
  onToggleFloating: () => void;
  onToggleStatusTray: () => void;
  platform: PlatformCapabilities;
  statusTrayLiveTextEnabled: boolean;
}

export function LiveRateSettingsPanel({
  floatingEnabled,
  floatingSettings,
  onFloatingGradientChange,
  onFloatingOpacityChange,
  onFloatingScaleChange,
  onFloatingUnreadEffectChange,
  onToggleFloating,
  onToggleStatusTray,
  platform,
  statusTrayLiveTextEnabled,
}: LiveRateSettingsPanelProps) {
  const opacityPercent = Math.round(floatingSettings.opacity * 100);
  const scalePercent = Math.round(floatingSettings.scale * 100);
  const opacityFill = ((opacityPercent - 40) / 60) * 100;
  const scaleFill = ((scalePercent - 90) / 48) * 100;
  const floatingAvailable = platform.floatingWindow.available;
  const floatingButtonLabel = floatingAvailable
    ? `显示：${floatingEnabled ? "悬浮窗" : "关闭"}`
    : "悬浮窗待接入";
  const statusTrayLiveTextAvailable =
    platform.statusTray.available && platform.statusTrayLiveText.available;
  const statusTrayButtonLabel = statusTrayLiveTextAvailable
    ? `状态栏数字：${statusTrayLiveTextEnabled ? "开" : "关"}`
    : platform.statusTray.available
      ? "托盘图标已启用"
      : "状态栏待接入";

  return (
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
            disabled={!statusTrayLiveTextAvailable}
            onClick={onToggleStatusTray}
            title={
              statusTrayLiveTextAvailable
                ? platform.statusTrayLiveText.note
                : platform.statusTray.note
            }
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
      <div className="setting-segment" aria-label="未读提醒样式">
        <span>未读提醒</span>
        <div>
          {UNREAD_EFFECT_OPTIONS.map((option) => (
            <button
              className={floatingSettings.unreadEffect === option.value ? "is-active" : ""}
              key={option.value}
              onClick={() => onFloatingUnreadEffectChange(option.value)}
              type="button"
            >
              {option.label}
            </button>
          ))}
        </div>
      </div>
      <div className="floating-palette" aria-label="悬浮窗渐变调色盘">
        <span>调色盘</span>
        <input
          aria-label="渐变起始颜色"
          onChange={(event) => onFloatingGradientChange({ gradientStart: event.currentTarget.value })}
          type="color"
          value={floatingSettings.gradientStart}
        />
        <input
          aria-label="渐变结束颜色"
          onChange={(event) => onFloatingGradientChange({ gradientEnd: event.currentTarget.value })}
          type="color"
          value={floatingSettings.gradientEnd}
        />
        <select
          aria-label="渐变方向"
          onChange={(event) => onFloatingGradientChange({ gradientDirection: event.currentTarget.value as FloatingWindowSettings["gradientDirection"] })}
          value={floatingSettings.gradientDirection}
        >
          <option value="135deg">斜向</option>
          <option value="90deg">横向</option>
          <option value="180deg">纵向</option>
          <option value="45deg">反斜</option>
        </select>
        <select
          aria-label="渐变类型"
          onChange={(event) => onFloatingGradientChange({ gradientType: event.currentTarget.value as FloatingWindowSettings["gradientType"] })}
          value={floatingSettings.gradientType}
        >
          <option value="linear">线性</option>
          <option value="radial">柔光</option>
        </select>
      </div>
    </div>
  );
}
