import type {
  FloatingContentVisibility,
  FloatingUnreadEffect,
  LiveRateSnapshot,
  PlatformCapabilities,
} from "../types/dashboard";
import type { FloatingWindowSettings } from "../floating/floatingSettings";
import { LiveRateMeter } from "./liveRate/LiveRateMeter";
import { LiveRateSettingsPanel } from "./liveRate/LiveRateSettingsPanel";

interface LiveRateCardProps {
  floatingSettings: FloatingWindowSettings;
  floatingEnabled: boolean;
  onFloatingOpacityChange: (opacity: number) => void;
  onFloatingScaleChange: (scale: number) => void;
  onTokenRateFullScaleChange: (fullScale: number) => void;
  onFloatingUnreadEffectChange: (effect: FloatingUnreadEffect) => void;
  onFloatingGradientChange: (patch: Partial<Pick<FloatingWindowSettings, "gradientStart" | "gradientEnd" | "gradientDirection" | "gradientType">>) => void;
  onFloatingTextToneChange: (textTone: number) => void;
  onFloatingContentVisibilityChange: (contentVisibility: FloatingContentVisibility) => void;
  onLiveRateReset: () => Promise<void>;
  onToggleLiveRate: () => void;
  onToggleFloating: () => void;
  onToggleStatusTray: () => void;
  liveRateEnabled: boolean;
  platform: PlatformCapabilities;
  snapshot: LiveRateSnapshot;
  statusTrayLiveTextEnabled: boolean;
}

export function LiveRateCard({
  floatingSettings,
  floatingEnabled,
  onFloatingOpacityChange,
  onFloatingScaleChange,
  onTokenRateFullScaleChange,
  onFloatingUnreadEffectChange,
  onFloatingGradientChange,
  onFloatingTextToneChange,
  onFloatingContentVisibilityChange,
  onLiveRateReset,
  onToggleLiveRate,
  onToggleFloating,
  onToggleStatusTray,
  liveRateEnabled,
  platform,
  snapshot,
  statusTrayLiveTextEnabled,
}: LiveRateCardProps) {
  return (
    <section className={liveRateEnabled ? "live-card" : "live-card is-live-disabled"} aria-label="实时速率">
      <div className="section-title-row">
        <div>
          <div className="live-heading-line">
            <h2>全会话实时速度</h2>
            <button
              type="button"
              className={liveRateEnabled ? "live-rate-switch is-active" : "live-rate-switch"}
              onClick={onToggleLiveRate}
              aria-pressed={liveRateEnabled}
              title="关闭后停止实时速率监控，但不影响用量、额度和雷达统计"
            >
              实时速率 {liveRateEnabled ? "开" : "关"}
            </button>
          </div>
          <span>{liveRateEnabled ? "含输出与工具输入流 · 部分流式可能延迟" : "实时速率已关闭"}</span>
        </div>
        <div className="live-title-actions">
          <button
            type="button"
            className="live-reset-button"
            disabled={!liveRateEnabled}
            onClick={() => {
              void onLiveRateReset();
            }}
            title="清空当前滚动窗口，重新统计整体速率"
            aria-label="重置整体速率"
          >
            重置整体速率
          </button>
        </div>
      </div>

      <div className="live-grid">
        <div className={liveRateEnabled ? "live-left" : "live-left is-live-disabled"}>
          <LiveRateMeter
            fullScale={floatingSettings.tokenRateFullScale}
            liveRateEnabled={liveRateEnabled}
            snapshot={snapshot}
            onFullScaleChange={onTokenRateFullScaleChange}
          />
          <p className="live-rate-note">
            官方为减少磁盘写入关闭了部分流式日志，因此这里显示的是估算速率，主要用于判断 Codex 是否正在工作，不代表真实 tok/s。
          </p>
        </div>

        <LiveRateSettingsPanel
          floatingEnabled={floatingEnabled}
          floatingSettings={floatingSettings}
          onFloatingOpacityChange={onFloatingOpacityChange}
          onFloatingScaleChange={onFloatingScaleChange}
          onFloatingUnreadEffectChange={onFloatingUnreadEffectChange}
          onFloatingGradientChange={onFloatingGradientChange}
          onFloatingTextToneChange={onFloatingTextToneChange}
          onFloatingContentVisibilityChange={onFloatingContentVisibilityChange}
          onToggleFloating={onToggleFloating}
          onToggleStatusTray={onToggleStatusTray}
          platform={platform}
          statusTrayLiveTextEnabled={statusTrayLiveTextEnabled}
        />
      </div>
    </section>
  );
}
