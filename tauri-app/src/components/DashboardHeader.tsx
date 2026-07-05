import type { AccountInfo, AutostartStatus, CodexHomeStatus } from "../types/dashboard";
import { CodexHomeEditor } from "./dashboardHeader/CodexHomeEditor";
import {
  committedCustomAccountDisplayName,
  resolveAccountDisplayName,
  shouldCommitDisplayNameOnKey,
} from "./dashboardHeader/model";
import { useEffect, useState, type KeyboardEvent } from "react";

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
  onRefresh: () => Promise<void>;
  onToggleAutostart: () => void;
  refreshing: boolean;
  appUpdateState: {
    kind: "idle" | "checking" | "available" | "installing" | "error";
    message: string;
  };
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
  onRefresh,
  onToggleAutostart,
  refreshing,
  appUpdateState,
}: DashboardHeaderProps) {
  const [editingPath, setEditingPath] = useState(false);
  const [editingDisplayName, setEditingDisplayName] = useState(false);
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
  const sourceLabel = codexHome.source === "manual" ? "手动目录" : codexHome.exists ? "自动发现" : "等待选择";
  const updateBusy = appUpdateState.kind === "checking" || appUpdateState.kind === "installing";
  const updateButtonLabel = appUpdateState.kind === "available" ? "安装更新" : "检查更新";

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
        <span className="app-name">Codex Token Bar</span>
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
        <span className="plan-badge">{account.planLabel}</span>
      </div>
      <div className="source-row">
        <span className={codexHome.exists ? "status-dot status-dot--ok" : "status-dot"} />
        <span>{sourceLabel}</span>
        <span className="path-pill">{codexHome.path}</span>
        <span className="muted">Updated {timeLabel}</span>
        <button className="toolbar-button" disabled={refreshing} onClick={onRefresh} type="button">
          立即刷新
        </button>
        <button className="toolbar-button" disabled={updateBusy} onClick={onCheckForUpdate} type="button">
          {updateButtonLabel}
        </button>
        {appUpdateState.message ? (
          <span className={`update-status update-status--${appUpdateState.kind}`}>{appUpdateState.message}</span>
        ) : null}
        <button className="toolbar-button" onClick={onExportCsv} type="button">
          导出 CSV
        </button>
        <button className="toolbar-button" onClick={onExportPng} type="button">
          导出 PNG
        </button>
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
          className={autostartStatus.enabled ? "toolbar-button is-active" : "toolbar-button"}
          disabled={!autostartStatus.available}
          onClick={onToggleAutostart}
          title={autostartStatus.message}
          type="button"
        >
          开机自启{autostartStatus.enabled ? "开" : "关"}
        </button>
        <span className="refresh-label">{refreshing ? "同步中" : ""}</span>
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
