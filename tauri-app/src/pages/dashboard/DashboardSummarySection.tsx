import { LiveRateCard } from "../../components/LiveRateCard";
import { QuotaStrip } from "../../components/QuotaStrip";
import { StatsStrip } from "../../components/StatsStrip";
import type { FloatingWindowSettings } from "../../floating/floatingSettings";
import type {
  DashboardSnapshot,
  DisplaySurfaceSettings,
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
  onFloatingUnreadEffectChange: (effect: FloatingUnreadEffect) => void;
  onFloatingGradientChange: (patch: Partial<Pick<FloatingWindowSettings, "gradientStart" | "gradientEnd" | "gradientDirection" | "gradientType">>) => void;
  onLiveThreadSelect: (threadId: string) => void;
  onToggleFloating: () => void;
  onToggleStatusTray: () => void;
  platform: PlatformCapabilities;
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
  onFloatingUnreadEffectChange,
  onFloatingGradientChange,
  onLiveThreadSelect,
  onToggleFloating,
  onToggleStatusTray,
  platform,
  selectedLiveThreadId,
}: DashboardSummarySectionProps) {
  return (
    <>
      <QuotaStrip snapshot={dashboard.quota} />
      <StatsStrip stats={dashboard.stats} />
      <LiveRateCard
        floatingEnabled={displaySurfaces.floatingWindowEnabled}
        floatingSettings={floatingSettings}
        statusTrayLiveTextEnabled={displaySurfaces.statusTrayLiveTextEnabled}
      onFloatingOpacityChange={onFloatingOpacityChange}
      onFloatingScaleChange={onFloatingScaleChange}
      onFloatingUnreadEffectChange={onFloatingUnreadEffectChange}
      onFloatingGradientChange={onFloatingGradientChange}
        onLiveThreadSelect={onLiveThreadSelect}
        onToggleFloating={onToggleFloating}
        onToggleStatusTray={onToggleStatusTray}
        liveThreadOptions={liveThreadOptions}
        platform={platform}
        selectedLiveThreadId={selectedLiveThreadId}
        snapshot={liveRate}
      />
    </>
  );
}
