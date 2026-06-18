import { useEffect, useMemo, useState } from "react";
import {
  readAccountQuota,
  readFloatingPanelSnapshot,
} from "../api/client";
import { emptyAccountQuotaBundle, emptyFloatingPanelSnapshot } from "../api/fallback";
import { desktopPlatform } from "../platform/desktop";
import type { AccountQuotaBundle, FloatingPanelSnapshot } from "../types/dashboard";
import { compactQuotaLabel } from "../utils/quota";

export function StatusPanelApp() {
  const [snapshot, setSnapshot] = useState<FloatingPanelSnapshot>(emptyFloatingPanelSnapshot);
  const [quota, setQuota] = useState<AccountQuotaBundle>(() => emptyAccountQuotaBundle());
  const [active, setActive] = useState(() => document.hasFocus());
  const quotaLabels = useMemo(() => ({
    fiveHour: compactQuotaLabel(quota.quota.fiveHour),
    sevenDay: compactQuotaLabel(quota.quota.sevenDay),
  }), [quota]);

  useEffect(() => {
    document.documentElement.classList.add("status-document");
    return () => document.documentElement.classList.remove("status-document");
  }, []);

  useEffect(() => {
    const hideWhenBlurred = () => {
      setActive(false);
      void desktopPlatform.hideStatusPanelWindow();
    };
    const markActive = () => setActive(true);
    window.addEventListener("focus", markActive);
    window.addEventListener("blur", hideWhenBlurred);
    return () => {
      window.removeEventListener("focus", markActive);
      window.removeEventListener("blur", hideWhenBlurred);
    };
  }, []);

  useEffect(() => {
    if (!active) {
      return;
    }

    let cancelled = false;
    let inFlight = false;

    async function refresh() {
      if (inFlight) {
        return;
      }

      inFlight = true;
      try {
        const next = await readFloatingPanelSnapshot();
        if (!cancelled) {
          setSnapshot(next);
        }
      } finally {
        inFlight = false;
      }
    }

    void refresh();
    const interval = window.setInterval(() => {
      void refresh();
    }, 750);

    return () => {
      cancelled = true;
      window.clearInterval(interval);
    };
  }, [active]);

  useEffect(() => {
    if (!active) {
      return;
    }

    let cancelled = false;
    let inFlight = false;

    async function refreshQuota() {
      if (inFlight) {
        return;
      }

      inFlight = true;
      try {
        const next = await readAccountQuota();
        if (!cancelled && next !== null) {
          setQuota(next);
        }
      } finally {
        inFlight = false;
      }
    }

    void refreshQuota();
    const interval = window.setInterval(() => {
      void refreshQuota();
    }, 180_000);

    return () => {
      cancelled = true;
      window.clearInterval(interval);
    };
  }, [active]);

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
          <i style={{ width: `${Math.min(100, Math.max(7, snapshot.tokensPerSecond / 2))}%` }} />
        </div>

        <div className="status-panel-status">
          <strong>{snapshot.trendLabel}</strong>
          <span>{snapshot.unread ? "有未读完成会话" : "暂无未读完成会话"}</span>
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
