import { LiveRateCard } from "../../components/LiveRateCard";
import { CodexRadarStrip } from "../../components/CodexRadarStrip";
import { QuotaStrip } from "../../components/QuotaStrip";
import { StatsStrip } from "../../components/StatsStrip";
import type { FloatingWindowSettings } from "../../floating/floatingSettings";
import type {
  DashboardSnapshot,
  DisplaySurfaceSettings,
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
  onTokenRateFullScaleChange: (fullScale: number) => void;
  onOpenSettings: () => void;
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
  onTokenRateFullScaleChange,
  onOpenSettings,
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
        onTokenRateFullScaleChange={onTokenRateFullScaleChange}
        onOpenSettings={onOpenSettings}
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
