import { useClientScope } from "../../multiClient/useClientScope";
import type { ClientCostPeriods } from "../../multiClient/originalDashboardProjection";
import type { QuotaItem } from "../../multiClient/integratedClientModel";
import { LiveRateCard } from "../../components/LiveRateCard";
import { CodexRadarStrip } from "../../components/CodexRadarStrip";
import { QuotaStrip } from "../../components/QuotaStrip";
import { StatsStrip } from "../../components/StatsStrip";
import type { FloatingWindowSettings } from "../../floating/floatingSettings";
import type {
  DashboardSnapshot,
  CodexHomeSourceToken,
  DisplaySurfaceSettings,
  LiveRateSnapshot,
  LiveThreadOption,
  PlatformCapabilities,
} from "../../types/dashboard";
import type { SharedAccountAttributionResult } from "../../components/sharedAccountAttribution/model";

interface DashboardSummarySectionProps {
  speedOnly?: boolean;
  clientCosts?: ClientCostPeriods;
  clientQuotaItems?: QuotaItem[];
  includesCodex?: boolean;
  sourceToken?: CodexHomeSourceToken | null;
  dashboard: DashboardSnapshot;
  quotaDashboard?: DashboardSnapshot;
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
  onQuotaSidebarChange: (patch: Pick<Partial<DisplaySurfaceSettings>, "quotaSidebarEnabled" | "quotaSidebarSide">) => void;
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
  speedOnly = false,
  clientCosts,
  clientQuotaItems,
  includesCodex = true,
  quotaDashboard,
  sourceToken = null,
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
  onQuotaSidebarChange,
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
  // Today's model card is a light-summary surface. Do not fall back to the
  // activity-day/5-minute aggregate when that owner has not published yet;
  // doing so would make a chart aggregate look like a current model reading.
  const latestTodayTokens = dashboard.usageSummary?.todayTokens ?? 0;
  const latestTodayModels = dashboard.usageSummary?.todayModelBreakdowns ?? [];
  const scope = useClientScope();
  const quotaData = quotaDashboard ?? dashboard;
  return (
    <>
      {!speedOnly && <>
      <QuotaStrip
        clientItems={clientQuotaItems}
        clientPlanLabels={{codex: quotaData.account.planLabel}}
        includesCodex={includesCodex}
        attributionIdentity={quotaData.attributionIdentity ?? null}
        diagnostics={quotaData.diagnostics}
        onAttributionPreciseRefreshNeeded={onAttributionPreciseRefreshNeeded}
        onAttributionSafetyAcknowledge={onAttributionSafetyAcknowledge}
        onAttributionSafetyRefreshNeeded={onAttributionSafetyRefreshNeeded}
        onAttributionChange={onAttributionChange}
        onQuotaRefreshIntervalChange={onQuotaRefreshIntervalChange}
        onRetryQuotaRefresh={onQuotaRefresh}
        preciseDataAvailable={quotaData.preciseRecentUsageCoveredAt !== null
          && quotaData.preciseRecentUsageCoveredAt !== undefined}
        preciseDataCoveredAt={quotaData.preciseRecentUsageCoveredAt ?? null}
        preciseDataFresh={quotaData.preciseRecentUsageFresh === true}
        preciseObserverEpoch={quotaData.preciseObserverEpoch ?? null}
        preciseObserverStartedAtUnixMicros={quotaData.preciseObserverStartedAtUnixMicros ?? null}
        preciseObserverSequence={quotaData.preciseObserverSequence ?? null}
        preciseAttributionProvenanceEpoch={quotaData.preciseAttributionProvenanceEpoch ?? null}
        preciseAttributionGeneration={quotaData.preciseAttributionGeneration ?? null}
        preciseAttributionUnsafeSinceGeneration={quotaData.preciseAttributionUnsafeSinceGeneration ?? null}
        preciseAttributionUnsafeID={quotaData.preciseAttributionUnsafeId ?? null}
        preciseAttributionCurrentScanUnsafe={quotaData.preciseAttributionCurrentScanUnsafe === true}
        quotaUpdatedAt={quotaData.quotaUpdatedAt ?? null}
        quotaRefreshIntervalMs={quotaRefreshIntervalMs}
        recentUsage24h={quotaData.recentUsage24h}
        snapshot={quotaData.quota}
        sourceHomeIdentity={sourceHomeIdentity}
        warnings={quotaData.warnings}
      />
      <StatsStrip
        clientCosts={clientCosts}
        sourceToken={sourceToken}
        attributionIdentity={dashboard.attributionIdentity ?? null}
        quotaUpdatedAt={dashboard.quotaUpdatedAt}
        planLabel={dashboard.account.planLabel}
        preciseDataFresh={dashboard.preciseRecentUsageFresh === true}
        stats={dashboard.stats}
        todayModelBreakdowns={latestTodayModels}
        todayTokens={latestTodayTokens}
        usageSummaryFresh={dashboard.usageSummaryFresh === true}
        recentUsageFiveMinute={dashboard.recentUsage24h}
        sevenDayResetAtUnix={dashboard.quota.sevenDay.resetsAtUnix}
        warnings={dashboard.warnings}
      />
      </>}
      {includesCodex && <CodexRadarStrip refreshGeneration={radarRefreshGeneration} />}
      {(includesCodex || scope.allowed.some(c => ["claudeCode", "claudeDesktop"].includes(c))) && <LiveRateCard
        includesCodex={includesCodex} localClients={scope.allowed}
        quotaIdentity={dashboard.attributionIdentity} quotaUpdatedAt={dashboard.quotaUpdatedAt}
        sourceToken={sourceToken}
        liveThreadOptions={liveThreadOptions}
        floatingEnabled={displaySurfaces.floatingWindowEnabled}
        quotaSidebarEnabled={displaySurfaces.quotaSidebarEnabled}
        onToggleQuotaSidebar={() => onQuotaSidebarChange({ quotaSidebarEnabled: !displaySurfaces.quotaSidebarEnabled })}
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
      />}
    </>
  );
}
