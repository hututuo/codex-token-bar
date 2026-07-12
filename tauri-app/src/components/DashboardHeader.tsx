import type { AccountInfo, AutostartStatus, CodexHomeStatus } from "../types/dashboard";
import { CodexHomeEditor } from "./dashboardHeader/CodexHomeEditor";
import {
  committedCustomAccountDisplayName,
  resolveAccountDisplayName,
  shouldCommitDisplayNameOnKey,
} from "./dashboardHeader/model";
import { useEffect, useId, useRef, useState, type FocusEvent, type KeyboardEvent } from "react";

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
  const moreActionsTriggerRef = useRef<HTMLButtonElement>(null);
  const moreActionsMenuRef = useRef<HTMLDivElement>(null);
  const pendingMenuFocusRef = useRef<"first" | "last" | null>(null);
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

  useEffect(() => {
    if (!moreActionsOpen) return;
    function closeOnOutsidePointer(event: PointerEvent) {
      if (!moreActionsRef.current?.contains(event.target as Node)) setMoreActionsOpen(false);
    }
    document.addEventListener("pointerdown", closeOnOutsidePointer);
    return () => {
      document.removeEventListener("pointerdown", closeOnOutsidePointer);
    };
  }, [moreActionsOpen]);

  useEffect(() => {
    if (!moreActionsOpen || !pendingMenuFocusRef.current) return;
    const items = enabledMenuItems();
    const target = pendingMenuFocusRef.current === "last" ? items.at(-1) : items[0];
    pendingMenuFocusRef.current = null;
    target?.focus();
  }, [moreActionsOpen]);

  function enabledMenuItems() {
    return [...(moreActionsMenuRef.current?.querySelectorAll<HTMLElement>(
      '[role="menuitem"], [role="menuitemcheckbox"]',
    ) ?? [])].filter((item) => !item.hasAttribute("disabled"));
  }

  function openMoreActions(focus: "first" | "last" = "first") {
    pendingMenuFocusRef.current = focus;
    setMoreActionsOpen(true);
  }

  function closeMoreActionsAndRestoreFocus() {
    setMoreActionsOpen(false);
    moreActionsTriggerRef.current?.focus();
  }

  function handleMoreActionsTriggerKeyDown(event: KeyboardEvent<HTMLButtonElement>) {
    if (event.key === "Enter" || event.key === " " || event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      openMoreActions(event.key === "ArrowUp" ? "last" : "first");
    }
  }

  function focusOutsideMenu(backward: boolean) {
    const focusable = [...document.querySelectorAll<HTMLElement>(
      'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
    )].filter((element) => !moreActionsMenuRef.current?.contains(element));
    const triggerIndex = focusable.indexOf(moreActionsTriggerRef.current as HTMLElement);
    const target = focusable[triggerIndex + (backward ? -1 : 1)];
    setMoreActionsOpen(false);
    target?.focus();
  }

  function handleMoreActionsMenuKeyDown(event: KeyboardEvent<HTMLDivElement>) {
    const items = enabledMenuItems();
    if (!items.length) return;
    const activeIndex = items.indexOf(document.activeElement as HTMLElement);
    let target: HTMLElement | undefined;
    if (event.key === "ArrowDown") target = items[(activeIndex + 1 + items.length) % items.length];
    else if (event.key === "ArrowUp") target = items[(activeIndex - 1 + items.length) % items.length];
    else if (event.key === "Home") target = items[0];
    else if (event.key === "End") target = items.at(-1);
    else if (event.key === "Escape") {
      event.preventDefault();
      closeMoreActionsAndRestoreFocus();
      return;
    } else if (event.key === "Tab") {
      event.preventDefault();
      focusOutsideMenu(event.shiftKey);
      return;
    } else return;
    event.preventDefault();
    target?.focus();
  }

  function handleMoreActionsBlur(event: FocusEvent<HTMLDivElement>) {
    const next = event.relatedTarget as Node | null;
    if (next && !moreActionsRef.current?.contains(next)) setMoreActionsOpen(false);
  }

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
          <div className="more-actions" ref={moreActionsRef}>
            <button
              aria-expanded={moreActionsOpen}
              aria-haspopup="menu"
              aria-label="更多操作"
              className="toolbar-button more-actions-trigger"
              onClick={() => moreActionsOpen ? closeMoreActionsAndRestoreFocus() : openMoreActions()}
              onKeyDown={handleMoreActionsTriggerKeyDown}
              ref={moreActionsTriggerRef}
              type="button"
            >
              <span aria-hidden="true">•••</span>
              <span>更多操作</span>
            </button>
            {moreActionsOpen ? (
              <div
                aria-label="更多操作"
                className="more-actions-menu"
                onBlur={handleMoreActionsBlur}
                onKeyDown={handleMoreActionsMenuKeyDown}
                ref={moreActionsMenuRef}
                role="menu"
              >
                <button onClick={() => { onExportCsv(); closeMoreActionsAndRestoreFocus(); }} role="menuitem" tabIndex={-1} type="button">
                  导出 CSV
                </button>
                <button onClick={() => { onExportPng(); closeMoreActionsAndRestoreFocus(); }} role="menuitem" tabIndex={-1} type="button">
                  导出 PNG
                </button>
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
