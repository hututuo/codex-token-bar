import type { ProviderRepairBackupInfo } from "../../types/dashboard";

interface ProviderRepairBackupsProps {
  activeBackupId: string | null;
  backups: ProviderRepairBackupInfo[];
  busy: boolean;
  onRollback: (backupId: string) => void;
  onSelectBackup: (backupId: string) => void;
}

export function ProviderRepairBackups({
  activeBackupId,
  backups,
  busy,
  onRollback,
  onSelectBackup,
}: ProviderRepairBackupsProps) {
  return (
    <div className="repair-backups">
      <div className="repair-backups-head">
        <strong>回滚备份</strong>
        <span>{backups.length === 0 ? "暂无备份" : `${backups.length} 个备份`}</span>
      </div>
      <div className="repair-backup-list">
        {backups.length === 0 ? (
          <p>创建备份后，会在这里显示可回滚的时间点。</p>
        ) : (
          backups.map((backup, index) => {
            const legacyUnsupported = backup.restoreStatus !== "supported";
            return (
              <article
                className={activeBackupId === backup.id ? "repair-backup repair-backup--active" : "repair-backup"}
                key={backup.id}
              >
                <button
                  disabled={legacyUnsupported}
                  onClick={() => onSelectBackup(backup.id)}
                  type="button"
                >
                  <strong>#{backups.length - index}</strong>
                  <span>{backup.createdAt}</span>
                  <em>{legacyUnsupported ? "旧版备份，仅供查看" : backup.targetProvider}</em>
                </button>
                <small>
                  JSONL {backup.sessionFiles} · SQLite {backup.stateDatabase ? "已备份" : "无"} · 索引{" "}
                  {backup.sessionIndex ? "已备份" : "无"}
                </small>
                <small title={backup.codexHome}>目录 {compactCodexHome(backup.codexHome)}</small>
                {legacyUnsupported ? (
                  <>
                    <small className="repair-backup-path" title={backup.path}>备份路径 {backup.path}</small>
                    <small>{backup.restoreUnsupportedReason}</small>
                    <small>请创建新的 v2 恢复点后再回滚。</small>
                  </>
                ) : null}
                <button
                  className="repair-rollback-button"
                  disabled={busy || legacyUnsupported}
                  onClick={() => onRollback(backup.id)}
                  type="button"
                >
                  {legacyUnsupported ? "不支持回滚" : "回滚"}
                </button>
              </article>
            );
          })
        )}
      </div>
    </div>
  );
}

function compactCodexHome(path: string) {
  if (!path || path === "unknown") {
    return "未知";
  }
  const parts = path.split(/[\\/]+/).filter(Boolean);
  if (parts.length <= 2) {
    return path;
  }
  return `.../${parts.slice(-2).join("/")}`;
}
