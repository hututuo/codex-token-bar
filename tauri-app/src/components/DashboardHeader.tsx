import type {
  AccountInfo,
  AutostartStatus,
  CodexHomeStatus,
  RunningThreadSummary,
} from "../types/dashboard";
import { CodexHomeEditor } from "./dashboardHeader/CodexHomeEditor";
import {
  committedCustomAccountDisplayName,
  resolveAccountDisplayName,
  shouldCommitDisplayNameOnKey,
} from "./dashboardHeader/model";
import { useEffect, useId, useRef, useState, type KeyboardEvent } from "react";
import type { ThreadDeleteBridgeStatus } from "../api/threadDeleteClient";
import type { AppSettingsCategory } from "./settings/AppSettingsDialog";

interface DashboardHeaderProps {
  account: AccountInfo;
  autostartStatus: AutostartStatus;
  codexHome: CodexHomeStatus;
  customAccountDisplayName: string;
  generatedAt: string;
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
  status: "scanning",
  updatedAt: null,
  detail: "正在读取当前数据源的会话生命周期",
  livenessLeaseHours: 24,
};

export function DashboardHeader({
  account,
  autostartStatus,
  codexHome,
  customAccountDisplayName,
  generatedAt,
  onCodexHomeChange,
  onCodexHomeReset,
  onCustomAccountDisplayNameChange,
  onCheckForUpdate,
  onExportCsv,
  onExportPng,
  onOpenProviderRepair,
  onOpenSessionManagement,
  onOpenSettings,
  onRefresh,
  onToggleAutostart,
  refreshing,
  appUpdateState,
  threadDeleteBridgeStatus,
  autoResumeEnabled,
  runningThreads = PENDING_HEADER_RUNNING_THREADS,
}: DashboardHeaderProps) {
  const [editingPath, setEditingPath] = useState(false);
  const [editingDisplayName, setEditingDisplayName] = useState(false);
  const [moreMenuOpen, setMoreMenuOpen] = useState(false);
  const moreMenuRef = useRef<HTMLDivElement>(null);
  const autostartHelpId = useId();
  const resolvedDisplayName = resolveAccountDisplayName(
    account.displayName,
    customAccountDisplayName,
  );
  const [displayNameDraft, setDisplayNameDraft] = useState(resolvedDisplayName);

  useEffect(() => {
    if (!editingDisplayName) {
      setDisplayNameDraft(resolvedDisplayName);
    }
  }, [editingDisplayName, resolvedDisplayName]);

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

  const timeLabel = new Intl.DateTimeFormat("zh-CN", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).format(new Date(generatedAt));
  const updatedLabel = refreshing ? "同步中" : timeLabel;
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
          : appUpdateState.message || "检查更新";
  const updateNeedsAttention = appUpdateState.kind === "available" || appUpdateState.kind === "error";

  function beginEditDisplayName() {
    setDisplayNameDraft(resolvedDisplayName);
    setEditingDisplayName(true);
  }

  function commitDisplayName() {
    const nextName = committedCustomAccountDisplayName(
      displayNameDraft,
      customAccountDisplayName,
    );
    setEditingDisplayName(false);
    if (nextName !== null) {
      void onCustomAccountDisplayNameChange(nextName);
    }
  }

  function handleDisplayNameKeyDown(event: KeyboardEvent<HTMLInputElement>) {
    if (shouldCommitDisplayNameOnKey(event.key)) {
      event.currentTarget.blur();
    }
  }

  function runMenuAction(action: () => void) {
    setMoreMenuOpen(false);
    action();
  }

  return (
    <header className="dashboard-header">
      <div className="floating-title-spacer" />
      <div aria-hidden="true" className="brand-mark">CX</div>
      <div className="account-row">
        {editingDisplayName ? (
          <input
            autoFocus
            aria-label="昵称"
            className="account-name-edit"
            onBlur={commitDisplayName}
            onChange={(event) => setDisplayNameDraft(event.currentTarget.value)}
            onKeyDown={handleDisplayNameKeyDown}
            value={displayNameDraft}
          />
        ) : (
          <button className="account-name-button" onClick={beginEditDisplayName} title="修改显示昵称" type="button">
            <span aria-hidden="true" className="account-name-pencil account-name-pencil--spacer">✎</span>
            <span className="account-name">{resolvedDisplayName}</span>
            <span aria-hidden="true" className="account-name-pencil">✎</span>
          </button>
        )}
      </div>

      <div className="dash-head">
        <div className="dash-head__top dash-head__top--actions-only">
          <div aria-label="常用操作" className="dash-head__actions">
            <button className="dash-head__action dash-head__action--accent" disabled={refreshing} onClick={onRefresh} type="button">
              {refreshing ? "刷新中…" : "立即刷新"}
            </button>
            <button className="dash-head__action" onClick={() => onOpenSettings("general")} type="button">设置</button>
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
                    <span>会话</span>
                    <button onClick={() => runMenuAction(onOpenSessionManagement)} role="menuitem" type="button">会话管理</button>
                    <button onClick={() => runMenuAction(onOpenProviderRepair)} role="menuitem" title="找回消失的历史会话" type="button">会话消失修复</button>
                    <button onClick={() => runMenuAction(() => onOpenSettings("session"))} role="menuitem" title={threadDeleteBridgeStatus.message} type="button">
                      会话增强{threadDeleteBridgeStatus.connected ? " · 已连接" : ""}
                    </button>
                    <button onClick={() => runMenuAction(() => onOpenSettings("automation"))} role="menuitem" type="button">
                      自动续跑{autoResumeEnabled ? " · 已开启" : ""}
                    </button>
                  </div>
                  <div className="dash-head__menu-group">
                    <span>数据</span>
                    <button onClick={() => runMenuAction(() => setEditingPath((value) => !value))} role="menuitem" type="button">{editingPath ? "收起目录" : "更改目录"}</button>
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

        <div aria-label="运行信息" className="dash-head__strip">
          <span className="dash-head__platform">
            <small>Codex Token Bar</small>
            <strong>
              <i aria-hidden="true" className="platform-indicator" />
              <span className="platform-badge">跨平台版</span>
              <span className="plan-badge">{account.planLabel}</span>
            </strong>
          </span>
          <button className="dash-head__source" onClick={() => setEditingPath((value) => !value)} title={codexHome.path} type="button">
            <span className={codexHome.exists ? "status-dot status-dot--ok" : "status-dot"} />
            <span>{sourceLabel}</span>
            <strong>{codexHome.path}</strong>
          </button>
          <span aria-live="polite" className={`dash-head__threads is-${runningThreads.status}`} title={runningThreads.detail}>
            <small>运行线程</small>
            <strong>{runningThreadHeaderText(runningThreads)}</strong>
          </span>
          <span className="dash-head__freshness">
            <small>本地统计</small>
            <strong>更新于 {updatedLabel}</strong>
          </span>
        </div>
        {editingPath ? (
          <CodexHomeEditor
            codexHome={codexHome}
            onCodexHomeChange={onCodexHomeChange}
            onCodexHomeReset={onCodexHomeReset}
            onDone={() => setEditingPath(false)}
          />
        ) : null}
      </div>
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
