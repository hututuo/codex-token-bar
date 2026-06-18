import { useEffect, useState } from "react";
import type { AccountInfo, CodexHomeStatus } from "../types/dashboard";

interface DashboardHeaderProps {
  account: AccountInfo;
  codexHome: CodexHomeStatus;
  generatedAt: string;
  onCodexHomeChange: (path: string) => Promise<void>;
  onCodexHomeReset: () => Promise<void>;
  onRefresh: () => Promise<void>;
  refreshing: boolean;
}

export function DashboardHeader({
  account,
  codexHome,
  generatedAt,
  onCodexHomeChange,
  onCodexHomeReset,
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
    </header>
  );
}
