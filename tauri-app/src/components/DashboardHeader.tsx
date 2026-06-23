import type { AccountInfo, AutostartStatus, CodexHomeStatus } from "../types/dashboard";
import { CodexHomeEditor } from "./dashboardHeader/CodexHomeEditor";
import { useState } from "react";

interface DashboardHeaderProps {
  account: AccountInfo;
  autostartStatus: AutostartStatus;
  codexHome: CodexHomeStatus;
  generatedAt: string;
  onCodexHomeChange: (path: string) => Promise<void>;
  onCodexHomeReset: () => Promise<void>;
  onRefresh: () => Promise<void>;
  onToggleAutostart: () => void;
  refreshing: boolean;
}

export function DashboardHeader({
  account,
  autostartStatus,
  codexHome,
  generatedAt,
  onCodexHomeChange,
  onCodexHomeReset,
  onRefresh,
  onToggleAutostart,
  refreshing,
}: DashboardHeaderProps) {
  const [editingPath, setEditingPath] = useState(false);

  const timeLabel = new Intl.DateTimeFormat("zh-CN", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).format(new Date(generatedAt));
  const sourceLabel = codexHome.source === "manual" ? "手动目录" : codexHome.exists ? "自动发现" : "等待选择";

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
