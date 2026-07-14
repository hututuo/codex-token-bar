import { useEffect, useState } from "react";
import { DashboardHeader } from "../components/DashboardHeader";
import { AppSettingsDialog } from "../components/settings/AppSettingsDialog";
import type { FloatingWindowSettings } from "../floating/floatingSettings";
import type {
  AutostartStatus,
  CodexHomeStatus,
  DashboardSnapshot,
  DisplaySurfaceSettings,
  FloatingContentVisibility,
  FloatingPalettePatch,
  FloatingUnreadEffect,
  LiveRateSnapshot,
  LiveThreadOption,
  PlatformCapabilities,
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

  useEffect(() => {
    let disposed = false;
    let unlisten: (() => void) | null = null;
    void desktopPlatform.onOpenAppSettings(() => {
      if (!disposed) {
        window.localStorage.removeItem("open-app-settings-requested");
        setSettingsOpen(true);
      }
    }).then((handler) => {
      if (disposed) handler();
      else unlisten = handler;
    });
    return () => {
      disposed = true;
      unlisten?.();
    };
  }, []);

  return (
    <main className="app-shell">
      <section className="dashboard">
        <DashboardHeader
          account={dashboard.account}
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
          onOpenSettings={() => setSettingsOpen(true)}
          onRefresh={onRefresh}
          onReconnectThreadDelete={onReconnectThreadDelete}
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
              onOpenSettings={() => setSettingsOpen(true)}
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
        autostartStatus={autostartStatus}
        displaySurfaces={displaySurfaces}
        floatingSettings={floatingSettings}
        liveRateEnabled={liveRateEnabled}
        onClose={() => setSettingsOpen(false)}
        onFloatingContentVisibilityChange={onFloatingContentVisibilityChange}
        onFloatingGradientChange={onFloatingGradientChange}
        onFloatingOpacityChange={onFloatingOpacityChange}
        onFloatingScaleChange={onFloatingScaleChange}
        onFloatingTextToneChange={onFloatingTextToneChange}
        onFloatingUnreadEffectChange={onFloatingUnreadEffectChange}
        onQuotaRefreshIntervalChange={onQuotaRefreshIntervalChange}
        onToggleAutostart={onToggleAutostart}
        onToggleFloating={onToggleFloating}
        onToggleLiveRate={onToggleLiveRate}
        onToggleStatusTray={onToggleStatusTray}
        open={settingsOpen}
        platform={platform}
        quotaRefreshIntervalMs={quotaRefreshIntervalMs}
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
