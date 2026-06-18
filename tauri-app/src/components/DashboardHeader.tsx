import type { AccountInfo, CodexHomeStatus } from "../types/dashboard";

interface DashboardHeaderProps {
  account: AccountInfo;
  codexHome: CodexHomeStatus;
  generatedAt: string;
  refreshing: boolean;
}

export function DashboardHeader({
  account,
  codexHome,
  generatedAt,
  refreshing,
}: DashboardHeaderProps) {
  const timeLabel = new Intl.DateTimeFormat("zh-CN", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).format(new Date(generatedAt));

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
        <span>{codexHome.exists ? "自动发现" : "等待选择"}</span>
        <span className="path-pill">{codexHome.path}</span>
        <span className="muted">Updated {timeLabel}</span>
        <button className="toolbar-button" type="button">
          立即刷新
        </button>
        <button className="toolbar-button" type="button">
          更改目录
        </button>
        <span className="refresh-label">{refreshing ? "同步中" : ""}</span>
      </div>
    </header>
  );
}
