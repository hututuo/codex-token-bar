import { DashboardHeader } from "../components/DashboardHeader";
import type { FloatingWindowSettings } from "../floating/floatingSettings";
import type {
  AutostartStatus,
  CodexHomeStatus,
  DashboardSnapshot,
  DisplaySurfaceSettings,
  FloatingContentVisibility,
  FloatingUnreadEffect,
  LiveRateSnapshot,
  LiveThreadOption,
  PlatformCapabilities,
} from "../types/dashboard";
import { DashboardAnalyticsSection } from "./dashboard/DashboardAnalyticsSection";
import { DashboardSummarySection } from "./dashboard/DashboardSummarySection";
import { useDashboardPageLifecycle } from "./dashboard/useDashboardPageLifecycle";
import { downloadDashboardCsv, downloadDashboardPng } from "../utils/dashboardExport";

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
  onFloatingGradientChange: (patch: Partial<Pick<FloatingWindowSettings, "gradientStart" | "gradientEnd" | "gradientDirection" | "gradientType">>) => void;
  onFloatingTextToneChange: (textTone: number) => void;
  onFloatingContentVisibilityChange: (contentVisibility: FloatingContentVisibility) => void;
  onLiveRateReset: () => Promise<void>;
  onLiveThreadSelect: (threadId: string) => void;
  onQuotaRefresh: () => void;
  onToggleLiveRate: () => void;
  onRefresh: () => Promise<void>;
  onToggleAutostart: () => void;
  onToggleFloating: () => void;
  onToggleStatusTray: () => void;
  usageCacheInitializing: boolean;
  radarRefreshGeneration: number;
  refreshing: boolean;
  appUpdateState: AppUpdateViewState;
  liveRateEnabled: boolean;
  selectedLiveThreadId: string;
}

export function DashboardPage({
  autostartStatus,
  codexHome,
  dashboard,
  displaySurfaces,
  floatingSettings,
  customAccountDisplayName,
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
  onLiveThreadSelect,
  onQuotaRefresh,
  onToggleLiveRate,
  onRefresh,
  onToggleAutostart,
  onToggleFloating,
  onToggleStatusTray,
  usageCacheInitializing,
  radarRefreshGeneration,
  refreshing,
  appUpdateState,
  liveRateEnabled,
  selectedLiveThreadId,
}: DashboardPageProps) {
  const { analyticsReady, summaryReady } = useDashboardPageLifecycle();

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
          onRefresh={onRefresh}
          onToggleAutostart={onToggleAutostart}
          refreshing={refreshing}
          appUpdateState={appUpdateState}
        />

        {usageCacheInitializing ? <UsageCacheInitializationNotice /> : null}

        {summaryReady ? (
          <>
            <DashboardSummarySection
              dashboard={dashboard}
              displaySurfaces={displaySurfaces}
              floatingSettings={floatingSettings}
              liveRate={liveRate}
              liveThreadOptions={liveThreadOptions}
              onFloatingOpacityChange={onFloatingOpacityChange}
              onFloatingScaleChange={onFloatingScaleChange}
              onTokenRateFullScaleChange={onTokenRateFullScaleChange}
              onFloatingUnreadEffectChange={onFloatingUnreadEffectChange}
              onFloatingGradientChange={onFloatingGradientChange}
              onFloatingTextToneChange={onFloatingTextToneChange}
              onFloatingContentVisibilityChange={onFloatingContentVisibilityChange}
              onLiveRateReset={onLiveRateReset}
              onLiveThreadSelect={onLiveThreadSelect}
              onQuotaRefresh={onQuotaRefresh}
              onToggleLiveRate={onToggleLiveRate}
              onToggleFloating={onToggleFloating}
              onToggleStatusTray={onToggleStatusTray}
              platform={platform}
              radarRefreshGeneration={radarRefreshGeneration}
              liveRateEnabled={liveRateEnabled}
              selectedLiveThreadId={selectedLiveThreadId}
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
    </main>
  );
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
