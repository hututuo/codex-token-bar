import type { AccountInfo, AutostartStatus, CodexHomeStatus } from "../types/dashboard";
import { CodexHomeEditor } from "./dashboardHeader/CodexHomeEditor";
import {
  committedCustomAccountDisplayName,
  resolveAccountDisplayName,
  shouldCommitDisplayNameOnKey,
} from "./dashboardHeader/model";
import { useEffect, useId, useRef, useState, type KeyboardEvent } from "react";
import type { ThreadDeleteBridgeStatus } from "../api/threadDeleteClient";

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
  onReconnectThreadDelete: () => Promise<void>;
  onToggleAutostart: () => void;
  refreshing: boolean;
  appUpdateState: {
    kind: "idle" | "checking" | "available" | "installing" | "error";
    message: string;
  };
  threadDeleteBridgeStatus: ThreadDeleteBridgeStatus;
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
  onReconnectThreadDelete,
  onToggleAutostart,
  refreshing,
  appUpdateState,
  threadDeleteBridgeStatus,
}: DashboardHeaderProps) {
  const [editingPath, setEditingPath] = useState(false);
  const [editingDisplayName, setEditingDisplayName] = useState(false);
  const [threadDeleteConfirmationOpen, setThreadDeleteConfirmationOpen] = useState(false);
  const threadDeleteTriggerRef = useRef<HTMLButtonElement>(null);
  const threadDeleteDialogRef = useRef<HTMLDivElement>(null);
  const threadDeleteCancelRef = useRef<HTMLButtonElement>(null);
  const autostartHelpId = useId();
  const threadDeleteHelpId = useId();
  const threadDeleteDialogTitleId = useId();
  const threadDeleteDialogDescriptionId = useId();
  const resolvedDisplayName = resolveAccountDisplayName(
    account.displayName,
    customAccountDisplayName,
  );
  const threadDeleteActionLabel = threadDeleteBridgeStatus.connected
    ? "会话删除已启用"
    : threadDeleteBridgeStatus.debugPort === null ? "启用会话删除" : "重连会话删除";
  const threadDeleteActionDescription = threadDeleteBridgeStatus.debugPort === null
    ? "重启 Codex 并启用删除按钮"
    : "重新连接 Codex 删除按钮";
  const [displayNameDraft, setDisplayNameDraft] = useState(resolvedDisplayName);

  useEffect(() => {
    if (!editingDisplayName) {
      setDisplayNameDraft(resolvedDisplayName);
    }
  }, [editingDisplayName, resolvedDisplayName]);

  useEffect(() => {
    if (threadDeleteConfirmationOpen) {
      threadDeleteCancelRef.current?.focus();
    }
  }, [threadDeleteConfirmationOpen]);

  const closeThreadDeleteConfirmation = () => {
    setThreadDeleteConfirmationOpen(false);
    window.requestAnimationFrame(() => threadDeleteTriggerRef.current?.focus());
  };

  const handleThreadDeleteDialogKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.key === "Escape") {
      event.preventDefault();
      closeThreadDeleteConfirmation();
      return;
    }
    if (event.key !== "Tab") return;
    const buttons = [...(threadDeleteDialogRef.current?.querySelectorAll<HTMLButtonElement>("button") ?? [])];
    if (buttons.length === 0) return;
    const currentIndex = buttons.indexOf(document.activeElement as HTMLButtonElement);
    if (event.shiftKey && currentIndex <= 0) {
      event.preventDefault();
      buttons.at(-1)?.focus();
    } else if (!event.shiftKey && currentIndex === buttons.length - 1) {
      event.preventDefault();
      buttons[0]?.focus();
    }
  };

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
        <div className="header-context">
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
            aria-describedby={threadDeleteHelpId}
            aria-label={threadDeleteActionLabel}
            className={threadDeleteBridgeStatus.connected
              ? "toolbar-button thread-delete-action thread-delete-action--connected"
              : "toolbar-button thread-delete-action"}
            onClick={() => {
              if (threadDeleteBridgeStatus.debugPort === null) {
                setThreadDeleteConfirmationOpen(true);
              } else {
                void onReconnectThreadDelete();
              }
            }}
            ref={threadDeleteTriggerRef}
            title={threadDeleteBridgeStatus.message}
            type="button"
          >
            <span aria-hidden="true" className="thread-delete-action-dot" />
            {threadDeleteActionLabel}
          </button>
          <span className="visually-hidden" id={threadDeleteHelpId}>
            {threadDeleteActionDescription}。{threadDeleteBridgeStatus.message}
          </span>
          <button className="toolbar-button" onClick={onExportCsv} type="button">
            导出 CSV
          </button>
          <button className="toolbar-button" onClick={onExportPng} type="button">
            导出 PNG
          </button>
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
      {threadDeleteConfirmationOpen ? (
        <div
          className="thread-delete-confirmation-overlay"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget) closeThreadDeleteConfirmation();
          }}
        >
          <div
            aria-describedby={threadDeleteDialogDescriptionId}
            aria-labelledby={threadDeleteDialogTitleId}
            aria-modal="true"
            className="thread-delete-confirmation-dialog"
            onKeyDown={handleThreadDeleteDialogKeyDown}
            ref={threadDeleteDialogRef}
            role="alertdialog"
          >
            <h2 id={threadDeleteDialogTitleId}>重启 Codex 并启用会话删除按钮？</h2>
            <p id={threadDeleteDialogDescriptionId}>
              Codex 会关闭后立即以仅限本机的调试端口重新打开。当前任务不会被删除，但界面会短暂中断。
            </p>
            <div className="thread-delete-confirmation-actions">
              <button onClick={closeThreadDeleteConfirmation} ref={threadDeleteCancelRef} type="button">
                取消
              </button>
              <button
                className="thread-delete-confirmation-primary"
                onClick={() => {
                  setThreadDeleteConfirmationOpen(false);
                  window.requestAnimationFrame(() => threadDeleteTriggerRef.current?.focus());
                  void onReconnectThreadDelete();
                }}
                type="button"
              >
                重启并启用
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </header>
  );
}
