import type { AccountInfo, AutostartStatus, CodexHomeStatus } from "../types/dashboard";
import { CodexHomeEditor } from "./dashboardHeader/CodexHomeEditor";
import {
  committedCustomAccountDisplayName,
  resolveAccountDisplayName,
  shouldCommitDisplayNameOnKey,
} from "./dashboardHeader/model";
import { useEffect, useId, useState, type KeyboardEvent } from "react";
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
}

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
  onOpenSettings,
  onRefresh,
  onToggleAutostart,
  refreshing,
  appUpdateState,
  threadDeleteBridgeStatus,
  autoResumeEnabled,
}: DashboardHeaderProps) {
  const [editingPath, setEditingPath] = useState(false);
  const [editingDisplayName, setEditingDisplayName] = useState(false);
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

  return (
    <header className="dashboard-header">
      <div className="floating-title-spacer" />
      <div className="brand-mark">CX</div>
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
          <button
            className="account-name-button"
            onClick={beginEditDisplayName}
            title="修改显示昵称"
            type="button"
          >
            <span className="account-name-pencil account-name-pencil--spacer">✎</span>
            <span className="account-name">{resolvedDisplayName}</span>
            <span className="account-name-pencil">✎</span>
          </button>
        )}
      </div>
      <div className="header-toolbar">
        <div aria-label="运行信息" className="header-context">
          <span className="header-info-cell header-info-cell--identity">
            <span className="header-info-kicker">Codex Token Bar</span>
            <span className="header-info-main">
              <i aria-hidden="true" className="platform-indicator" />
              <span className="platform-badge">跨平台版</span>
              <span className="plan-badge">{account.planLabel}</span>
            </span>
          </span>
          <span className="header-info-cell header-info-cell--source">
            <span className="header-info-kicker">数据源</span>
            <span className="header-info-main">
              <span className={codexHome.exists ? "status-dot status-dot--ok" : "status-dot"} />
              <span className="source-label">{sourceLabel}</span>
              <span className="path-pill" title={codexHome.path}>{codexHome.path}</span>
            </span>
          </span>
          <span className="header-info-cell header-info-cell--freshness">
            <span className="header-info-kicker">统计状态</span>
            <span className="header-info-main">
              <span className="header-data-mode">本地统计</span>
              <span className="updated-label">更新于 {updatedLabel}</span>
            </span>
          </span>
        </div>
        <div className="header-primary-actions" aria-label="常用操作">
          <span className="header-action-group header-action-group--primary">
            <button className="toolbar-button toolbar-button--accent" disabled={refreshing} onClick={onRefresh} type="button">
              立即刷新
            </button>
            <span aria-live={appUpdateState.message ? "polite" : "off"} className="header-update-action">
              <button
                className={updateNeedsAttention ? `toolbar-button update-action update-action--${appUpdateState.kind}` : "toolbar-button update-action"}
                disabled={updateBusy}
                onClick={onCheckForUpdate}
                title={appUpdateState.message || undefined}
                type="button"
              >
                {updateButtonLabel}
              </button>
            </span>
            <span className="header-autostart-action">
              <button
                aria-describedby={autostartStatus.message ? autostartHelpId : undefined}
                aria-pressed={autostartStatus.enabled}
                className={autostartStatus.enabled ? "toolbar-button is-active" : "toolbar-button"}
                disabled={!autostartStatus.available}
                onClick={onToggleAutostart}
                title={autostartStatus.message}
                type="button"
              >
                开机自启：{autostartStatus.enabled ? "开" : "关"}
              </button>
              {autostartStatus.message ? <span className="visually-hidden" id={autostartHelpId}>{autostartStatus.message}</span> : null}
            </span>
          </span>
          <span aria-hidden="true" className="header-action-divider" />
          <span className="header-action-group header-action-group--maintenance">
            <button className="toolbar-button" onClick={() => setEditingPath((value) => !value)} type="button">
              {editingPath ? "收起目录" : "更改目录"}
            </button>
            <button
              className="toolbar-button"
              onClick={onOpenProviderRepair}
              title="找回消失的历史会话"
              type="button"
            >
              会话消失修复
            </button>
            <button
              aria-label="会话增强"
              className={threadDeleteBridgeStatus.connected
                ? "toolbar-button thread-delete-action thread-delete-action--connected"
                : "toolbar-button thread-delete-action"}
              onClick={() => onOpenSettings("session")}
              title={threadDeleteBridgeStatus.message}
              type="button"
            >
              <span aria-hidden="true" className="thread-delete-action-dot" />
              会话增强
            </button>
            <button
              aria-pressed={autoResumeEnabled}
              className={autoResumeEnabled ? "toolbar-button is-active" : "toolbar-button"}
              onClick={() => onOpenSettings("automation")}
              title={autoResumeEnabled ? "自动续跑已开启" : "管理定时、额度恢复和中断续跑"}
              type="button"
            >
              自动续跑
            </button>
          </span>
          <span aria-hidden="true" className="header-action-divider" />
          <span className="header-action-group header-action-group--export">
            <button className="toolbar-button toolbar-button--settings" onClick={() => onOpenSettings("general")} type="button">
              设置
            </button>
            <button className="toolbar-button" onClick={onExportCsv} type="button">
              导出 CSV
            </button>
            <button className="toolbar-button" onClick={onExportPng} type="button">
              导出 PNG
            </button>
          </span>
        </div>
      </div>
      {editingPath ? (
        <CodexHomeEditor
          codexHome={codexHome}
          onCodexHomeChange={onCodexHomeChange}
          onCodexHomeReset={onCodexHomeReset}
          onDone={() => setEditingPath(false)}
        />
      ) : null}
    </header>
  );
}
