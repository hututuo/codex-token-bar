interface ProviderRepairActionsProps {
  activeBackupId: string | null;
  busy: boolean;
  onBackup: () => void;
  onScan: () => void;
  onSync: () => void;
  onVerify: () => void;
}

export function ProviderRepairActions({
  activeBackupId,
  busy,
  onBackup,
  onScan,
  onSync,
  onVerify,
}: ProviderRepairActionsProps) {
  return (
    <div className="repair-actions">
      <button disabled={busy} onClick={onScan} type="button">
        1 扫描
      </button>
      <button disabled={busy} onClick={onBackup} type="button">
        2 创建备份
      </button>
      <button disabled={busy || !activeBackupId} onClick={onSync} type="button">
        3 同步修复
      </button>
      <button disabled={busy} onClick={onVerify} type="button">
        4 验证
      </button>
    </div>
  );
}
