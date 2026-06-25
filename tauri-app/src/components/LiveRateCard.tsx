import type {
  FloatingContentVisibility,
  FloatingUnreadEffect,
  LiveRateSnapshot,
  LiveThreadOption,
  PlatformCapabilities,
} from "../types/dashboard";
import type { FloatingWindowSettings } from "../floating/floatingSettings";
import { LiveRateMeter } from "./liveRate/LiveRateMeter";
import { LiveRateSessionRow } from "./liveRate/LiveRateSessionRow";
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
  onLiveThreadSelect: (threadId: string) => void;
  onToggleFloating: () => void;
  onToggleStatusTray: () => void;
  liveThreadOptions: LiveThreadOption[];
  platform: PlatformCapabilities;
  selectedLiveThreadId: string;
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
  onLiveThreadSelect,
  onToggleFloating,
  onToggleStatusTray,
  liveThreadOptions,
  platform,
  selectedLiveThreadId,
  snapshot,
  statusTrayLiveTextEnabled,
}: LiveRateCardProps) {
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
          <LiveRateMeter
            fullScale={floatingSettings.tokenRateFullScale}
            snapshot={snapshot}
            onFullScaleChange={onTokenRateFullScaleChange}
          />
          <LiveRateSessionRow
            liveThreadOptions={liveThreadOptions}
            onLiveThreadSelect={onLiveThreadSelect}
            selectedLiveThreadId={selectedLiveThreadId}
            snapshot={snapshot}
          />
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
