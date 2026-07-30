import {
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
} from "react";
import { acknowledgeUnreadSummary, readAppSettings } from "../api/client";
import { formatLiveRateValue, rateFillStyle } from "../components/liveRate/rateDisplay";
import {
  DEFAULT_FLOATING_SETTINGS,
  sanitizeFloatingSettings,
} from "../floating/floatingSettings";
import { floatingStandaloneStatusText } from "../floating/floatingPanelLabels";
import {
  FloatingCrowdRadarRow,
  FloatingQuotaBar,
  FloatingRadarRow,
} from "../floating/FloatingPanelPreview";
import { useFloatingCrowdRadar, useFloatingRadar } from "../floating/useFloatingRadar";
import { desktopPlatform } from "../platform/desktop";
import {
  DEFAULT_DISPLAY_SURFACES,
  sanitizeDisplaySurfaces,
} from "../settings/displaySettings";
import { DEFAULT_QUOTA_REFRESH_INTERVAL_MS, sanitizeQuotaRefreshIntervalMs } from "../settings/quotaRefreshCadence";
import { useCompactPanelData } from "../surfaces/useCompactPanelData";
import {
  sameCodexHomeSourceToken,
  useCompactPanelSource,
} from "../surfaces/useCompactPanelSource";
import type {
  CodexHomeSourceToken,
  DisplaySurfaceSettings,
  FloatingWindowSettings,
  StatusSummarySectionId,
  UnreadSummary,
} from "../types/dashboard";
import {
  buildStatusIndicatorPresentation,
  buildStatusMetricStates,
} from "./statusIndicatorPresentation";
import { attemptStatusIndicatorReadoutPublish } from "./statusIndicatorPublisher";
import {
  buildStatusPanelDataInterests,
  statusPanelBackgroundActive,
  statusPanelSummaryVisible,
} from "./statusPanelDataInterests";
import { StatusPanelCompactIndicator } from "./StatusPanelCompactIndicator";
import { useStatusPanelWindowLifecycleState } from "./useStatusPanelWindowLifecycle";

export function StatusPanelApp() {
  const [displaySurfaces, setDisplaySurfaces] = useState<DisplaySurfaceSettings>(
    DEFAULT_DISPLAY_SURFACES,
  );
  const backgroundActive = statusPanelBackgroundActive(
    displaySurfaces.statusTrayLiveTextEnabled,
    displaySurfaces.statusMetricOrder,
  );
  const lifecycle = useStatusPanelWindowLifecycleState(backgroundActive);
  const active = lifecycle.active;
  const [compact, setCompact] = useState(() => window.innerHeight <= 80);
  const summaryVisible = statusPanelSummaryVisible(lifecycle.visible, compact);
  const dataInterests = useMemo(() => buildStatusPanelDataInterests({
    liveRateEnabled: displaySurfaces.liveRateEnabled,
    metricOrder: displaySurfaces.statusMetricOrder,
    panelVisible: summaryVisible,
    statusMetricsEnabled: displaySurfaces.statusTrayLiveTextEnabled,
    summaryOrder: displaySurfaces.statusSummaryOrder,
  }), [
    displaySurfaces.liveRateEnabled,
    displaySurfaces.statusMetricOrder,
    displaySurfaces.statusSummaryOrder,
    displaySurfaces.statusTrayLiveTextEnabled,
    summaryVisible,
  ]);
  const [settings, setSettings] = useState<FloatingWindowSettings>(DEFAULT_FLOATING_SETTINGS);
  const [acknowledgedUnreadSummary, setAcknowledgedUnreadSummary] = useState<UnreadSummary | null>(null);
  const [quotaRefreshIntervalMs, setQuotaRefreshIntervalMs] = useState(DEFAULT_QUOTA_REFRESH_INTERVAL_MS);
  const { sourceReady, sourceToken } = useCompactPanelSource(active);
  const radarSnapshot = useFloatingRadar(
    active && sourceReady && dataInterests.radar,
  );
  const crowdRadarSnapshot = useFloatingCrowdRadar(
    active && sourceReady && dataInterests.crowdRadar,
  );
  const sourceTokenRef = useRef<CodexHomeSourceToken | null>(sourceToken);
  const lastPublishedReadoutRef = useRef("");
  const [publishRetryNonce, setPublishRetryNonce] = useState(0);
  const { runningThreads, snapshot } = useCompactPanelData({
    active: active && sourceReady,
    liveRateEnabled: dataInterests.liveRate,
    liveRateOwnerToken: "status-live-rate",
    quotaEnabled: dataInterests.quota,
    quotaInitialDelayMs: 0,
    quotaIntervalMs: quotaRefreshIntervalMs,
    runningEnabled: dataInterests.running,
    snapshotEnabled: dataInterests.snapshot,
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
    const updateCompactMode = () => setCompact(window.innerHeight <= 80);
    window.addEventListener("resize", updateCompactMode);
    updateCompactMode();
    return () => window.removeEventListener("resize", updateCompactMode);
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
      setDisplaySurfaces(sanitizeDisplaySurfaces(payload));
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
        setDisplaySurfaces(sanitizeDisplaySurfaces(snapshot.displaySurfaces));
      }
      setQuotaRefreshIntervalMs(sanitizeQuotaRefreshIntervalMs(snapshot?.quotaRefreshIntervalMs));
    }).catch(() => {
      // 保持默认展示设置；失败已由命令诊断链路记录。
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
    window.localStorage.setItem("open-app-settings-requested", "status");
    void desktopPlatform.showDashboardWindow().then(() => {
      void desktopPlatform.publishOpenAppSettings();
    });
    void desktopPlatform.hideStatusPanelWindow();
  }

  function closePanel() {
    void desktopPlatform.hideStatusPanelWindow();
  }

  function expandPanel() {
    void desktopPlatform.showStatusPanelWindow();
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
  const metricStates = useMemo(() => buildStatusMetricStates({
    liveRateEnabled: displaySurfaces.liveRateEnabled,
    snapshot: displaySnapshot,
    sourceReady,
  }), [
    displaySnapshot,
    displaySurfaces.liveRateEnabled,
    sourceReady,
  ]);
  const indicatorPresentation = useMemo(() => buildStatusIndicatorPresentation({
    labelStyle: displaySurfaces.statusMetricLabelStyle,
    metricStates,
    order: displaySurfaces.statusMetricOrder,
    radar: radarSnapshot,
    running: runningThreads,
    snapshot: displaySnapshot,
  }), [
    displaySnapshot,
    displaySurfaces.statusMetricLabelStyle,
    displaySurfaces.statusMetricOrder,
    metricStates,
    radarSnapshot,
    runningThreads,
  ]);

  useEffect(() => {
    let disposed = false;
    let retryTimer: number | null = null;
    const readout = displaySurfaces.statusTrayLiveTextEnabled
      ? indicatorPresentation
      : {
          title: "",
          tooltip: "Codex Token Bar",
          width: 0,
        };
    void attemptStatusIndicatorReadoutPublish(
      readout,
      lastPublishedReadoutRef.current,
      desktopPlatform.publishStatusIndicatorReadout,
    ).then((attempt) => {
      if (disposed) {
        return;
      }
      lastPublishedReadoutRef.current = attempt.committedSignature;
      if (attempt.shouldRetry) {
        retryTimer = window.setTimeout(() => {
          setPublishRetryNonce((value) => value + 1);
        }, 1_000);
      }
    });

    return () => {
      disposed = true;
      if (retryTimer !== null) {
        window.clearTimeout(retryTimer);
      }
    };
  }, [
    displaySurfaces.statusTrayLiveTextEnabled,
    indicatorPresentation,
    publishRetryNonce,
  ]);

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

  function renderSummarySection(section: StatusSummarySectionId) {
    switch (section) {
      case "overview": {
        const rate = metricStates.rate;
        const measuredRate = rate.available ? displaySnapshot.tokensPerSecond : 0;
        return (
          <article className="status-summary-card status-summary-card--overview" key={section}>
            <header>
              <span>实时速度</span>
              <strong>
                {rate.available ? `${formatLiveRateValue(measuredRate)} tok/s` : "—"}
              </strong>
            </header>
            <div className="status-panel-meter" aria-hidden="true">
              <i
                className="rate-fill"
                style={rateFillStyle(measuredRate, settings.tokenRateFullScale)}
              />
            </div>
            <p>{rate.available ? (floatingStandaloneStatusText(displaySnapshot) || "—") : "—"}</p>
          </article>
        );
      }
      case "usage":
        return (
          <article className="status-summary-card" key={section}>
            <header><span>用量统计</span></header>
            <dl className="status-summary-metrics status-summary-metrics--three">
              <div><dt>今日</dt><dd>{metricStates.today.value}</dd></div>
              <div><dt>累计</dt><dd>{metricStates.total.value}</dd></div>
              <div><dt>请求</dt><dd>{metricStates.requests.value}</dd></div>
            </dl>
          </article>
        );
      case "quota":
        return (
          <article className="status-summary-card status-summary-card--wide" key={section}>
            <header><span>账户额度</span></header>
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
              {statusQuotaWindows.length === 0 ? <span className="status-panel-quota-empty">—</span> : null}
            </div>
          </article>
        );
      case "running":
        return (
          <article className="status-summary-card" key={section}>
            <header><span>运行任务</span><strong>{summaryNumber(runningThreads.total)}</strong></header>
            <dl className="status-summary-metrics">
              <div><dt>主任务</dt><dd>{summaryNumber(runningThreads.mainThreads)}</dd></div>
              <div><dt>子 Agent</dt><dd>{summaryNumber(runningThreads.subagents)}</dd></div>
            </dl>
          </article>
        );
      case "unread":
        return (
          <article className="status-summary-card" key={section}>
            <header><span>未读会话</span><strong>{metricStates.unread.value}</strong></header>
            <p title={displaySnapshot.unreadSummary.detail}>
              {metricStates.unread.available
                ? (displaySnapshot.unreadSummary.label || "—")
                : "—"}
            </p>
            {metricStates.unread.available && displaySnapshot.unreadSummary.active ? (
              <button className="status-summary-inline-action" onClick={acknowledgeUnread} type="button">
                标记已读
              </button>
            ) : null}
          </article>
        );
      case "radar":
        return (
          <article className="status-summary-card status-summary-card--wide" key={section}>
            <header><span>雷达</span></header>
            <FloatingRadarRow snapshot={radarSnapshot} style={{}} />
          </article>
        );
      case "crowdRadar":
        return (
          <article className="status-summary-card status-summary-card--wide" key={section}>
            <header><span>众测雷达</span></header>
            <FloatingCrowdRadarRow snapshot={crowdRadarSnapshot} style={{}} />
          </article>
        );
    }
  }

  if (compact) {
    return (
      <StatusPanelCompactIndicator
        items={indicatorPresentation.visibleItems}
        onExpand={expandPanel}
        tooltip={indicatorPresentation.tooltip}
      />
    );
  }

  return (
    <main className="status-window-shell">
      <section
        className="status-panel-card status-panel-card--expanded"
        aria-label="状态栏可编排摘要"
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
            <span>Codex Token Bar · 状态摘要</span>
            <strong title={indicatorPresentation.tooltip}>
              {indicatorPresentation.title || "已启用图标入口"}
            </strong>
          </div>
          <div className="status-panel-rate-unit">
            <button type="button" aria-label="关闭状态栏详情" onClick={closePanel}>×</button>
          </div>
        </header>

        <div className="status-panel-summary-scroll">
          <div className="status-panel-summary-grid">
            {displaySurfaces.statusSummaryOrder.map(renderSummarySection)}
            {displaySurfaces.statusSummaryOrder.length === 0 ? (
              <div className="status-panel-summary-empty">尚未选择摘要内容，可在“状态栏与托盘”设置中添加。</div>
            ) : null}
          </div>
        </div>

        <footer className="status-panel-actions">
          <button type="button" onClick={openDashboard}>打开主界面</button>
          <button type="button" onClick={openSettings}>设置</button>
          <button type="button" onClick={closePanel}>收起</button>
        </footer>
      </section>
    </main>
  );
}

function summaryNumber(value: number | null | undefined): string {
  return value === null || value === undefined || !Number.isFinite(value)
    ? "—"
    : String(Math.max(0, Math.round(value)));
}
