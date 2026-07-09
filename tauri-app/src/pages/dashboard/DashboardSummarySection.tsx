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
  quotaRefreshIntervalMs: number;
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
  onLiveRateRetry: () => void;
  onAcknowledgeUnread: () => Promise<void>;
  onLiveThreadSelect: (threadId: string) => void;
  onQuotaRefresh: () => void;
  onQuotaRefreshIntervalChange: (intervalMs: number) => Promise<void>;
  onToggleLiveRate: () => void;
  onToggleFloating: () => void;
  onToggleStatusTray: () => void;
  platform: PlatformCapabilities;
  radarRefreshGeneration: number;
  refreshing: boolean;
  liveRateEnabled: boolean;
  selectedLiveThreadId: string;
  usageCacheInitializing: boolean;
}

export function DashboardSummarySection({
  dashboard,
  displaySurfaces,
  floatingSettings,
  quotaRefreshIntervalMs,
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
  onLiveRateRetry,
  onAcknowledgeUnread,
  onLiveThreadSelect,
  onQuotaRefresh,
  onQuotaRefreshIntervalChange,
  onToggleLiveRate,
  onToggleFloating,
  onToggleStatusTray,
  platform,
  radarRefreshGeneration,
  refreshing,
  liveRateEnabled,
  selectedLiveThreadId,
  usageCacheInitializing,
}: DashboardSummarySectionProps) {
  return (
    <>
      <QuotaStrip
        diagnostics={dashboard.diagnostics}
        onQuotaRefreshIntervalChange={onQuotaRefreshIntervalChange}
        onRetryQuotaRefresh={onQuotaRefresh}
        quotaRefreshIntervalMs={quotaRefreshIntervalMs}
        snapshot={dashboard.quota}
        warnings={dashboard.warnings}
      />
      <StatsStrip stats={dashboard.stats} warnings={dashboard.warnings} />
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
        onLiveRateRetry={onLiveRateRetry}
        onAcknowledgeUnread={onAcknowledgeUnread}
        onToggleLiveRate={onToggleLiveRate}
        onToggleFloating={onToggleFloating}
        onToggleStatusTray={onToggleStatusTray}
        platform={platform}
        refreshing={refreshing}
        snapshot={liveRate}
        usageCacheInitializing={usageCacheInitializing}
      />
    </>
  );
}
