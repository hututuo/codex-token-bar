import { DiagnosticNotice } from "./DiagnosticNotice";
import type {
  AccountInfo,
  AutostartStatus,
  CodexHomeStatus,
  PreciseDashboardProgress,
  RunningThreadSummary,
} from "../types/dashboard";
import { CodexHomeEditor } from "./dashboardHeader/CodexHomeEditor";
import {
  PRECISE_PROGRESS_REASSURANCE,
  presentDashboardHeaderProgress,
} from "./dashboardHeader/progress";
import { useEffect, useId, useRef, useState, type ReactNode } from "react";
import type { ThreadDeleteBridgeStatus } from "../api/threadDeleteClient";
import type { AppSettingsCategory } from "./settings/AppSettingsDialog";
import type { DashboardLineageScalar } from "../types/usage";

interface DashboardHeaderProps {
  includesCodex?: boolean;
  scopeControl?: ReactNode;
  reportingStatus?: ReactNode;
  account: AccountInfo;
  autostartStatus: AutostartStatus;
  codexHome: CodexHomeStatus;
  customAccountDisplayName: string;
  generatedAt: string;
  usageSummaryUpdatedAt?: string | null;
  usageSummaryCheckedAt?: string | null;
  usageSummaryDataUpdatedAt?: string | null;
  /** Light-summary publication is independent from five-minute chart progress. */
  usageSummaryFresh?: boolean;
  /** Full five-minute/model snapshot freshness; required before the header may look complete. */
  preciseDataFresh?: boolean;
  /** True while the native precise owner (Summary or Full) is in flight. */
  preciseRequestInFlight?: boolean;
  /** Source generation and the two existing aggregate generation receipts. */
  exactGeneration?: DashboardLineageScalar;
  aggregateExactGeneration?: DashboardLineageScalar;
  aggregatePublishedGeneration?: DashboardLineageScalar;
  aggregateCoveredAt?: string | null;
  onCodexHomeChange: (path: string) => Promise<void>;
  onCodexHomeReset: () => Promise<void>;
  onCustomAccountDisplayNameChange: (displayName: string) => Promise<void>;
  onCheckForUpdate: () => Promise<void>;
  onExportCsv: () => void;
  onExportPng: () => void;
  onOpenProviderRepair: () => void;
  onOpenSessionManagement: () => void;
  onOpenSettings: (category?: AppSettingsCategory) => void;
  onRefresh: () => Promise<void>;
  onToggleAutostart: () => void;
  refreshing: boolean;
  preciseProgress?: PreciseDashboardProgress | null;
  appUpdateState: {
    kind: "idle" | "checking" | "available" | "installing" | "error";
    message: string;
  };
  threadDeleteBridgeStatus: ThreadDeleteBridgeStatus;
  autoResumeEnabled: boolean;
  runningThreads?: RunningThreadSummary;
}

const PENDING_HEADER_RUNNING_THREADS: RunningThreadSummary = {
  total: null,
  mainThreads: null,
  subagents: null,
  mainModels: [],
  subagentModels: [],
  groups: [],
  unassignedSubagents: [],
  status: "scanning",
  updatedAt: null,
  detail: "正在读取当前数据源的会话生命周期",
  livenessLeaseHours: 24,
};

function lineageNumber(value: DashboardLineageScalar): bigint | null {
  if (typeof value === "number") {
    return Number.isSafeInteger(value) && value >= 0 ? BigInt(value) : null;
  }
  if (typeof value !== "string" || !/^\d+$/.test(value.trim())) return null;
  try {
    return BigInt(value.trim());
  } catch {
    return null;
  }
}

function generationIsAhead(
  source: DashboardLineageScalar,
  aggregateExact: DashboardLineageScalar,
  aggregatePublished: DashboardLineageScalar,
): boolean {
  const sourceValue = lineageNumber(source);
  if (sourceValue === null) return false;
  const exactValue = lineageNumber(aggregateExact);
  const publishedValue = lineageNumber(aggregatePublished);
  // A missing aggregate lineage is not evidence that a chart job is running.
  // It is an old/stale cache (or an incomplete snapshot) and must not be
  // presented as “图表同步中”. Only comparable, valid generations can prove
  // that a Full request is catching up.
  if (exactValue === null || publishedValue === null) return false;
  return sourceValue > exactValue || sourceValue > publishedValue;
}

export function DashboardHeader({
  includesCodex = true, scopeControl, reportingStatus,
  account,
  autostartStatus,
  codexHome,
  generatedAt,
  usageSummaryUpdatedAt = null,
  usageSummaryCheckedAt = null,
  usageSummaryDataUpdatedAt = null,
  usageSummaryFresh,
  preciseDataFresh,
  preciseRequestInFlight = false,
  exactGeneration = null,
  aggregateExactGeneration = null,
  aggregatePublishedGeneration = null,
  aggregateCoveredAt = null,
  onCodexHomeChange,
  onCodexHomeReset,
  onCheckForUpdate,
  onExportCsv,
  onExportPng,
  onOpenProviderRepair,
  onOpenSessionManagement,
  onOpenSettings,
  onRefresh,
  onToggleAutostart,
  refreshing,
  preciseProgress = null,
  appUpdateState,
  threadDeleteBridgeStatus,
  autoResumeEnabled,
  runningThreads = PENDING_HEADER_RUNNING_THREADS,
}: DashboardHeaderProps) {
  const [editingPath, setEditingPath] = useState(false);
  const [moreMenuOpen, setMoreMenuOpen] = useState(false);
  const moreMenuRef = useRef<HTMLDivElement>(null);
  const autostartHelpId = useId();
  useEffect(() => {
    if (!moreMenuOpen) return undefined;
    const closeForPointer = (event: PointerEvent) => {
      if (!moreMenuRef.current?.contains(event.target as Node)) setMoreMenuOpen(false);
    };
    const closeForEscape = (event: globalThis.KeyboardEvent) => {
      if (event.key === "Escape") setMoreMenuOpen(false);
    };
    document.addEventListener("pointerdown", closeForPointer);
    window.addEventListener("keydown", closeForEscape);
    return () => {
      document.removeEventListener("pointerdown", closeForPointer);
      window.removeEventListener("keydown", closeForEscape);
    };
  }, [moreMenuOpen]);

  const timeFormatter = new Intl.DateTimeFormat("zh-CN", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
  const timeLabel = timeFormatter.format(new Date(usageSummaryUpdatedAt ?? generatedAt));
  const checkedDate = usageSummaryCheckedAt ? new Date(usageSummaryCheckedAt) : null;
  const dataDate = usageSummaryDataUpdatedAt ? new Date(usageSummaryDataUpdatedAt) : null;
  const hasFreshnessTimes = checkedDate !== null
    && !Number.isNaN(checkedDate.getTime());
  const hasDataTime = dataDate !== null && !Number.isNaN(dataDate.getTime());
  // Keep the status strip focused on two user-facing freshness facts:
  // actual summary data publication and chart coverage. A successful check
  // without changed data is an internal coordinator event, not a second
  // timestamp to squeeze into the same narrow cell.
  const explicitSummaryTime = hasDataTime
    ? `数据更新于 ${timeFormatter.format(dataDate!)}`
    : hasFreshnessTimes
      ? `摘要于 ${timeFormatter.format(checkedDate!)}`
      : null;
  const summaryProgressTime = explicitSummaryTime ?? `摘要 ${timeLabel}`;
  const summaryCompleteTime = explicitSummaryTime ?? `更新于 ${timeLabel}`;
  const aggregateTimeLabel = aggregateCoveredAt === null
    ? null
    : new Intl.DateTimeFormat("zh-CN", {
        hour: "2-digit",
        minute: "2-digit",
      }).format(new Date(aggregateCoveredAt));
  // The progress endpoint is the source of truth for the index owner. Keep it
  // visible even after the lightweight summary publishes so migration/model
  // backfill cannot be mistaken for a finished read.
  const progressPresentation = presentDashboardHeaderProgress(preciseProgress);
  const activeProgress = progressPresentation?.isVisible
    ? progressPresentation
    : null;
  // `refreshing` includes the slower chart/index owner. Only the explicit
  // light-summary state may replace the published summary timestamp.
  const lightSummarySyncing = usageSummaryFresh === false
    || (usageSummaryFresh === undefined && refreshing);
  // A light summary may legitimately advance the source generation while the
  // next chart cadence is still waiting. Only an active Full/progress owner
  // should turn that lag into “图表同步中”; otherwise keep the honest
  // settled-through label instead of implying a chart job is running. After
  // the light part of a Full request has published, the progress endpoint can
  // briefly be quiet while the native precise owner is still running, so use
  // its explicit in-flight signal rather than the broader UI refresh flag
  // (which also covers quota and radar refreshes).
  const fullAggregateRequestActive = preciseRequestInFlight || activeProgress !== null;
  const aggregateSourceLeading = fullAggregateRequestActive && generationIsAhead(
    exactGeneration,
    aggregateExactGeneration,
    aggregatePublishedGeneration,
  );
  const aggregateLineageMissing = preciseDataFresh === true
    && (exactGeneration === null
      || aggregateExactGeneration === null
      || aggregatePublishedGeneration === null);
  const preciseStatisticsPending = preciseDataFresh === false;
  const aggregateWaitingWithoutLineage = aggregateLineageMissing && aggregateTimeLabel === null;
  const fullPrecisionPending = preciseStatisticsPending
    || aggregateSourceLeading
    || aggregateWaitingWithoutLineage;
  const freshnessStage = activeProgress?.stage ?? (fullPrecisionPending ? "waiting" : null);
  const sourceLabel = codexHome.source === "manual" ? "手动目录" : codexHome.exists ? "自动发现" : "等待选择";
  const updateBusy = appUpdateState.kind === "checking" || appUpdateState.kind === "installing";
  const updateButtonLabel = appUpdateState.kind === "checking"
    ? "检查中…"
    : appUpdateState.kind === "installing"
      ? "安装中…"
      : appUpdateState.kind === "available"
        ? "安装更新"
        : appUpdateState.kind === "error"
          ? "重试更新检查"
          : appUpdateState.message && appUpdateState.message.length <= 20 ? appUpdateState.message : "检查更新";
  const updateNeedsAttention = appUpdateState.kind === "available" || appUpdateState.kind === "error";

  function runMenuAction(action: () => void) {
    setMoreMenuOpen(false);
    action();
  }

  return (
    <header className="dashboard-header">
      <div className="dashboard-header-top">
        <div className="dashboard-scope-slot">
          <h1 className="dashboard-overview-title">用量概览{refreshing && <span>读取中</span>}</h1>
          {scopeControl}
        </div>
        <div className="dashboard-global-tools" role="group" aria-label="全局工具">
          <div className="dashboard-global-meta"><span>全局工具</span><div className="dashboard-global-status">{reportingStatus}{includesCodex && (<span className={`dash-head__freshness${freshnessStage ? ` is-${freshnessStage}` : ""}`}>
            <small>{activeProgress?.phaseLabel ?? (fullPrecisionPending ? "等待精确统计" : "精确统计")}</small>
            <strong>
              <i aria-hidden="true" className="precise-progress-dot" />
              {activeProgress
                ? activeProgress.text
                : aggregateSourceLeading
                  ? `${summaryProgressTime} · 模型与图表同步中`
                  : preciseStatisticsPending
                    ? `${summaryProgressTime} · 等待精确统计`
                  : aggregateWaitingWithoutLineage
                    ? `${summaryProgressTime} · 等待图表聚合`
                  : lightSummarySyncing
                    ? `${summaryProgressTime} · 同步中`
                  : aggregateTimeLabel === null
                    ? summaryCompleteTime
                    : `${summaryCompleteTime} · 图表至 ${aggregateTimeLabel}`}
              {activeProgress?.countLabel ? ` ${activeProgress.countLabel}` : ""}
            </strong>
            {activeProgress?.showsReassurance ? (
              <small className="precise-progress-hint">{PRECISE_PROGRESS_REASSURANCE}</small>
            ) : null}
            {activeProgress?.showsProgress ? (
              <span
                aria-label={activeProgress.countLabel ?? activeProgress.text}
                aria-valuemax={preciseProgress?.total ?? undefined}
                aria-valuemin={preciseProgress?.total == null ? undefined : 0}
                aria-valuenow={preciseProgress?.total == null ? undefined : preciseProgress.completed}
                className={`precise-progress-bar${activeProgress.fraction == null ? " is-indeterminate" : ""}`}
                role="progressbar"
              >
                <span style={{ width: `${Math.round((activeProgress.fraction ?? 0) * 100)}%` }} />
              </span>
            ) : null}
          </span>)}</div></div>
          <div className="dashboard-global-actions">
            <button className="dash-head__action dash-head__action--accent" disabled={refreshing} onClick={onRefresh} type="button">{refreshing ? "刷新中…" : "立即刷新"}</button>
            <div className="dash-head__action-group">
              <button className="dash-head__action dash-head__action--accent" onClick={() => onOpenSettings("general")} type="button">设置</button>
              <DiagnosticNotice summary="" logs="" buttonOnly />
              <div className="dash-head__more" ref={moreMenuRef}>
                <button
                  aria-expanded={moreMenuOpen}
                  aria-haspopup="menu"
                  aria-label="更多操作"
                  className="dash-head__action dash-head__action--more"
                  onClick={() => setMoreMenuOpen((current) => !current)}
                  type="button"
                >
                  更多
                  {updateNeedsAttention ? <i aria-label="更新需要处理" className="dash-head__attention" /> : null}
                </button>
                {moreMenuOpen ? (
                  <div className="dash-head__menu" role="menu">
                    <div className="dash-head__menu-group">
                      <span>数据</span>
                      <button onClick={() => runMenuAction(onExportCsv)} role="menuitem" type="button">导出 CSV</button>
                      <button onClick={() => runMenuAction(onExportPng)} role="menuitem" type="button">导出 PNG</button>
                    </div>
                    <div className="dash-head__menu-group">
                      <span>应用</span>
                      <button
                        className={updateNeedsAttention ? `update-action--${appUpdateState.kind}` : undefined}
                        disabled={updateBusy}
                        onClick={() => runMenuAction(() => { void onCheckForUpdate(); })}
                        role="menuitem"
                        title={appUpdateState.message || undefined}
                        type="button"
                      >{updateButtonLabel}</button>
                      {appUpdateState.message.includes("更新未完成") || appUpdateState.message.includes("尚未确认") || appUpdateState.message.includes("无法确认") ? (
                        <small role="status" style={{ whiteSpace: "normal", overflowWrap: "anywhere" }}>{appUpdateState.message}</small>
                      ) : null}
                      <button
                        aria-describedby={autostartStatus.message ? autostartHelpId : undefined}
                        aria-pressed={autostartStatus.enabled}
                        disabled={!autostartStatus.available}
                        onClick={() => runMenuAction(onToggleAutostart)}
                        role="menuitem"
                        title={autostartStatus.message}
                        type="button"
                      >开机自启：{autostartStatus.enabled ? "开" : "关"}</button>
                      {autostartStatus.message ? <span className="visually-hidden" id={autostartHelpId}>{autostartStatus.message}</span> : null}
                    </div>
                  </div>
                ) : null}
              </div>
            </div>
          </div>
        </div>
      </div>
      {includesCodex && <section className="dash-head dash-head--scoped" aria-label="Codex 专属工具">
        <div className="dashboard-codex-context">
          <div className="dashboard-codex-heading"><strong>Codex</strong><span>专属工具</span><small title={runningThreads.detail}>任务 · {runningThreadHeaderText(runningThreads)}</small></div>
          <button className="dashboard-codex-source" onClick={() => setEditingPath(value => !value)} title={codexHome.path} type="button" aria-label="更改 Codex 数据目录">
            <span>{sourceLabel}</span><strong>{codexHome.path}</strong><span aria-hidden="true">⌄</span>
          </button>

        </div>
        <div className="dashboard-codex-toolbox" role="group" aria-label="Codex 会话操作">
            <div className="dash-head__action-group">
              <button className="dash-head__action dash-head__action--accent" onClick={onOpenSessionManagement} title="按项目浏览上下文，管理归档、恢复包和容量清理" type="button">会话管理</button>
              <button
                aria-label="会话增强"
                className={`dash-head__action${threadDeleteBridgeStatus.connected ? " is-enabled" : ""}`}
                onClick={() => onOpenSettings("session")}
                title={threadDeleteBridgeStatus.message}
                type="button"
              >
                会话增强{threadDeleteBridgeStatus.connected ? " · 已连接" : ""}
              </button>
              <button
                aria-label="自动续跑"
                aria-pressed={autoResumeEnabled}
                className={`dash-head__action${autoResumeEnabled ? " is-enabled" : ""}`}
                onClick={() => onOpenSettings("automation")}
                title={autoResumeEnabled ? "自动续跑已开启，点击管理" : "管理失败中断、定时和额度恢复续跑"}
                type="button"
              >
                自动续跑{autoResumeEnabled ? " · 已开启" : ""}
              </button>
            </div>

          <div className="dashboard-codex-maintenance">
            <button className="dash-head__action" onClick={() => setEditingPath(value => !value)} type="button">{editingPath ? "收起目录" : "更改目录"}</button>
            <button className="dash-head__action" onClick={onOpenProviderRepair} title="找回 Codex 消失的历史会话" type="button">会话消失修复</button>
          </div>
        </div>
        {editingPath && <CodexHomeEditor codexHome={codexHome} onCodexHomeChange={onCodexHomeChange} onCodexHomeReset={onCodexHomeReset} onDone={() => setEditingPath(false)}/>}
      </section>}
    </header>
  );
}

export function runningThreadHeaderText(summary: RunningThreadSummary): string {
  if (
    summary.total === null
    || summary.mainThreads === null
    || summary.subagents === null
  ) {
    return summary.status === "unavailable" ? "暂不可用" : "正在读取…";
  }
  const prefix = summary.status === "stale" ? "上次 · " : "";
  return `${prefix}总 ${summary.total} · 主 ${summary.mainThreads} · 子 ${summary.subagents}`;
}
