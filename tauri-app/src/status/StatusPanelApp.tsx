import { useEffect, useState } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { readAppSettings } from "../api/client";
import {
  DEFAULT_FLOATING_SETTINGS,
  sanitizeFloatingSettings,
} from "../floating/floatingSettings";
import { desktopPlatform } from "../platform/desktop";
import { useCompactPanelData } from "../surfaces/useCompactPanelData";
import type { FloatingWindowSettings } from "../types/dashboard";

function statusRateFillPercent(tokensPerSecond: number, fullScale: number): number {
  if (!Number.isFinite(tokensPerSecond) || tokensPerSecond <= 0) {
    return 0;
  }
  const scaleLimit = Number.isFinite(fullScale) && fullScale > 0 ? fullScale : DEFAULT_FLOATING_SETTINGS.tokenRateFullScale;
  return Math.min(100, Math.max(7, (tokensPerSecond / scaleLimit) * 100));
}

export function StatusPanelApp() {
  const [active, setActive] = useState(false);
  const [settings, setSettings] = useState<FloatingWindowSettings>(DEFAULT_FLOATING_SETTINGS);
  const { snapshot, quotaLabels } = useCompactPanelData({
    active,
    snapshotIntervalMs: 750,
    quotaInitialDelayMs: 0,
    quotaIntervalMs: 180_000,
  });

  useEffect(() => {
    document.documentElement.classList.add("status-document");
    return () => document.documentElement.classList.remove("status-document");
  }, []);

  useEffect(() => {
    let disposed = false;
    let unsubscribe: (() => void) | null = null;

    void desktopPlatform.onFloatingSettingsChanged((payload) => {
      setSettings(sanitizeFloatingSettings(payload));
    }).then((handler) => {
      if (disposed) {
        handler();
        return;
      }
      unsubscribe = handler;
    });

    void readAppSettings().then((snapshot) => {
      if (snapshot?.floatingWindow) {
        setSettings(sanitizeFloatingSettings(snapshot.floatingWindow));
      }
    });

    return () => {
      disposed = true;
      unsubscribe?.();
    };
  }, []);

  useEffect(() => {
    const appWindow = getCurrentWindow();
    let cancelled = false;

    async function refreshActiveState() {
      try {
        const visible = await appWindow.isVisible();
        if (!cancelled) {
          setActive(Boolean(visible) && document.hasFocus());
        }
      } catch {
        if (!cancelled) {
          setActive(document.hasFocus());
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

  return (
    <main className="status-window-shell">
      <section className="status-panel-card" aria-label="状态栏速率详情">
        <header className="status-panel-head">
          <div>
            <span>Codex Token Bar</span>
            <strong>{snapshot.tokensPerSecond.toFixed(1)}</strong>
          </div>
          <div className="status-panel-rate-unit">
            <em>tok/s</em>
            <button type="button" aria-label="关闭状态栏详情" onClick={closePanel}>×</button>
          </div>
        </header>

        <div className="status-panel-meter" aria-hidden="true">
          <i style={{ width: `${statusRateFillPercent(snapshot.tokensPerSecond, settings.tokenRateFullScale)}%` }} />
        </div>

        <div className="status-panel-status">
          <strong>{snapshot.trendLabel}</strong>
          <span title={snapshot.unreadSummary.detail}>{snapshot.unreadSummary.label}</span>
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

        <div className="status-panel-quota">
          <span>{quotaLabels.fiveHour}</span>
          <span>{quotaLabels.sevenDay}</span>
        </div>

        <footer className="status-panel-actions">
          <button type="button" onClick={openDashboard}>打开主界面</button>
          <button type="button" onClick={closePanel}>收起</button>
        </footer>
      </section>
    </main>
  );
}
