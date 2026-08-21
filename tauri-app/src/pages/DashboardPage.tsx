import { lazy, Suspense, useCallback, useEffect, useState } from "react";
import { DashboardHeader } from "../components/DashboardHeader";
import { AppSettingsDialog, type AppSettingsCategory } from "../components/settings/AppSettingsDialog";
import type { FloatingWindowSettings } from "../floating/floatingSettings";
import type {
  AutostartStatus,
  AutoResumeRuntimeStatus,
  AutoResumeSettings,
  AutoResumeThreadOption,
  CodexHomeSourceToken,
  CodexHomeStatus,
  DashboardSnapshot,
  DisplaySurfaceSettings,
  FloatingContentVisibility,
  FloatingPalettePatch,
  FloatingUnreadEffect,
  LiveRateSnapshot,
  LiveThreadOption,
  PlatformCapabilities,
  PreciseDashboardProgress,
  SessionEnhancementSettings,
  StatusMetricId,
  StatusMetricLabelStyle,
  StatusSummarySectionId,
  UsageRefreshSettings,
  ProviderRepairSnapshot,
  RunningThreadSummary,
} from "../types/dashboard";
import { DashboardAnalyticsSection } from "./dashboard/DashboardAnalyticsSection";
import { DashboardSummarySection } from "./dashboard/DashboardSummarySection";
import { ProviderRepairPanel } from "./dashboard/ProviderRepairPanel";
import { useDashboardPageLifecycle } from "./dashboard/useDashboardPageLifecycle";
import { downloadDashboardCsv, downloadDashboardPng } from "../utils/dashboardExport";
import type { ThreadDeleteBridgeStatus } from "../api/threadDeleteClient";
import type { CommandFailureDiagnostic } from "../api/client";
import { buildLocalCommandNoticeLines } from "../state/localCommandNotice";
import { desktopPlatform } from "../platform/desktop";
import type { SharedAccountAttributionResult } from "../components/sharedAccountAttribution/model";
import { floatingSnapshotForDashboardPreview } from "../surfaces/compactPanelSnapshotModel";
import type { PreciseIndexUpgradeState } from "../state/useDashboardData";

const SessionManagementWorkspace = lazy(async () => {
  const module = await import("./SessionManagementWorkspace");
  return { default: module.SessionManagementWorkspace };
});

interface AppUpdateViewState {
  kind: "idle" | "checking" | "available" | "installing" | "error";
  message: string;
}

interface DashboardPageProps {
  autostartStatus: AutostartStatus;
  autoResumeCancelling: boolean;
  autoResumeError: string | null;
  autoResumeLoading: boolean;
  autoResumeRunning: boolean;
  autoResumeSaving: boolean;
  autoResumeSettings: AutoResumeSettings;
  autoResumeStatus: AutoResumeRuntimeStatus;
  autoResumeThreads: AutoResumeThreadOption[];
  sessionEnhancements: SessionEnhancementSettings;
  codexHome: CodexHomeStatus;
  dashboard: DashboardSnapshot;
  diagnostics: CommandFailureDiagnostic[];
  settingsError: string | null;
  displaySurfaces: DisplaySurfaceSettings;
  floatingSettings: FloatingWindowSettings;
  customAccountDisplayName: string;
  quotaRefreshIntervalMs: number;
  usageLightRefreshIntervalSeconds: number;
  usageVisibleAggregateIntervalMinutes: number;
  usageBackgroundAggregateIntervalMinutes: number;
  liveRate: LiveRateSnapshot;
  liveThreadOptions: LiveThreadOption[];
  platform: PlatformCapabilities;
  onCodexHomeChange: (path: string) => Promise<void>;
  onCodexHomeReset: () => Promise<void>;
  onCustomAccountDisplayNameChange: (displayName: string) => Promise<void>;
  onCheckForUpdate: () => Promise<void>;
  onDeferPreciseIndexUpgrade: () => void;
  onRebuildPreciseIndex: () => Promise<void>;
  onFloatingOpacityChange: (opacity: number) => void;
  onFloatingScaleChange: (scale: number) => void;
  onTokenRateFullScaleChange: (fullScale: number) => void;
  onFloatingUnreadEffectChange: (effect: FloatingUnreadEffect) => void;
  onFloatingGradientChange: (patch: FloatingPalettePatch) => void;
  onFloatingTextToneChange: (textTone: number) => void;
  onFloatingContentVisibilityChange: (contentVisibility: FloatingContentVisibility) => void;
  onLiveRateReset: () => Promise<void>;
  onLiveRateRetry: () => void;
  onAcknowledgeUnread: () => Promise<void>;
  onLiveThreadSelect: (threadId: string) => void;
  onProviderRepairClose: () => void;
  onProviderRepairOpen: () => void;
  onProviderRepairSnapshotChange: (snapshot: ProviderRepairSnapshot) => void;
  onQuotaRefresh: () => void;
  onQuotaRefreshIntervalChange: (intervalMs: number) => Promise<void>;
  onUsageRefreshSettingsChange: (settings: UsageRefreshSettings) => Promise<void>;
  onAttributionPreciseRefreshNeeded: (comparisonUpdatedAt: string) => void;
  onAttributionSafetyAcknowledge: (
    provenanceEpoch: string,
    unsafeID: string,
    throughGeneration: number,
  ) => Promise<boolean>;
  onAttributionSafetyRefreshNeeded: () => void;
  onToggleLiveRate: () => void;
  onRefresh: () => Promise<void>;
  onCancelAutoResume: () => Promise<void>;
  onRefreshAutoResume: () => Promise<void>;
  onRunAutoResume: (taskId: string) => Promise<void>;
  onSaveAutoResume: (settings: AutoResumeSettings) => Promise<void>;
  onSaveSessionEnhancements: (settings: SessionEnhancementSettings) => Promise<void>;
  onReconnectThreadDelete: () => Promise<void>;
  onToggleAutostart: () => void;
  onToggleFloating: () => void;
  onToggleStatusTray: () => void;
  onStatusMetricOrderChange: (order: StatusMetricId[]) => void;
  onStatusMetricLabelStyleChange: (style: StatusMetricLabelStyle) => void;
  onStatusSummaryOrderChange: (order: StatusSummarySectionId[]) => void;
  usageCacheInitializing: boolean;
  providerRepairOpen: boolean;
  providerRepairSnapshot: ProviderRepairSnapshot;
  providerSourceKey: string;
  sourceToken: CodexHomeSourceToken | null;
  runningThreads: RunningThreadSummary;
  radarRefreshGeneration: number;
  refreshing: boolean;
  preciseRequestInFlight: boolean;
  preciseProgress: PreciseDashboardProgress | null;
  preciseIndexUpgradeRequired: PreciseIndexUpgradeState | null;
  appUpdateState: AppUpdateViewState;
  liveRateEnabled: boolean;
  selectedLiveThreadId: string;
  threadDeleteBridgeStatus: ThreadDeleteBridgeStatus;
}

export function DashboardPage({
  autostartStatus,
  autoResumeCancelling,
  autoResumeError,
  autoResumeLoading,
  autoResumeRunning,
  autoResumeSaving,
  autoResumeSettings,
  autoResumeStatus,
  autoResumeThreads,
  sessionEnhancements,
  codexHome,
  dashboard,
  diagnostics,
  settingsError,
  displaySurfaces,
  floatingSettings,
  customAccountDisplayName,
  quotaRefreshIntervalMs,
  usageLightRefreshIntervalSeconds,
  usageVisibleAggregateIntervalMinutes,
  usageBackgroundAggregateIntervalMinutes,
  liveRate,
  liveThreadOptions,
  platform,
  onCodexHomeChange,
  onCodexHomeReset,
  onCustomAccountDisplayNameChange,
  onCheckForUpdate,
  onDeferPreciseIndexUpgrade,
  onRebuildPreciseIndex,
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
  onProviderRepairClose,
  onProviderRepairOpen,
  onProviderRepairSnapshotChange,
  onQuotaRefresh,
  onQuotaRefreshIntervalChange,
  onUsageRefreshSettingsChange,
  onAttributionPreciseRefreshNeeded,
  onAttributionSafetyAcknowledge,
  onAttributionSafetyRefreshNeeded,
  onCancelAutoResume,
  onRefreshAutoResume,
  onRunAutoResume,
  onSaveAutoResume,
  onSaveSessionEnhancements,
  onToggleLiveRate,
  onRefresh,
  onReconnectThreadDelete,
  onToggleAutostart,
  onToggleFloating,
  onToggleStatusTray,
  onStatusMetricOrderChange,
  onStatusMetricLabelStyleChange,
  onStatusSummaryOrderChange,
  usageCacheInitializing,
  providerRepairOpen,
  providerRepairSnapshot,
  providerSourceKey,
  sourceToken,
  runningThreads,
  radarRefreshGeneration,
  refreshing,
  preciseRequestInFlight,
  preciseProgress,
  preciseIndexUpgradeRequired,
  appUpdateState,
  liveRateEnabled,
  selectedLiveThreadId,
  threadDeleteBridgeStatus,
}: DashboardPageProps) {
  const [sharedAccountAttribution, setSharedAccountAttribution] = useState<SharedAccountAttributionResult | null>(null);
  const { analyticsReady, summaryReady } = useDashboardPageLifecycle();
  const [initialSettingsRequest] = useState(consumePendingSettingsRequest);
  const [settingsOpen, setSettingsOpen] = useState(initialSettingsRequest !== null);
  const [settingsCategory, setSettingsCategory] = useState<AppSettingsCategory>(
    initialSettingsRequest ?? "general",
  );
  const [sessionManagementOpen, setSessionManagementOpen] = useState(false);
  const [indexRebuildError, setIndexRebuildError] = useState<string | null>(null);
  const closeSettings = useCallback(() => setSettingsOpen(false), []);
  const openSettings = useCallback((category: AppSettingsCategory = "general") => {
    setSettingsCategory(category);
    setSettingsOpen(true);
  }, []);
  const openSessionManagement = useCallback(() => {
    setSettingsOpen(false);
    setSessionManagementOpen(true);
  }, []);

  useEffect(() => {
    let disposed = false;
    let unlisten: (() => void) | null = null;
    void desktopPlatform.onOpenAppSettings(() => {
      if (!disposed) {
        openSettings(consumePendingSettingsRequest() ?? "general");
      }
    }).then((handler) => {
      if (disposed) handler();
      else unlisten = handler;
    });
    return () => {
      disposed = true;
      unlisten?.();
    };
  }, [openSettings]);

  return (
    <main className="app-shell">
      <section className="dashboard">
        <DashboardHeader
          account={dashboard.account}
          autoResumeEnabled={autoResumeSettings.enabled}
          autostartStatus={autostartStatus}
          codexHome={codexHome}
          customAccountDisplayName={customAccountDisplayName}
          generatedAt={dashboard.generatedAt}
          aggregateCoveredAt={dashboard.settledThrough
            ?? dashboard.preciseRecentUsageCoveredAt
            ?? null}
          usageSummaryUpdatedAt={dashboard.usageSummaryUpdatedAt ?? dashboard.generatedAt}
          usageSummaryCheckedAt={dashboard.usageSummaryCheckedAt ?? null}
          usageSummaryDataUpdatedAt={dashboard.usageSummaryDataUpdatedAt ?? null}
          usageSummaryFresh={dashboard.usageSummaryFresh === true}
          preciseDataFresh={dashboard.preciseRecentUsageFresh === true}
          preciseRequestInFlight={preciseRequestInFlight}
          exactGeneration={dashboard.exactGeneration ?? null}
          aggregateExactGeneration={dashboard.aggregateExactGeneration ?? null}
          aggregatePublishedGeneration={dashboard.aggregatePublishedGeneration ?? null}
          onCodexHomeChange={onCodexHomeChange}
          onCodexHomeReset={onCodexHomeReset}
          onCustomAccountDisplayNameChange={onCustomAccountDisplayNameChange}
          onCheckForUpdate={onCheckForUpdate}
          onExportCsv={() => downloadDashboardCsv(dashboard)}
          onExportPng={() => {
            void downloadDashboardPng(dashboard);
          }}
          onOpenProviderRepair={onProviderRepairOpen}
          onOpenSessionManagement={openSessionManagement}
          onOpenSettings={openSettings}
          onRefresh={onRefresh}
          onToggleAutostart={onToggleAutostart}
          refreshing={refreshing}
          preciseProgress={preciseProgress}
          appUpdateState={appUpdateState}
          threadDeleteBridgeStatus={threadDeleteBridgeStatus}
          runningThreads={runningThreads}
        />

        {preciseIndexUpgradeRequired ? (
          <section aria-live="assertive" className="index-upgrade-warning" role="alert">
            <span aria-hidden="true" className="index-upgrade-warning__icon">!</span>
            <div className="index-upgrade-warning__content">
              <strong>精确统计索引需要更高版本的软件</strong>
              <span>
                {preciseIndexUpgradeRequired.message} 当前已停止此目录的精确统计自动重试；上次可信数据继续保留，额度、雷达和设置不受影响。
              </span>
              {preciseIndexUpgradeRequired.deferred ? (
                <small>已选择稍后处理。本次运行期间不会再尝试写入这个索引。</small>
              ) : null}
              {indexRebuildError ? <small className="is-error">{indexRebuildError}</small> : null}
            </div>
            <div className="index-upgrade-warning__actions">
              <button onClick={() => { void onCheckForUpdate(); }} type="button">升级软件</button>
              <button
                disabled={preciseIndexUpgradeRequired.deferred}
                onClick={onDeferPreciseIndexUpgrade}
                type="button"
              >
                {preciseIndexUpgradeRequired.deferred ? "已暂停" : "稍后处理"}
              </button>
              <button
                className="is-destructive"
                onClick={() => {
                  const confirmed = window.confirm(
                    "确定为当前版本重建精确统计索引吗？\n\n只会删除跨平台版的派生索引和绑定缓存；不会删除 Codex 会话 JSONL、state_5.sqlite、设置、额度历史或雷达数据。重建期间会暂时占用 CPU 和磁盘。",
                  );
                  if (!confirmed) return;
                  setIndexRebuildError(null);
                  void onRebuildPreciseIndex().catch((error) => {
                    setIndexRebuildError(error instanceof Error ? error.message : String(error));
                  });
                }}
                type="button"
              >
                为当前版本重建索引
              </button>
            </div>
          </section>
        ) : null}

        {usageCacheInitializing ? <UsageCacheInitializationNotice /> : null}

        <LocalCommandFailureNotice settingsError={settingsError} diagnostics={diagnostics} />

        {summaryReady ? (
          <>
            <DashboardSummarySection
              dashboard={dashboard}
              displaySurfaces={displaySurfaces}
              floatingSettings={floatingSettings}
              quotaRefreshIntervalMs={quotaRefreshIntervalMs}
              liveRate={liveRate}
              liveThreadOptions={liveThreadOptions}
              onTokenRateFullScaleChange={onTokenRateFullScaleChange}
              onOpenSettings={() => openSettings("general")}
              onLiveRateReset={onLiveRateReset}
              onLiveRateRetry={onLiveRateRetry}
              onAcknowledgeUnread={onAcknowledgeUnread}
              onLiveThreadSelect={onLiveThreadSelect}
              onQuotaRefresh={onQuotaRefresh}
              onQuotaRefreshIntervalChange={onQuotaRefreshIntervalChange}
              onAttributionPreciseRefreshNeeded={onAttributionPreciseRefreshNeeded}
              onAttributionSafetyAcknowledge={onAttributionSafetyAcknowledge}
              onAttributionSafetyRefreshNeeded={onAttributionSafetyRefreshNeeded}
              onAttributionChange={setSharedAccountAttribution}
              onToggleLiveRate={onToggleLiveRate}
              onToggleFloating={onToggleFloating}
              onToggleStatusTray={onToggleStatusTray}
              platform={platform}
              radarRefreshGeneration={radarRefreshGeneration}
              refreshing={refreshing}
              liveRateEnabled={liveRateEnabled}
              selectedLiveThreadId={selectedLiveThreadId}
              sourceHomeIdentity={sourceToken === null
                ? providerSourceKey
                : `${sourceToken.canonicalHomeKey}\u0000${sourceToken.physicalHomeKey}`}
              usageCacheInitializing={usageCacheInitializing}
            />
            {analyticsReady ? (
              <DashboardAnalyticsSection
                dashboard={dashboard}
                sharedAccountAttribution={sharedAccountAttribution}
              />
            ) : (
              <section className="analytics-boot" aria-label="图表区域正在准备">
                <span>正在准备图表和排行...</span>
              </section>
            )}
          </>
        ) : (
          <section className="analytics-boot" aria-label="统计区域正在准备">
            <span>正在准备统计和实时速率...</span>
          </section>
        )}
      </section>
      <ProviderRepairPanel
        onClose={onProviderRepairClose}
        onSnapshotChange={onProviderRepairSnapshotChange}
        open={providerRepairOpen}
        providerSourceKey={providerSourceKey}
        snapshot={providerRepairSnapshot}
      />
      <AppSettingsDialog
        appUpdateState={appUpdateState}
        autostartStatus={autostartStatus}
        autoResumeCancelling={autoResumeCancelling}
        autoResumeError={autoResumeError}
        autoResumeLoading={autoResumeLoading}
        autoResumeRunning={autoResumeRunning}
        autoResumeSaving={autoResumeSaving}
        autoResumeSettings={autoResumeSettings}
        autoResumeStatus={autoResumeStatus}
        autoResumeThreads={autoResumeThreads}
        codexHome={codexHome}
        displaySurfaces={displaySurfaces}
        floatingSettings={floatingSettings}
        floatingPreviewSnapshot={floatingSnapshotForDashboardPreview(liveRate, dashboard)}
        floatingPreviewRunningThreads={runningThreads}
        initialCategory={settingsCategory}
        liveRateEnabled={liveRateEnabled}
        onCheckForUpdate={onCheckForUpdate}
        onClose={closeSettings}
        onCodexHomeChange={onCodexHomeChange}
        onCodexHomeReset={onCodexHomeReset}
        onFloatingContentVisibilityChange={onFloatingContentVisibilityChange}
        onFloatingGradientChange={onFloatingGradientChange}
        onFloatingOpacityChange={onFloatingOpacityChange}
        onFloatingScaleChange={onFloatingScaleChange}
        onFloatingTextToneChange={onFloatingTextToneChange}
        onFloatingUnreadEffectChange={onFloatingUnreadEffectChange}
        onOpenProviderRepair={onProviderRepairOpen}
        onOpenSessionManagement={openSessionManagement}
        onQuotaRefreshIntervalChange={onQuotaRefreshIntervalChange}
        onUsageRefreshSettingsChange={onUsageRefreshSettingsChange}
        onCancelAutoResume={onCancelAutoResume}
        onRefreshAutoResume={onRefreshAutoResume}
        onReconnectThreadDelete={onReconnectThreadDelete}
        onRunAutoResume={onRunAutoResume}
        onSaveAutoResume={onSaveAutoResume}
        onSaveSessionEnhancements={onSaveSessionEnhancements}
        onTokenRateFullScaleChange={onTokenRateFullScaleChange}
        onToggleAutostart={onToggleAutostart}
        onToggleFloating={onToggleFloating}
        onToggleLiveRate={onToggleLiveRate}
        onToggleStatusTray={onToggleStatusTray}
        onStatusMetricOrderChange={onStatusMetricOrderChange}
        onStatusMetricLabelStyleChange={onStatusMetricLabelStyleChange}
        onStatusSummaryOrderChange={onStatusSummaryOrderChange}
        open={settingsOpen}
        platform={platform}
        quotaRefreshIntervalMs={quotaRefreshIntervalMs}
        usageLightRefreshIntervalSeconds={usageLightRefreshIntervalSeconds}
        usageVisibleAggregateIntervalMinutes={usageVisibleAggregateIntervalMinutes}
        usageBackgroundAggregateIntervalMinutes={usageBackgroundAggregateIntervalMinutes}
        sessionEnhancements={sessionEnhancements}
        threadDeleteBridgeStatus={threadDeleteBridgeStatus}
      />
      {sessionManagementOpen && sourceToken !== null ? (
        <Suspense
          fallback={(
            <div className="session-management-overlay">
              <section
                aria-label="会话管理"
                aria-modal="true"
                className="session-management-workspace session-management-workspace--boot"
                role="dialog"
              >
                <div className="session-management-loading" aria-live="polite">
                  <span aria-hidden="true" />
                  <strong>正在打开会话管理</strong>
                  <p>主界面保持可用，会话目录将在工作面内单独读取。</p>
                </div>
              </section>
            </div>
          )}
        >
          <SessionManagementWorkspace
            onClose={() => setSessionManagementOpen(false)}
            open
            sourceToken={sourceToken}
          />
        </Suspense>
      ) : null}
    </main>
  );
}

function consumePendingSettingsRequest(): AppSettingsCategory | null {
  const pending = window.localStorage.getItem("open-app-settings-requested");
  if (pending === null) {
    return null;
  }
  window.localStorage.removeItem("open-app-settings-requested");
  return pending === "status" ? "status" : "general";
}

function UsageCacheInitializationNotice() {
  return (
    <section className="usage-cache-notice" aria-label="本地统计缓存初始化提示">
      <span className="usage-cache-notice-dot" aria-hidden="true" />
      <div>
        <strong>正在初始化本地统计缓存</strong>
        <span>首次打开或更新后可能需要一点时间，只读取本机 Codex 记录，不上传数据。</span>
      </div>
    </section>
  );
}

function LocalCommandFailureNotice({
  settingsError,
  diagnostics,
}: {
  settingsError: string | null;
  diagnostics: CommandFailureDiagnostic[];
}) {
  const lines = buildLocalCommandNoticeLines(settingsError, diagnostics);
  if (lines.length === 0) {
    return null;
  }
  return (
    <section className="local-command-notice" role="alert" aria-label="本地操作失败提示">
      <span className="local-command-notice-dot" aria-hidden="true" />
      <div className="local-command-notice-lines">
        {lines.map((line) => (
          <span key={line.key}>{line.text}</span>
        ))}
      </div>
    </section>
  );
}
