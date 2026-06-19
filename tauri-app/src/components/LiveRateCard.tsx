import type {
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
  floatingVisible: boolean;
  onFloatingOpacityChange: (opacity: number) => void;
  onFloatingScaleChange: (scale: number) => void;
  onFloatingUnreadEffectChange: (effect: FloatingUnreadEffect) => void;
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
  floatingVisible,
  onFloatingOpacityChange,
  onFloatingScaleChange,
  onFloatingUnreadEffectChange,
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
          <LiveRateMeter snapshot={snapshot} />
          <LiveRateSessionRow
            liveThreadOptions={liveThreadOptions}
            onLiveThreadSelect={onLiveThreadSelect}
            selectedLiveThreadId={selectedLiveThreadId}
            snapshot={snapshot}
          />
        </div>

        <LiveRateSettingsPanel
          floatingSettings={floatingSettings}
          floatingVisible={floatingVisible}
          onFloatingOpacityChange={onFloatingOpacityChange}
          onFloatingScaleChange={onFloatingScaleChange}
          onFloatingUnreadEffectChange={onFloatingUnreadEffectChange}
          onToggleFloating={onToggleFloating}
          onToggleStatusTray={onToggleStatusTray}
          platform={platform}
          statusTrayLiveTextEnabled={statusTrayLiveTextEnabled}
        />
      </div>
    </section>
  );
}
