import { useEffect, useLayoutEffect, useRef, useState, type CSSProperties } from "react";
import { acknowledgeUnreadSummary, readAppSettings } from "../api/client";
import { formatLiveRateValue, rateFillStyle } from "../components/liveRate/rateDisplay";
import {
  DEFAULT_FLOATING_SETTINGS,
  sanitizeFloatingSettings,
} from "../floating/floatingSettings";
import { floatingStandaloneStatusText } from "../floating/floatingPanelLabels";
import { FloatingQuotaBar, FloatingRadarRow } from "../floating/FloatingPanelPreview";
import { useFloatingRadar } from "../floating/useFloatingRadar";
import { desktopPlatform } from "../platform/desktop";
import { DEFAULT_QUOTA_REFRESH_INTERVAL_MS, sanitizeQuotaRefreshIntervalMs } from "../settings/quotaRefreshCadence";
import { useCompactPanelData } from "../surfaces/useCompactPanelData";
import {
  sameCodexHomeSourceToken,
  useCompactPanelSource,
} from "../surfaces/useCompactPanelSource";
import type {
  CodexHomeSourceToken,
  FloatingWindowSettings,
  UnreadSummary,
} from "../types/dashboard";
import { useStatusPanelWindowLifecycle } from "./useStatusPanelWindowLifecycle";

export function StatusPanelApp() {
  const active = useStatusPanelWindowLifecycle();
  const [liveRateEnabled, setLiveRateEnabled] = useState(true);
  const [settings, setSettings] = useState<FloatingWindowSettings>(DEFAULT_FLOATING_SETTINGS);
  const [acknowledgedUnreadSummary, setAcknowledgedUnreadSummary] = useState<UnreadSummary | null>(null);
  const [quotaRefreshIntervalMs, setQuotaRefreshIntervalMs] = useState(DEFAULT_QUOTA_REFRESH_INTERVAL_MS);
  const { sourceReady, sourceToken } = useCompactPanelSource(active);
  const radarSnapshot = useFloatingRadar(active && sourceReady);
  const sourceTokenRef = useRef<CodexHomeSourceToken | null>(sourceToken);
  const { snapshot } = useCompactPanelData({
    active: active && sourceReady,
    liveRateEnabled,
    liveRateOwnerToken: "status-live-rate",
    quotaInitialDelayMs: 0,
    quotaIntervalMs: quotaRefreshIntervalMs,
    sourceToken,
  });

  useLayoutEffect(() => {
    sourceTokenRef.current = sourceToken;
    setAcknowledgedUnreadSummary(null);
  }, [sourceToken]);

  useEffect(() => {
    document.documentElement.classList.add("status-document");
    return () => document.documentElement.classList.remove("status-document");
  }, []);

  useEffect(() => {
    if (!snapshot.unreadSummary.active) {
      setAcknowledgedUnreadSummary(null);
    }
  }, [snapshot.unreadSummary.active, snapshot.unreadSummary.count, snapshot.unreadSummary.source]);

  useEffect(() => {
    let disposed = false;
    let unsubscribe: (() => void) | null = null;
    let unsubscribeDisplay: (() => void) | null = null;
    let unsubscribeAppSettings: (() => void) | null = null;

    void desktopPlatform.onFloatingSettingsChanged((payload) => {
      setSettings(sanitizeFloatingSettings(payload));
    }).then((handler) => {
      if (disposed) {
        handler();
        return;
      }
      unsubscribe = handler;
    });

    void desktopPlatform.onDisplaySurfacesChanged((payload) => {
      setLiveRateEnabled(payload.liveRateEnabled);
    }).then((handler) => {
      if (disposed) {
        handler();
        return;
      }
      unsubscribeDisplay = handler;
    });

    void desktopPlatform.onAppSettingsChanged((payload) => {
      setQuotaRefreshIntervalMs(sanitizeQuotaRefreshIntervalMs(payload.quotaRefreshIntervalMs));
    }).then((handler) => {
      if (disposed) {
        handler();
        return;
      }
      unsubscribeAppSettings = handler;
    });

    void readAppSettings().then((snapshot) => {
      if (snapshot?.floatingWindow) {
        setSettings(sanitizeFloatingSettings(snapshot.floatingWindow));
      }
      if (snapshot?.displaySurfaces) {
        setLiveRateEnabled(snapshot.displaySurfaces.liveRateEnabled);
      }
      setQuotaRefreshIntervalMs(sanitizeQuotaRefreshIntervalMs(snapshot?.quotaRefreshIntervalMs));
    });

    return () => {
      disposed = true;
      unsubscribe?.();
      unsubscribeDisplay?.();
      unsubscribeAppSettings?.();
    };
  }, []);

  useEffect(() => {
    if (sourceToken === null) {
      return;
    }
    let disposed = false;
    let unlisten: (() => void) | null = null;
    void desktopPlatform.onUnreadSummaryChanged((payload) => {
      if (!disposed && sameCodexHomeSourceToken(sourceTokenRef.current, payload.sourceToken)) {
        setAcknowledgedUnreadSummary(payload.summary);
      }
    }).then((handler) => {
      if (disposed) {
        handler();
      } else {
        unlisten = handler;
      }
    });

    return () => {
      disposed = true;
      unlisten?.();
    };
  }, [sourceToken]);

  function openDashboard() {
    void desktopPlatform.showDashboardWindow();
    void desktopPlatform.hideStatusPanelWindow();
  }

  function openSettings() {
    window.localStorage.setItem("open-app-settings-requested", "1");
    void desktopPlatform.showDashboardWindow().then(() => {
      void desktopPlatform.publishOpenAppSettings();
    });
    void desktopPlatform.hideStatusPanelWindow();
  }

  function closePanel() {
    void desktopPlatform.hideStatusPanelWindow();
  }

  function acknowledgeUnread() {
    const acknowledgedSourceToken = sourceTokenRef.current;
    if (acknowledgedSourceToken === null) {
      return;
    }
    void acknowledgeUnreadSummary(acknowledgedSourceToken).then((summary) => {
      if (
        summary === null
        || !sameCodexHomeSourceToken(sourceTokenRef.current, acknowledgedSourceToken)
      ) {
        return;
      }
      setAcknowledgedUnreadSummary(summary);
      void desktopPlatform.publishUnreadSummaryChanged({
        sourceToken: acknowledgedSourceToken,
        summary,
      });
    });
  }

  const displayUnreadSummary = acknowledgedUnreadSummary ?? snapshot.unreadSummary;
  const displaySnapshot = {
    ...snapshot,
    unread: displayUnreadSummary.active,
    unreadSummary: displayUnreadSummary,
  };
  const statusQuotaWindows = [
    {
      availability: displaySnapshot.fiveHourAvailability,
      label: displaySnapshot.fiveHourLabel,
      remainingPercent: displaySnapshot.fiveHourRemainingPercent,
      expectedRemainingPercent: displaySnapshot.fiveHourExpectedRemainingPercent,
    },
    {
      availability: displaySnapshot.sevenDayAvailability,
      label: displaySnapshot.sevenDayLabel,
      remainingPercent: displaySnapshot.sevenDayRemainingPercent,
      expectedRemainingPercent: displaySnapshot.sevenDayExpectedRemainingPercent,
    },
  ].filter((window) => window.availability !== "absent");

  return (
    <main className="status-window-shell">
      <section
        className="status-panel-card"
        aria-label="状态栏速率详情"
        style={{
          "--floating-scale": 1,
          "--floating-primary": "var(--text)",
          "--floating-secondary": "color-mix(in srgb, var(--text) 80%, var(--muted))",
          "--floating-muted": "var(--muted)",
          "--floating-divider": "var(--line)",
        } as CSSProperties}
      >
        <header className="status-panel-head">
          <div>
            <span>Codex Token Bar</span>
            <strong>{formatLiveRateValue(displaySnapshot.tokensPerSecond)}</strong>
          </div>
          <div className="status-panel-rate-unit">
            <em>tok/s</em>
            <button type="button" aria-label="关闭状态栏详情" onClick={closePanel}>×</button>
          </div>
        </header>

        <div className="status-panel-meter" aria-hidden="true">
          <i className="rate-fill" style={rateFillStyle(displaySnapshot.tokensPerSecond, settings.tokenRateFullScale)} />
        </div>

        <div className="status-panel-status">
          <strong>{floatingStandaloneStatusText(displaySnapshot)}</strong>
          <span title={displaySnapshot.unreadSummary.detail}>{displaySnapshot.unreadSummary.label}</span>
        </div>

        <dl className="status-panel-stats">
          <div>
            <dt>总量</dt>
            <dd>{snapshot.totalTokensLabel.replace(/^总\s*/, "")}</dd>
          </div>
          <div>
            <dt>今日</dt>
            <dd>{snapshot.todayTokensLabel.replace(/^今\s*/, "")}</dd>
          </div>
          <div>
            <dt>请求</dt>
            <dd>{snapshot.requestsLabel.replace(/^次\s*/, "")}</dd>
          </div>
        </dl>

        <div className="status-panel-quota" aria-label="账户额度">
          {statusQuotaWindows.map((window) => (
            <FloatingQuotaBar
              availability={window.availability}
              key={window.label}
              label={window.label}
              remainingPercent={window.remainingPercent}
              expectedRemainingPercent={window.expectedRemainingPercent}
              settings={settings}
            />
          ))}
          {statusQuotaWindows.length === 0 ? <span className="status-panel-quota-empty">额度待读取</span> : null}
        </div>

        <FloatingRadarRow snapshot={radarSnapshot} style={{}} />

        <footer className="status-panel-actions">
          <button type="button" onClick={openDashboard}>打开主界面</button>
          <button type="button" onClick={openSettings}>设置</button>
          {displaySnapshot.unreadSummary.active ? (
            <button type="button" onClick={acknowledgeUnread}>标记已读</button>
          ) : null}
          <button type="button" onClick={closePanel}>收起</button>
        </footer>
      </section>
    </main>
  );
}
