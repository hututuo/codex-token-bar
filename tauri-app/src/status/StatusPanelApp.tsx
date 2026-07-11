import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { acknowledgeUnreadSummary, readAppSettings } from "../api/client";
import { formatLiveRateValue, rateFillStyle } from "../components/liveRate/rateDisplay";
import {
  DEFAULT_FLOATING_SETTINGS,
  sanitizeFloatingSettings,
} from "../floating/floatingSettings";
import { floatingStandaloneStatusText } from "../floating/floatingPanelLabels";
import { desktopPlatform } from "../platform/desktop";
import { DEFAULT_QUOTA_REFRESH_INTERVAL_MS, sanitizeQuotaRefreshIntervalMs } from "../settings/quotaRefreshCadence";
import { useCompactPanelData } from "../surfaces/useCompactPanelData";
import {
  sameCodexHomeSourceToken,
  useCompactPanelSource,
} from "../surfaces/useCompactPanelSource";
import { statusPanelIsActive } from "../surfaces/surfaceLifecycle";
import type {
  CodexHomeSourceToken,
  FloatingWindowSettings,
  UnreadSummary,
} from "../types/dashboard";
import { StatusQuotaProjection } from "./StatusQuotaProjection";

export function StatusPanelApp() {
  const [active, setActive] = useState(false);
  const [liveRateEnabled, setLiveRateEnabled] = useState(true);
  const [settings, setSettings] = useState<FloatingWindowSettings>(DEFAULT_FLOATING_SETTINGS);
  const [acknowledgedUnreadSummary, setAcknowledgedUnreadSummary] = useState<UnreadSummary | null>(null);
  const [quotaRefreshIntervalMs, setQuotaRefreshIntervalMs] = useState(DEFAULT_QUOTA_REFRESH_INTERVAL_MS);
  const { sourceReady, sourceToken } = useCompactPanelSource(active);
  const sourceTokenRef = useRef<CodexHomeSourceToken | null>(sourceToken);
  const { snapshot, quota } = useCompactPanelData({
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

  useEffect(() => {
    const appWindow = getCurrentWindow();
    let cancelled = false;

    async function refreshActiveState() {
      try {
        const visible = await appWindow.isVisible();
        if (!cancelled) {
          setActive(statusPanelIsActive(Boolean(visible), document.hasFocus()));
        }
      } catch {
        if (!cancelled) {
          setActive(statusPanelIsActive(true, document.hasFocus()));
        }
      }
    }

    const hideWhenBlurred = () => {
      setActive(false);
      void desktopPlatform.hideStatusPanelWindow();
    };
    const markActive = () => {
      void refreshActiveState();
    };
    window.addEventListener("focus", markActive);
    window.addEventListener("blur", hideWhenBlurred);
    void refreshActiveState();
    return () => {
      cancelled = true;
      window.removeEventListener("focus", markActive);
      window.removeEventListener("blur", hideWhenBlurred);
    };
  }, []);

  function openDashboard() {
    void desktopPlatform.showDashboardWindow();
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

  return (
    <main className="status-window-shell">
      <section className="status-panel-card" aria-label="状态栏速率详情">
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

        <StatusQuotaProjection
          fiveHour={quota.quota.fiveHour}
          sevenDay={quota.quota.sevenDay}
        />

        <footer className="status-panel-actions">
          <button type="button" onClick={openDashboard}>打开主界面</button>
          {displaySnapshot.unreadSummary.active ? (
            <button type="button" onClick={acknowledgeUnread}>标记已读</button>
          ) : null}
          <button type="button" onClick={closePanel}>收起</button>
        </footer>
      </section>
    </main>
  );
}
