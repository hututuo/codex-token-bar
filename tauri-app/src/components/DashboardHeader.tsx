import { useEffect, useState } from "react";
import type { CommandFailureDiagnostic } from "../api/client";
import type { AccountInfo, CodexHomeStatus } from "../types/dashboard";

interface DashboardHeaderProps {
  account: AccountInfo;
  codexHome: CodexHomeStatus;
  diagnostics: CommandFailureDiagnostic[];
  generatedAt: string;
  onCodexHomeChange: (path: string) => Promise<void>;
  onCodexHomeReset: () => Promise<void>;
  onOpenProviderRepair: () => void;
  onRefresh: () => Promise<void>;
  refreshing: boolean;
}

export function DashboardHeader({
  account,
  codexHome,
  diagnostics,
  generatedAt,
  onCodexHomeChange,
  onCodexHomeReset,
  onOpenProviderRepair,
  onRefresh,
  refreshing,
}: DashboardHeaderProps) {
  const [editingPath, setEditingPath] = useState(false);
  const [pathDraft, setPathDraft] = useState(codexHome.path);
  const [savingPath, setSavingPath] = useState(false);

  useEffect(() => {
    setPathDraft(codexHome.path);
  }, [codexHome.path]);

  const timeLabel = new Intl.DateTimeFormat("zh-CN", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).format(new Date(generatedAt));
  const sourceLabel = codexHome.source === "manual" ? "手动目录" : codexHome.exists ? "自动发现" : "等待选择";
  const latestDiagnostic = diagnostics[0] ?? null;

  async function savePath() {
    setSavingPath(true);
    try {
      await onCodexHomeChange(pathDraft);
      setEditingPath(false);
    } finally {
      setSavingPath(false);
    }
  }

  async function resetPath() {
    setSavingPath(true);
    try {
      await onCodexHomeReset();
      setEditingPath(false);
    } finally {
      setSavingPath(false);
    }
  }

  return (
    <header className="dashboard-header">
      <div className="floating-title-spacer" />
      <div className="brand-mark">CX</div>
      <div className="account-row">
        <span className="app-name">Codex Token Bar</span>
        <span className="account-name">{account.displayName}</span>
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
        <button className="toolbar-button" onClick={() => setEditingPath((value) => !value)} type="button">
          {editingPath ? "收起目录" : "更改目录"}
        </button>
        <button className="toolbar-button" onClick={onOpenProviderRepair} type="button">
          会话消失修复
        </button>
        <span className="refresh-label">{refreshing ? "同步中" : ""}</span>
      </div>
      {editingPath ? (
        <div className="codex-home-editor">
          <input
            aria-label="Codex 目录"
            disabled={savingPath}
            onChange={(event) => setPathDraft(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter") {
                void savePath();
              }
            }}
            value={pathDraft}
          />
          <button disabled={savingPath || pathDraft.trim().length === 0} onClick={savePath} type="button">
            保存目录
          </button>
          <button disabled={savingPath} onClick={resetPath} type="button">
            恢复自动
          </button>
        </div>
      ) : null}
      {latestDiagnostic ? (
        <div className="diagnostic-strip" title={latestDiagnostic.message}>
          <span className="diagnostic-strip__label">本地读取提醒</span>
          <span className="diagnostic-strip__message">
            {commandDisplayName(latestDiagnostic.command)} 失败，已显示待读取/零值数据。
          </span>
          <span className="diagnostic-strip__meta">
            {formatDiagnosticTime(latestDiagnostic.occurredAt)}
            {latestDiagnostic.count > 1 ? ` · ${latestDiagnostic.count} 次` : ""}
          </span>
        </div>
      ) : null}
    </header>
  );
}

function commandDisplayName(command: string): string {
  const knownNames: Record<string, string> = {
    get_codex_home: "Codex 目录读取",
    read_platform_capabilities: "平台能力读取",
    read_dashboard_snapshot: "首页快速统计读取",
    read_precise_dashboard_snapshot: "精确 token 扫描",
    read_account_quota: "额度读取",
    read_live_rate_snapshot: "实时速率读取",
    read_live_thread_options: "会话列表读取",
    read_floating_snapshot: "悬浮窗数据读取",
    "platform:command:show_floating_window": "悬浮窗打开",
    "platform:command:hide_floating_window": "悬浮窗关闭",
    "platform:command:show_status_panel_window": "状态栏面板打开",
    "platform:command:hide_status_panel_window": "状态栏面板关闭",
    "platform:command:show_dashboard_window": "主界面打开",
    "platform:command:set_status_tray_readout": "状态栏数字更新",
    "platform:command:start_live_rate_stream": "实时速率事件流",
    "platform:command:stop_live_rate_stream": "实时速率事件流停止",
    "platform:emit-floating-window-hidden": "悬浮窗关闭同步",
    "platform:publish-floating-settings": "悬浮窗设置同步",
    "platform:resize-floating-window": "悬浮窗尺寸调整",
    "platform:start-floating-window-drag": "悬浮窗拖动",
    "platform:restore-floating-window-position": "悬浮窗位置恢复",
    "platform:listen-floating-window-moved": "悬浮窗位置监听",
    "platform:listen:floating-window-hidden": "悬浮窗关闭监听",
    "platform:listen:floating-settings-changed": "悬浮窗设置监听",
    "platform:listen:live-rate-snapshot": "实时速率事件监听",
    "platform:read-window-label": "窗口类型识别",
  };
  if (knownNames[command]) {
    return knownNames[command];
  }
  if (command.startsWith("platform:")) {
    return command.slice("platform:".length).replaceAll("_", " ").replaceAll(":", " ");
  }
  return command.replaceAll("_", " ");
}

function formatDiagnosticTime(value: string): string {
  return new Intl.DateTimeFormat("zh-CN", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).format(new Date(value));
}
