import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
} from "react";
import { readAppSettings } from "../api/client";
import { formatLiveRateValue, rateFillStyle } from "../components/liveRate/rateDisplay";
import {
  DEFAULT_FLOATING_SETTINGS,
  sanitizeFloatingSettings,
} from "../floating/floatingSettings";
import { floatingStandaloneStatusText } from "../floating/floatingPanelLabels";
import {
  FloatingCrowdRadarRow,
  FloatingRadarRow,
  floatingQuotaFillBackground,
} from "../floating/FloatingPanelPreview";
import { useFloatingCrowdRadar, useFloatingRadar } from "../floating/useFloatingRadar";
import { desktopPlatform } from "../platform/desktop";
import {
  DEFAULT_DISPLAY_SURFACES,
  sanitizeDisplaySurfaces,
} from "../settings/displaySettings";
import { DEFAULT_QUOTA_REFRESH_INTERVAL_MS, sanitizeQuotaRefreshIntervalMs } from "../settings/quotaRefreshCadence";
import { useCompactPanelData } from "../surfaces/useCompactPanelData";
import { useCompactPanelSource } from "../surfaces/useCompactPanelSource";
import type {
  DisplaySurfaceSettings,
  FloatingPanelSnapshot,
  FloatingWindowSettings,
  StatusSummarySectionId,
} from "../types/dashboard";
import { compactQuotaResetText } from "../utils/quota";
import {
  buildStatusIndicatorPresentation,
  buildStatusMetricStates,
  statusSnapshotForQuotaDiagnostics,
} from "./statusIndicatorPresentation";
import { attemptStatusIndicatorReadoutPublish } from "./statusIndicatorPublisher";
import {
  buildStatusPanelDataInterests,
  statusPanelBackgroundActive,
  statusPanelSummaryVisible,
} from "./statusPanelDataInterests";
import { StatusPanelCompactIndicator } from "./StatusPanelCompactIndicator";
import { latestTrustedStatusUpdate } from "./statusSummaryUpdatedAt";
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
  const [quotaRefreshIntervalMs, setQuotaRefreshIntervalMs] = useState(DEFAULT_QUOTA_REFRESH_INTERVAL_MS);
  const floatingSettingsGenerationRef = useRef(0);
  const displaySettingsGenerationRef = useRef(0);
  const appSettingsGenerationRef = useRef(0);
  const { sourceReady, sourceToken } = useCompactPanelSource(active);
  const radarSnapshot = useFloatingRadar(
    active && sourceReady && dataInterests.radar,
  );
  const crowdRadarSnapshot = useFloatingCrowdRadar(
    active && sourceReady && dataInterests.crowdRadar,
    { clearOnError: true },
  );
  const lastPublishedReadoutRef = useRef("");
  const [publishRetryNonce, setPublishRetryNonce] = useState(0);
  const { quota, runningThreads, snapshot } = useCompactPanelData({
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
    let disposed = false;
    let unsubscribe: (() => void) | null = null;
    let unsubscribeDisplay: (() => void) | null = null;
    let unsubscribeAppSettings: (() => void) | null = null;

    void desktopPlatform.onFloatingSettingsChanged((payload) => {
      floatingSettingsGenerationRef.current += 1;
      setSettings(sanitizeFloatingSettings(payload));
    }).then((handler) => {
      if (disposed) {
        handler();
        return;
      }
      unsubscribe = handler;
    });

    void desktopPlatform.onDisplaySurfacesChanged((payload) => {
      displaySettingsGenerationRef.current += 1;
      setDisplaySurfaces(sanitizeDisplaySurfaces(payload));
    }).then((handler) => {
      if (disposed) {
        handler();
        return;
      }
      unsubscribeDisplay = handler;
    });

    void desktopPlatform.onAppSettingsChanged((payload) => {
      floatingSettingsGenerationRef.current += 1;
      displaySettingsGenerationRef.current += 1;
      appSettingsGenerationRef.current += 1;
      setSettings(sanitizeFloatingSettings(payload.floatingWindow));
      setDisplaySurfaces(sanitizeDisplaySurfaces(payload.displaySurfaces));
      setQuotaRefreshIntervalMs(sanitizeQuotaRefreshIntervalMs(payload.quotaRefreshIntervalMs));
    }).then((handler) => {
      if (disposed) {
        handler();
        return;
      }
      unsubscribeAppSettings = handler;
    });

    const startingFloatingSettingsGeneration = floatingSettingsGenerationRef.current;
    const startingDisplaySettingsGeneration = displaySettingsGenerationRef.current;
    const startingAppSettingsGeneration = appSettingsGenerationRef.current;
    void readAppSettings().then((snapshot) => {
      if (
        snapshot?.floatingWindow
        && startingFloatingSettingsGeneration === 0
        && floatingSettingsGenerationRef.current === 0
      ) {
        setSettings(sanitizeFloatingSettings(snapshot.floatingWindow));
      }
      if (
        snapshot?.displaySurfaces
        && startingDisplaySettingsGeneration === 0
        && displaySettingsGenerationRef.current === 0
      ) {
        setDisplaySurfaces(sanitizeDisplaySurfaces(snapshot.displaySurfaces));
      }
      if (startingAppSettingsGeneration === 0 && appSettingsGenerationRef.current === 0) {
        setQuotaRefreshIntervalMs(sanitizeQuotaRefreshIntervalMs(snapshot?.quotaRefreshIntervalMs));
      }
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

  const statusQuotaSnapshot = statusSnapshotForQuotaDiagnostics(snapshot, quota.diagnostics);
  const displaySnapshot = {
    ...statusQuotaSnapshot,
    unread: statusQuotaSnapshot.unreadSummary.active,
    unreadSummary: statusQuotaSnapshot.unreadSummary,
  };
  const summaryUpdatedAt = latestTrustedStatusUpdate(quota, runningThreads);
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
    crowdRadar: crowdRadarSnapshot,
    labelStyle: displaySurfaces.statusMetricLabelStyle,
    metricStates,
    order: displaySurfaces.statusMetricOrder,
    running: runningThreads,
    snapshot: displaySnapshot,
  }), [
    crowdRadarSnapshot,
    displaySnapshot,
    displaySurfaces.statusMetricLabelStyle,
    displaySurfaces.statusMetricOrder,
    metricStates,
    runningThreads,
  ]);

  useEffect(() => {
    let disposed = false;
    let retryTimer: number | null = null;
    const readout = displaySurfaces.statusTrayLiveTextEnabled
      ? indicatorPresentation
      : {
          columns: [],
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
    ...(displaySnapshot.fiveHourAvailability === "absent" ? [] : [{
      availability: displaySnapshot.fiveHourAvailability,
      label: displaySnapshot.fiveHourLabel,
      remainingPercent: displaySnapshot.fiveHourRemainingPercent,
      expectedRemainingPercent: displaySnapshot.fiveHourExpectedRemainingPercent,
      resetText: compactQuotaResetText(quota.quota.fiveHour),
    }]),
    {
      availability: displaySnapshot.sevenDayAvailability,
      label: displaySnapshot.sevenDayLabel,
      remainingPercent: displaySnapshot.sevenDayRemainingPercent,
      expectedRemainingPercent: displaySnapshot.sevenDayExpectedRemainingPercent,
      resetText: compactQuotaResetText(quota.quota.sevenDay),
    },
  ];

  function renderSummarySection(section: StatusSummarySectionId) {
    switch (section) {
      case "overview": {
        const rate = metricStates.rate;
        const measuredRate = rate.available ? displaySnapshot.tokensPerSecond : 0;
        return (
          <article className="status-summary-card status-summary-card--overview" key={section}>
            <header><span>关键概览</span></header>
            <div className="status-summary-overview-readout">
              <span>
                <strong>{rate.available ? formatLiveRateValue(measuredRate) : "—"}</strong>
                <em>tok/s</em>
              </span>
              <span className="status-summary-overview-meta">
                <b>{rate.available ? (floatingStandaloneStatusText(displaySnapshot) || "—") : "—"}</b>
                <small>更新 {summaryUpdatedAt ? formatStatusClock(summaryUpdatedAt) : "—"}</small>
              </span>
            </div>
            <div className="status-panel-meter" aria-hidden="true">
              <i
                className="rate-fill"
                style={rateFillStyle(measuredRate, settings.tokenRateFullScale)}
              />
            </div>
          </article>
        );
      }
      case "usage":
        return (
          <article className="status-summary-card" key={section}>
            <header><span>Token 用量</span></header>
            <dl className="status-summary-usage-tiles">
              <div><dt>累计 Token</dt><dd>{metricStates.total.value}</dd></div>
              <div><dt>今日 Token</dt><dd>{metricStates.today.value}</dd></div>
              <div><dt>今日请求</dt><dd>{metricStates.requests.value}</dd></div>
            </dl>
          </article>
        );
      case "quota":
        return (
          <article className="status-summary-card status-summary-card--wide" key={section}>
            <header><span>额度</span></header>
            <div className="status-panel-quota status-panel-quota--stacked" aria-label="账户额度">
              {statusQuotaWindows.map((window) => (
                <StatusPanelQuotaRow
                  availability={window.availability}
                  key={window.label}
                  label={window.label}
                  remainingPercent={window.remainingPercent}
                  resetText={window.resetText}
                  expectedRemainingPercent={window.expectedRemainingPercent}
                  settings={settings}
                />
              ))}
            </div>
          </article>
        );
      case "running":
        return (
          <article className="status-summary-card" key={section}>
            <header><span>运行线程</span></header>
            <p className="status-summary-running-line">
              <strong>{summaryNumber(runningThreads.total)}</strong><span>运行</span>
              <i>·</i><strong>{summaryNumber(runningThreads.mainThreads)}</strong><span>主任务</span>
              <i>·</i><strong>{summaryNumber(runningThreads.subagents)}</strong><span>子 Agent</span>
            </p>
          </article>
        );
      case "unread":
        return (
          <article className="status-summary-card" key={section}>
            <header><span>未读会话</span></header>
            <div className="status-summary-unread-line" title={displaySnapshot.unreadSummary.detail}>
              <strong>{metricStates.unread.value}</strong>
              <span>个未读</span>
            </div>
          </article>
        );
      case "radar":
        return (
          <article className="status-summary-card status-summary-card--wide" key={section}>
            <header><span>Codex 雷达</span></header>
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
        columns={indicatorPresentation.columns}
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
            <strong>Codex Token Bar</strong>
            <span title={indicatorPresentation.tooltip}>
              状态摘要 · {statusPanelHeaderText(displaySnapshot)}
            </span>
          </div>
          <em className="status-panel-arrangement">按设置编排</em>
        </header>

        <div
          aria-label="状态摘要内容"
          className="status-panel-summary-scroll"
          tabIndex={0}
        >
          <div className="status-panel-summary-grid">
            {displaySurfaces.statusSummaryOrder.map(renderSummarySection)}
            {displaySurfaces.statusSummaryOrder.length === 0 ? (
              <div className="status-panel-summary-empty">尚未选择摘要内容，可在“状态栏与托盘”设置中添加。</div>
            ) : null}
          </div>
        </div>

        <footer className="status-panel-actions">
          <button type="button" onClick={openDashboard}>主界面</button>
          <button type="button" onClick={openSettings}>设置</button>
          <button type="button" onClick={closePanel}>收起</button>
        </footer>
      </section>
    </main>
  );
}

function StatusPanelQuotaRow({
  availability,
  expectedRemainingPercent,
  label,
  remainingPercent,
  resetText,
  settings,
}: {
  availability: FloatingPanelSnapshot["fiveHourAvailability"];
  expectedRemainingPercent: number | null;
  label: string;
  remainingPercent: number | null;
  resetText: string;
  settings: FloatingWindowSettings;
}) {
  const measured = availability === "measured"
    && typeof remainingPercent === "number"
    && Number.isFinite(remainingPercent);
  const percent = measured
    ? Math.min(100, Math.max(0, remainingPercent * 100))
    : 0;
  const expectedPercent = typeof expectedRemainingPercent === "number"
    && Number.isFinite(expectedRemainingPercent)
    ? Math.min(100, Math.max(0, expectedRemainingPercent * 100))
    : null;
  const compactLabel = label.trim().split(/\s+/u)[0] || "额度";

  return (
    <div
      aria-label={measured ? `${compactLabel}，剩余 ${Math.round(percent)}%` : `${compactLabel}，额度待读取`}
      aria-valuemax={measured ? 100 : undefined}
      aria-valuemin={measured ? 0 : undefined}
      aria-valuenow={measured ? Math.round(percent) : undefined}
      className="status-panel-quota-row"
      role={measured ? "meter" : "status"}
    >
      <span>{compactLabel}</span>
      <i aria-hidden="true" className="status-panel-quota-track">
        <b
          style={{
            background: floatingQuotaFillBackground(settings, percent, expectedPercent),
            width: `${percent}%`,
          }}
        />
      </i>
      <strong>{measured ? `剩 ${Math.round(percent)}% · ${resetText || "—"}` : "—"}</strong>
    </div>
  );
}

function summaryNumber(value: number | null | undefined): string {
  return value === null || value === undefined || !Number.isFinite(value)
    ? "—"
    : String(Math.max(0, Math.round(value)));
}

function formatStatusClock(date: Date): string {
  return new Intl.DateTimeFormat("zh-CN", {
    hour: "2-digit",
    hour12: false,
    minute: "2-digit",
    second: "2-digit",
  }).format(date);
}

function statusPanelHeaderText(
  snapshot: FloatingPanelSnapshot,
): string {
  if (snapshot.liveRateStatusKind === "failure") {
    return snapshot.liveRateStatusLabel?.trim() || "等待输出";
  }
  return snapshot.trendLabel.trim()
    || snapshot.liveRateStatusLabel?.trim()
    || "等待输出";
}
