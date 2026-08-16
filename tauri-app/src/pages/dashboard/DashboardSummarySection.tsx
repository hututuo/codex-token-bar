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
import type { SharedAccountAttributionResult } from "../../components/sharedAccountAttribution/model";

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
  onAttributionPreciseRefreshNeeded: (comparisonUpdatedAt: string) => void;
  onAttributionSafetyAcknowledge: (
    provenanceEpoch: string,
    unsafeID: string,
    throughGeneration: number,
  ) => Promise<boolean>;
  onAttributionSafetyRefreshNeeded: () => void;
  onAttributionChange: (result: SharedAccountAttributionResult | null) => void;
  onToggleLiveRate: () => void;
  onToggleFloating: () => void;
  onToggleStatusTray: () => void;
  platform: PlatformCapabilities;
  radarRefreshGeneration: number;
  refreshing: boolean;
  liveRateEnabled: boolean;
  selectedLiveThreadId: string;
  sourceHomeIdentity: string;
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
  onAttributionPreciseRefreshNeeded,
  onAttributionSafetyAcknowledge,
  onAttributionSafetyRefreshNeeded,
  onAttributionChange,
  onToggleLiveRate,
  onToggleFloating,
  onToggleStatusTray,
  platform,
  radarRefreshGeneration,
  refreshing,
  liveRateEnabled,
  selectedLiveThreadId,
  sourceHomeIdentity,
  usageCacheInitializing,
}: DashboardSummarySectionProps) {
  const todayActivity = dashboard.activityDays.at(-1);
  return (
    <>
      <QuotaStrip
        attributionIdentity={dashboard.attributionIdentity ?? null}
        diagnostics={dashboard.diagnostics}
        onAttributionPreciseRefreshNeeded={onAttributionPreciseRefreshNeeded}
        onAttributionSafetyAcknowledge={onAttributionSafetyAcknowledge}
        onAttributionSafetyRefreshNeeded={onAttributionSafetyRefreshNeeded}
        onAttributionChange={onAttributionChange}
        onQuotaRefreshIntervalChange={onQuotaRefreshIntervalChange}
        onRetryQuotaRefresh={onQuotaRefresh}
        preciseDataAvailable={dashboard.preciseRecentUsageCoveredAt !== null
          && dashboard.preciseRecentUsageCoveredAt !== undefined}
        preciseDataCoveredAt={dashboard.preciseRecentUsageCoveredAt ?? null}
        preciseDataFresh={dashboard.preciseRecentUsageFresh === true}
        preciseObserverEpoch={dashboard.preciseObserverEpoch ?? null}
        preciseObserverStartedAtUnixMicros={dashboard.preciseObserverStartedAtUnixMicros ?? null}
        preciseObserverSequence={dashboard.preciseObserverSequence ?? null}
        preciseAttributionProvenanceEpoch={dashboard.preciseAttributionProvenanceEpoch ?? null}
        preciseAttributionGeneration={dashboard.preciseAttributionGeneration ?? null}
        preciseAttributionUnsafeSinceGeneration={dashboard.preciseAttributionUnsafeSinceGeneration ?? null}
        preciseAttributionUnsafeID={dashboard.preciseAttributionUnsafeId ?? null}
        preciseAttributionCurrentScanUnsafe={dashboard.preciseAttributionCurrentScanUnsafe === true}
        quotaUpdatedAt={dashboard.quotaUpdatedAt ?? null}
        quotaRefreshIntervalMs={quotaRefreshIntervalMs}
        recentUsage24h={dashboard.recentUsage24h}
        snapshot={dashboard.quota}
        sourceHomeIdentity={sourceHomeIdentity}
        warnings={dashboard.warnings}
      />
      <StatsStrip
        planLabel={dashboard.account.planLabel}
        preciseDataFresh={dashboard.preciseRecentUsageFresh === true}
        stats={dashboard.stats}
        todayModelBreakdowns={todayActivity?.modelBreakdowns ?? []}
        todayTokens={todayActivity?.tokens ?? 0}
        recentUsageFiveMinute={dashboard.recentUsage24h}
        sevenDayResetAtUnix={dashboard.quota.sevenDay.resetsAtUnix}
        warnings={dashboard.warnings}
      />
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
