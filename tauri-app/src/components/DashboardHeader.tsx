import type { AccountInfo, AutostartStatus, CodexHomeStatus } from "../types/dashboard";
import { CodexHomeEditor } from "./dashboardHeader/CodexHomeEditor";
import {
  committedCustomAccountDisplayName,
  resolveAccountDisplayName,
  shouldCommitDisplayNameOnKey,
} from "./dashboardHeader/model";
import { useEffect, useRef, useState, type KeyboardEvent } from "react";

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
  const [moreActionsOpen, setMoreActionsOpen] = useState(false);
  const moreActionsRef = useRef<HTMLDivElement>(null);
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
  const updateButtonLabel = appUpdateState.kind === "available" ? "安装更新" : "检查更新";
  const updateNeedsAttention = appUpdateState.kind === "available" || appUpdateState.kind === "error";

  useEffect(() => {
    if (!moreActionsOpen) return;
    function closeOnOutsidePointer(event: PointerEvent) {
      if (!moreActionsRef.current?.contains(event.target as Node)) setMoreActionsOpen(false);
    }
    function closeOnEscape(event: globalThis.KeyboardEvent) {
      if (event.key === "Escape") setMoreActionsOpen(false);
    }
    document.addEventListener("pointerdown", closeOnOutsidePointer);
    document.addEventListener("keydown", closeOnEscape);
    return () => {
      document.removeEventListener("pointerdown", closeOnOutsidePointer);
      document.removeEventListener("keydown", closeOnEscape);
    };
  }, [moreActionsOpen]);

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
        <div className="header-context">
          <span className="app-name">Codex Token Bar</span>
          <span className="plan-badge">{account.planLabel}</span>
          <span className={codexHome.exists ? "status-dot status-dot--ok" : "status-dot"} />
          <span className="source-label">{sourceLabel}</span>
          <span className="path-pill">{codexHome.path}</span>
          <span className="muted updated-label">更新于 {updatedLabel}</span>
        </div>
        <div className="header-primary-actions" aria-label="常用操作">
          <button className="toolbar-button" disabled={refreshing} onClick={onRefresh} type="button">
            立即刷新
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
          <div className="more-actions" ref={moreActionsRef}>
            <button
              aria-expanded={moreActionsOpen}
              aria-haspopup="menu"
              aria-label={updateNeedsAttention ? `更多操作，${appUpdateState.message || "更新状态需要关注"}` : "更多操作"}
              className={updateNeedsAttention ? "toolbar-button more-actions-trigger has-update-state" : "toolbar-button more-actions-trigger"}
              onClick={() => setMoreActionsOpen((value) => !value)}
              type="button"
            >
              <span aria-hidden="true">•••</span>
              <span>更多操作</span>
              {updateNeedsAttention ? <span aria-hidden="true" className={`more-actions-indicator more-actions-indicator--${appUpdateState.kind}`} /> : null}
            </button>
            {moreActionsOpen ? (
              <div aria-label="更多操作" className="more-actions-menu" role="menu">
                <button disabled={updateBusy} onClick={onCheckForUpdate} role="menuitem" type="button">
                  {updateButtonLabel}
                </button>
                <span
                  aria-live={appUpdateState.message ? "polite" : "off"}
                  className={`update-status-slot update-status--${appUpdateState.kind}`}
                  title={appUpdateState.message || undefined}
                >
                  {appUpdateState.message || "尚未检查更新"}
                </span>
                <button onClick={() => { onExportCsv(); setMoreActionsOpen(false); }} role="menuitem" type="button">
                  导出 CSV
                </button>
                <button onClick={() => { onExportPng(); setMoreActionsOpen(false); }} role="menuitem" type="button">
                  导出 PNG
                </button>
                <button
                  aria-checked={autostartStatus.enabled}
                  disabled={!autostartStatus.available}
                  onClick={() => { onToggleAutostart(); setMoreActionsOpen(false); }}
                  role="menuitemcheckbox"
                  title={autostartStatus.message}
                  type="button"
                >
                  开机自启：{autostartStatus.enabled ? "开" : "关"}
                </button>
                {autostartStatus.message ? <span className="more-actions-help">{autostartStatus.message}</span> : null}
              </div>
            ) : null}
          </div>
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
