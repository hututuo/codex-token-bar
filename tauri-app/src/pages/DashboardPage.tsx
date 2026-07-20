import { useCallback, useEffect, useState } from "react";
import { DashboardHeader } from "../components/DashboardHeader";
import { AppSettingsDialog, type AppSettingsCategory } from "../components/settings/AppSettingsDialog";
import type { FloatingWindowSettings } from "../floating/floatingSettings";
import type {
  AutostartStatus,
  AutoResumeRuntimeStatus,
  AutoResumeSettings,
  AutoResumeThreadOption,
  CodexHomeStatus,
  DashboardSnapshot,
  DisplaySurfaceSettings,
  FloatingContentVisibility,
  FloatingPalettePatch,
  FloatingUnreadEffect,
  LiveRateSnapshot,
  LiveThreadOption,
  PlatformCapabilities,
  SessionEnhancementSettings,
  ProviderRepairSnapshot,
} from "../types/dashboard";
import { DashboardAnalyticsSection } from "./dashboard/DashboardAnalyticsSection";
import { DashboardSummarySection } from "./dashboard/DashboardSummarySection";
import { ProviderRepairPanel } from "./dashboard/ProviderRepairPanel";
import { useDashboardPageLifecycle } from "./dashboard/useDashboardPageLifecycle";
import { downloadDashboardCsv, downloadDashboardPng } from "../utils/dashboardExport";
import type { ThreadDeleteBridgeStatus } from "../api/threadDeleteClient";
import { desktopPlatform } from "../platform/desktop";

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
  displaySurfaces: DisplaySurfaceSettings;
  floatingSettings: FloatingWindowSettings;
  customAccountDisplayName: string;
  quotaRefreshIntervalMs: number;
  liveRate: LiveRateSnapshot;
  liveThreadOptions: LiveThreadOption[];
  platform: PlatformCapabilities;
  onCodexHomeChange: (path: string) => Promise<void>;
  onCodexHomeReset: () => Promise<void>;
  onCustomAccountDisplayNameChange: (displayName: string) => Promise<void>;
  onCheckForUpdate: () => Promise<void>;
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
  onToggleLiveRate: () => void;
  onRefresh: () => Promise<void>;
  onCancelAutoResume: () => Promise<void>;
  onRefreshAutoResume: () => Promise<void>;
  onRunAutoResume: () => Promise<void>;
  onSaveAutoResume: (settings: AutoResumeSettings) => Promise<void>;
  onSaveSessionEnhancements: (settings: SessionEnhancementSettings) => Promise<void>;
  onReconnectThreadDelete: () => Promise<void>;
  onToggleAutostart: () => void;
  onToggleFloating: () => void;
  onToggleStatusTray: () => void;
  usageCacheInitializing: boolean;
  providerRepairOpen: boolean;
  providerRepairSnapshot: ProviderRepairSnapshot;
  providerSourceKey: string;
  radarRefreshGeneration: number;
  refreshing: boolean;
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
  displaySurfaces,
  floatingSettings,
  customAccountDisplayName,
  quotaRefreshIntervalMs,
  liveRate,
  liveThreadOptions,
  platform,
  onCodexHomeChange,
  onCodexHomeReset,
  onCustomAccountDisplayNameChange,
  onCheckForUpdate,
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
  usageCacheInitializing,
  providerRepairOpen,
  providerRepairSnapshot,
  providerSourceKey,
  radarRefreshGeneration,
  refreshing,
  appUpdateState,
  liveRateEnabled,
  selectedLiveThreadId,
  threadDeleteBridgeStatus,
}: DashboardPageProps) {
  const { analyticsReady, summaryReady } = useDashboardPageLifecycle();
  const [settingsOpen, setSettingsOpen] = useState(consumePendingSettingsRequest);
  const [settingsCategory, setSettingsCategory] = useState<AppSettingsCategory>("general");
  const closeSettings = useCallback(() => setSettingsOpen(false), []);
  const openSettings = useCallback((category: AppSettingsCategory = "general") => {
    setSettingsCategory(category);
    setSettingsOpen(true);
  }, []);

  useEffect(() => {
    let disposed = false;
    let unlisten: (() => void) | null = null;
    void desktopPlatform.onOpenAppSettings(() => {
      if (!disposed) {
        window.localStorage.removeItem("open-app-settings-requested");
        openSettings("general");
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
          onCodexHomeChange={onCodexHomeChange}
          onCodexHomeReset={onCodexHomeReset}
          onCustomAccountDisplayNameChange={onCustomAccountDisplayNameChange}
          onCheckForUpdate={onCheckForUpdate}
          onExportCsv={() => downloadDashboardCsv(dashboard)}
          onExportPng={() => {
            void downloadDashboardPng(dashboard);
          }}
          onOpenProviderRepair={onProviderRepairOpen}
          onOpenSettings={openSettings}
          onRefresh={onRefresh}
          onToggleAutostart={onToggleAutostart}
          refreshing={refreshing}
          appUpdateState={appUpdateState}
          threadDeleteBridgeStatus={threadDeleteBridgeStatus}
        />

        {usageCacheInitializing ? <UsageCacheInitializationNotice /> : null}

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
              onToggleLiveRate={onToggleLiveRate}
              onToggleFloating={onToggleFloating}
              onToggleStatusTray={onToggleStatusTray}
              platform={platform}
              radarRefreshGeneration={radarRefreshGeneration}
              refreshing={refreshing}
              liveRateEnabled={liveRateEnabled}
              selectedLiveThreadId={selectedLiveThreadId}
              usageCacheInitializing={usageCacheInitializing}
            />
            {analyticsReady ? (
              <DashboardAnalyticsSection dashboard={dashboard} />
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
        onQuotaRefreshIntervalChange={onQuotaRefreshIntervalChange}
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
        open={settingsOpen}
        platform={platform}
        quotaRefreshIntervalMs={quotaRefreshIntervalMs}
        sessionEnhancements={sessionEnhancements}
        threadDeleteBridgeStatus={threadDeleteBridgeStatus}
      />
    </main>
  );
}

function consumePendingSettingsRequest(): boolean {
  const pending = window.localStorage.getItem("open-app-settings-requested") === "1";
  if (pending) window.localStorage.removeItem("open-app-settings-requested");
  return pending;
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
