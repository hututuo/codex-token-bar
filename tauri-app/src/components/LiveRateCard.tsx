import type { LiveRateSnapshot, PlatformCapabilities } from "../types/dashboard";
import type { FloatingWindowSettings } from "../floating/floatingSettings";
import { LiveRateMeter } from "./liveRate/LiveRateMeter";
import { liveRateNotice } from "./liveRate/liveRateNotice";

interface LiveRateCardProps {
  floatingSettings: FloatingWindowSettings;
  floatingEnabled: boolean;
  quotaSidebarEnabled: boolean;
  onToggleQuotaSidebar: () => void;
  onTokenRateFullScaleChange: (fullScale: number) => void;
  onOpenSettings: () => void;
  onLiveRateReset: () => Promise<void>;
  onLiveRateRetry: () => void;
  onAcknowledgeUnread: () => Promise<void>;
  onToggleLiveRate: () => void;
  onToggleFloating: () => void;
  onToggleStatusTray: () => void;
  liveRateEnabled: boolean;
  platform: PlatformCapabilities;
  refreshing?: boolean;
  snapshot: LiveRateSnapshot;
  statusTrayLiveTextEnabled: boolean;
  usageCacheInitializing?: boolean;
}

export function LiveRateCard({
  floatingSettings,
  floatingEnabled,
  quotaSidebarEnabled,
  onToggleQuotaSidebar,
  onTokenRateFullScaleChange,
  onOpenSettings,
  onLiveRateReset,
  onLiveRateRetry,
  onAcknowledgeUnread,
  onToggleLiveRate,
  onToggleFloating,
  onToggleStatusTray,
  liveRateEnabled,
  platform,
  refreshing = false,
  snapshot,
  statusTrayLiveTextEnabled,
  usageCacheInitializing = false,
}: LiveRateCardProps) {
  const notice = liveRateNotice(snapshot, {
    liveRateEnabled,
    refreshing,
    usageCacheInitializing,
  });
  const resetDisabled = !liveRateEnabled || notice?.kind === "pending";
  const resetTitle =
    notice?.kind === "pending"
      ? notice.message
      : "清空当前滚动窗口，重新统计整体速率";
  const pendingNotice = notice?.kind === "pending" ? notice : null;
  const failureNotice = notice?.kind === "failure" ? notice : null;
  const subtitle = pendingNotice
    ? `${pendingNotice.title} · ${pendingNotice.message}`
    : liveRateEnabled
      ? "含输出与工具输入流 · 部分流式可能延迟"
      : "实时速率已关闭";

  return (
    <section className={liveRateEnabled ? "live-card" : "live-card is-live-disabled"} aria-label="实时速率">
      <div className="section-title-row">
        <div>
          <div className="live-heading-line">
            <h2>全会话实时速度</h2>
            <button
              type="button"
              className={liveRateEnabled ? "live-rate-switch is-active" : "live-rate-switch"}
              onClick={onToggleLiveRate}
              aria-pressed={liveRateEnabled}
              title="关闭后停止实时速率监控，但不影响用量、额度和雷达统计"
            >
              实时速率 {liveRateEnabled ? "开" : "关"}
            </button>
          </div>
          <span
            className={pendingNotice ? "live-title-status is-pending" : "live-title-status"}
            role={pendingNotice ? "status" : undefined}
            aria-live={pendingNotice ? "polite" : undefined}
          >
            {subtitle}
          </span>
        </div>
        <div className="live-title-actions">
          <button
            type="button"
            className="live-reset-button"
            disabled={resetDisabled}
            onClick={() => {
              void onLiveRateReset();
            }}
            title={resetTitle}
            aria-label="重置整体速率"
          >
            重置整体速率
          </button>
        </div>
      </div>

      {failureNotice !== null ? (
        <div className="live-rate-warning" role="status">
          <div>
            <strong>{failureNotice.title}</strong>
            <span>{failureNotice.message}</span>
          </div>
          {failureNotice.retryable ? <button type="button" onClick={onLiveRateRetry}>重试</button> : null}
        </div>
      ) : null}

      <div className="live-grid">
        <div className={liveRateEnabled ? "live-left" : "live-left is-live-disabled"}>
          <LiveRateMeter
            fullScale={floatingSettings.tokenRateFullScale}
            liveRateEnabled={liveRateEnabled}
            snapshot={snapshot}
            onFullScaleChange={onTokenRateFullScaleChange}
          />
          <p className="live-rate-note">
            官方为减少磁盘写入关闭了部分流式日志，因此这里显示的是估算速率，主要用于判断 Codex 是否正在工作，不代表真实 tok/s。
          </p>
        </div>

        <div className="settings-panel settings-panel--quick" aria-label="快捷显示设置">
          <div className="quick-surface-header">
            <div className="quick-surface-heading">
              <strong>显示面</strong>
              <span>可独立开启，也可同时显示</span>
            </div>
            <button className="quick-settings-button" onClick={onOpenSettings} type="button">
              总体设置 <span aria-hidden="true">›</span>
            </button>
          </div>
          <div className="quick-surface-actions" role="group" aria-label="显示面开关">
            <button
              aria-pressed={floatingEnabled}
              disabled={!platform.floatingWindow.available}
              onClick={onToggleFloating}
              title={platform.floatingWindow.note}
              type="button"
            >
              <span className="quick-surface-symbols" aria-hidden="true">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
                  <rect x="3" y="4" width="18" height="16" rx="3" /><path d="M3 9h18" /><rect x="11" y="12" width="7" height="5" rx="1" />
                </svg>
                <span className="quick-surface-switch" />
              </span>
              <span className="quick-surface-label">悬浮窗</span>
            </button>
            <button
              aria-pressed={quotaSidebarEnabled}
              disabled={!platform.floatingWindow.available}
              onClick={onToggleQuotaSidebar}
              title="独立额度侧栏：悬停查看额度，点击展开详情"
              type="button"
            >
              <span className="quick-surface-symbols" aria-hidden="true">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
                  <rect x="3" y="4" width="18" height="16" rx="3" /><path d="M15 4v16M18 8v3m0 3v2" />
                </svg>
                <span className="quick-surface-switch" />
              </span>
              <span className="quick-surface-label">额度侧栏</span>
            </button>
            <button
              aria-pressed={statusTrayLiveTextEnabled}
              aria-label="状态栏（实验）"
              disabled={!platform.statusTray.available || !platform.statusTrayLiveText.available}
              onClick={onToggleStatusTray}
              title={platform.statusTrayLiveText.note || platform.statusTray.note}
              type="button"
            >
              <span className="quick-surface-symbols" aria-hidden="true">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
                  <rect x="3" y="4" width="18" height="16" rx="3" /><path d="M3 9h18M13 6.5h1m3 0h1" />
                </svg>
                <span className="quick-surface-switch" />
              </span>
              <span className="quick-surface-label">状态栏<small>实验</small></span>
            </button>
          </div>
        </div>
      </div>
    </section>
  );
}
