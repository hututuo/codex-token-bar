import { LiveRateCard } from "../../components/LiveRateCard";
import { CodexRadarStrip } from "../../components/CodexRadarStrip";
import { QuotaStrip } from "../../components/QuotaStrip";
import { StatsStrip } from "../../components/StatsStrip";
import type { FloatingWindowSettings } from "../../floating/floatingSettings";
import type {
  DashboardSnapshot,
  DisplaySurfaceSettings,
  FloatingContentVisibility,
  FloatingUnreadEffect,
  LiveRateSnapshot,
  LiveThreadOption,
  PlatformCapabilities,
} from "../../types/dashboard";

interface DashboardSummarySectionProps {
  dashboard: DashboardSnapshot;
  displaySurfaces: DisplaySurfaceSettings;
  floatingSettings: FloatingWindowSettings;
  liveRate: LiveRateSnapshot;
  liveThreadOptions: LiveThreadOption[];
  onFloatingOpacityChange: (opacity: number) => void;
  onFloatingScaleChange: (scale: number) => void;
  onTokenRateFullScaleChange: (fullScale: number) => void;
  onFloatingUnreadEffectChange: (effect: FloatingUnreadEffect) => void;
  onFloatingGradientChange: (patch: Partial<Pick<FloatingWindowSettings, "gradientStart" | "gradientEnd" | "gradientDirection" | "gradientType">>) => void;
  onFloatingTextToneChange: (textTone: number) => void;
  onFloatingContentVisibilityChange: (contentVisibility: FloatingContentVisibility) => void;
  onLiveRateReset: () => Promise<void>;
  onLiveThreadSelect: (threadId: string) => void;
  onToggleLiveRate: () => void;
  onToggleFloating: () => void;
  onToggleStatusTray: () => void;
  platform: PlatformCapabilities;
  radarRefreshGeneration: number;
  liveRateEnabled: boolean;
  selectedLiveThreadId: string;
}

export function DashboardSummarySection({
  dashboard,
  displaySurfaces,
  floatingSettings,
  liveRate,
  liveThreadOptions,
  onFloatingOpacityChange,
  onFloatingScaleChange,
  onTokenRateFullScaleChange,
  onFloatingUnreadEffectChange,
  onFloatingGradientChange,
  onFloatingTextToneChange,
  onFloatingContentVisibilityChange,
  onLiveRateReset,
  onLiveThreadSelect,
  onToggleLiveRate,
  onToggleFloating,
  onToggleStatusTray,
  platform,
  radarRefreshGeneration,
  liveRateEnabled,
  selectedLiveThreadId,
}: DashboardSummarySectionProps) {
  return (
    <>
      <QuotaStrip snapshot={dashboard.quota} warnings={dashboard.warnings} />
      <StatsStrip stats={dashboard.stats} />
      <CodexRadarStrip refreshGeneration={radarRefreshGeneration} />
      <LiveRateCard
        floatingEnabled={displaySurfaces.floatingWindowEnabled}
        floatingSettings={floatingSettings}
        statusTrayLiveTextEnabled={displaySurfaces.statusTrayLiveTextEnabled}
        liveRateEnabled={liveRateEnabled}
        onFloatingOpacityChange={onFloatingOpacityChange}
        onFloatingScaleChange={onFloatingScaleChange}
        onTokenRateFullScaleChange={onTokenRateFullScaleChange}
        onFloatingUnreadEffectChange={onFloatingUnreadEffectChange}
        onFloatingGradientChange={onFloatingGradientChange}
        onFloatingTextToneChange={onFloatingTextToneChange}
        onFloatingContentVisibilityChange={onFloatingContentVisibilityChange}
        onLiveRateReset={onLiveRateReset}
        onToggleLiveRate={onToggleLiveRate}
        onToggleFloating={onToggleFloating}
        onToggleStatusTray={onToggleStatusTray}
        platform={platform}
        snapshot={liveRate}
      />
    </>
  );
}
