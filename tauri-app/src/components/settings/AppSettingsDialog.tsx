import { useEffect, useRef } from "react";
import type { AutostartStatus, DisplaySurfaceSettings, FloatingContentVisibility, FloatingPalettePatch, FloatingUnreadEffect, PlatformCapabilities } from "../../types/dashboard";
import type { FloatingWindowSettings } from "../../floating/floatingSettings";
import { QUOTA_REFRESH_CADENCE_OPTIONS } from "../../settings/quotaRefreshCadence";
import { LiveRateSettingsPanel } from "../liveRate/LiveRateSettingsPanel";

interface AppSettingsDialogProps {
  autostartStatus: AutostartStatus;
  displaySurfaces: DisplaySurfaceSettings;
  floatingSettings: FloatingWindowSettings;
  liveRateEnabled: boolean;
  open: boolean;
  platform: PlatformCapabilities;
  quotaRefreshIntervalMs: number;
  onClose: () => void;
  onFloatingContentVisibilityChange: (contentVisibility: FloatingContentVisibility) => void;
  onFloatingGradientChange: (patch: FloatingPalettePatch) => void;
  onFloatingOpacityChange: (opacity: number) => void;
  onFloatingScaleChange: (scale: number) => void;
  onFloatingTextToneChange: (textTone: number) => void;
  onFloatingUnreadEffectChange: (effect: FloatingUnreadEffect) => void;
  onQuotaRefreshIntervalChange: (intervalMs: number) => Promise<void>;
  onToggleAutostart: () => void;
  onToggleFloating: () => void;
  onToggleLiveRate: () => void;
  onToggleStatusTray: () => void;
}

export function AppSettingsDialog({
  autostartStatus,
  displaySurfaces,
  floatingSettings,
  liveRateEnabled,
  open,
  platform,
  quotaRefreshIntervalMs,
  onClose,
  onFloatingContentVisibilityChange,
  onFloatingGradientChange,
  onFloatingOpacityChange,
  onFloatingScaleChange,
  onFloatingTextToneChange,
  onFloatingUnreadEffectChange,
  onQuotaRefreshIntervalChange,
  onToggleAutostart,
  onToggleFloating,
  onToggleLiveRate,
  onToggleStatusTray,
}: AppSettingsDialogProps) {
  const closeButtonRef = useRef<HTMLButtonElement>(null);
  const dialogRef = useRef<HTMLElement>(null);
  const previousFocusRef = useRef<HTMLElement | null>(null);

  useEffect(() => {
    if (!open) return undefined;
    previousFocusRef.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    closeButtonRef.current?.focus();
    const closeForEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
    };
    window.addEventListener("keydown", closeForEscape);
    return () => {
      window.removeEventListener("keydown", closeForEscape);
      previousFocusRef.current?.focus();
    };
  }, [onClose, open]);

  if (!open) return null;

  return (
    <div
      className="app-settings-overlay"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) onClose();
      }}
    >
      <section
        aria-label="总体设置"
        aria-modal="true"
        className="app-settings-dialog"
        onKeyDown={(event) => {
          if (event.key !== "Tab") return;
          const focusable = [...(dialogRef.current?.querySelectorAll<HTMLElement>(
            "button:not(:disabled), input:not(:disabled), select:not(:disabled)",
          ) ?? [])];
          if (focusable.length === 0) return;
          const currentIndex = focusable.indexOf(document.activeElement as HTMLElement);
          if (event.shiftKey && currentIndex <= 0) {
            event.preventDefault();
            focusable.at(-1)?.focus();
          } else if (!event.shiftKey && currentIndex === focusable.length - 1) {
            event.preventDefault();
            focusable[0]?.focus();
          }
        }}
        ref={dialogRef}
        role="dialog"
      >
        <header className="app-settings-head">
          <div>
            <strong>总体设置</strong>
            <span>显示面、刷新与悬浮窗外观集中在这里。</span>
          </div>
          <button aria-label="关闭总体设置" onClick={onClose} ref={closeButtonRef} type="button">×</button>
        </header>

        <div className="app-settings-body">
          <section className="app-settings-section" aria-labelledby="app-settings-general-title">
            <div className="app-settings-section-head">
              <strong id="app-settings-general-title">常规</strong>
              <span>启动、监控与额度刷新</span>
            </div>
            <div className="app-settings-general-grid">
              <button
                aria-pressed={autostartStatus.enabled}
                className={autostartStatus.enabled ? "app-setting-toggle is-active" : "app-setting-toggle"}
                disabled={!autostartStatus.available}
                onClick={onToggleAutostart}
                title={autostartStatus.message}
                type="button"
              >
                <span>开机自启</span><strong>{autostartStatus.enabled ? "开" : "关"}</strong>
              </button>
              <button
                aria-pressed={liveRateEnabled}
                className={liveRateEnabled ? "app-setting-toggle is-active" : "app-setting-toggle"}
                onClick={onToggleLiveRate}
                type="button"
              >
                <span>实时速率</span><strong>{liveRateEnabled ? "开" : "关"}</strong>
              </button>
              <label className="app-setting-select">
                <span>额度刷新</span>
                <select
                  aria-label="额度刷新频率"
                  onChange={(event) => void onQuotaRefreshIntervalChange(Number(event.currentTarget.value))}
                  value={quotaRefreshIntervalMs}
                >
                  {QUOTA_REFRESH_CADENCE_OPTIONS.map((option) => (
                    <option key={option.valueMs} value={option.valueMs}>{option.label}</option>
                  ))}
                </select>
              </label>
            </div>
          </section>

          <section className="app-settings-section" aria-labelledby="app-settings-floating-title">
            <div className="app-settings-section-head">
              <strong id="app-settings-floating-title">显示与悬浮窗</strong>
              <span>高频开关也会保留在实时速率卡上</span>
            </div>
            <LiveRateSettingsPanel
              floatingEnabled={displaySurfaces.floatingWindowEnabled}
              floatingSettings={floatingSettings}
              onFloatingContentVisibilityChange={onFloatingContentVisibilityChange}
              onFloatingGradientChange={onFloatingGradientChange}
              onFloatingOpacityChange={onFloatingOpacityChange}
              onFloatingScaleChange={onFloatingScaleChange}
              onFloatingTextToneChange={onFloatingTextToneChange}
              onFloatingUnreadEffectChange={onFloatingUnreadEffectChange}
              onToggleFloating={onToggleFloating}
              onToggleStatusTray={onToggleStatusTray}
              platform={platform}
              statusTrayLiveTextEnabled={displaySurfaces.statusTrayLiveTextEnabled}
            />
          </section>
        </div>
      </section>
    </div>
  );
}
