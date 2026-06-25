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

interface DashboardPageProps {
  autostartStatus: AutostartStatus;
  codexHome: CodexHomeStatus;
  dashboard: DashboardSnapshot;
  displaySurfaces: DisplaySurfaceSettings;
  floatingSettings: FloatingWindowSettings;
  liveRate: LiveRateSnapshot;
  liveThreadOptions: LiveThreadOption[];
  platform: PlatformCapabilities;
  onCodexHomeChange: (path: string) => Promise<void>;
  onCodexHomeReset: () => Promise<void>;
  onFloatingOpacityChange: (opacity: number) => void;
  onFloatingScaleChange: (scale: number) => void;
  onTokenRateFullScaleChange: (fullScale: number) => void;
  onFloatingUnreadEffectChange: (effect: FloatingUnreadEffect) => void;
  onFloatingGradientChange: (patch: Partial<Pick<FloatingWindowSettings, "gradientStart" | "gradientEnd" | "gradientDirection" | "gradientType">>) => void;
  onFloatingTextToneChange: (textTone: number) => void;
  onFloatingContentVisibilityChange: (contentVisibility: FloatingContentVisibility) => void;
  onLiveThreadSelect: (threadId: string) => void;
  onRefresh: () => Promise<void>;
  onToggleAutostart: () => void;
  onToggleFloating: () => void;
  onToggleStatusTray: () => void;
  refreshing: boolean;
  selectedLiveThreadId: string;
}

export function DashboardPage({
  autostartStatus,
  codexHome,
  dashboard,
  displaySurfaces,
  floatingSettings,
  liveRate,
  liveThreadOptions,
  platform,
  onCodexHomeChange,
  onCodexHomeReset,
  onFloatingOpacityChange,
  onFloatingScaleChange,
  onTokenRateFullScaleChange,
  onFloatingUnreadEffectChange,
  onFloatingGradientChange,
  onFloatingTextToneChange,
  onFloatingContentVisibilityChange,
  onLiveThreadSelect,
  onRefresh,
  onToggleAutostart,
  onToggleFloating,
  onToggleStatusTray,
  refreshing,
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
          generatedAt={dashboard.generatedAt}
          onCodexHomeChange={onCodexHomeChange}
          onCodexHomeReset={onCodexHomeReset}
          onRefresh={onRefresh}
          onToggleAutostart={onToggleAutostart}
          refreshing={refreshing}
        />

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
              onLiveThreadSelect={onLiveThreadSelect}
              onToggleFloating={onToggleFloating}
              onToggleStatusTray={onToggleStatusTray}
              platform={platform}
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
