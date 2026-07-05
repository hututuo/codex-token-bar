import { buildProviderRepairActionModel } from "./actionModel";

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
  const actions = buildProviderRepairActionModel({ activeBackupId, busy });
  const missingBackupNote = !busy && !activeBackupId ? actions.sync.reason : null;

  return (
    <>
      <div className="repair-actions">
        <button
          disabled={actions.scan.disabled}
          onClick={onScan}
          title={actions.scan.reason ?? undefined}
          type="button"
        >
          {actions.scan.label}
        </button>
        <button
          disabled={actions.backup.disabled}
          onClick={onBackup}
          title={actions.backup.reason ?? undefined}
          type="button"
        >
          {actions.backup.label}
        </button>
        <button
          disabled={actions.sync.disabled}
          onClick={onSync}
          title={actions.sync.reason ?? undefined}
          type="button"
        >
          {actions.sync.label}
        </button>
        <button
          disabled={actions.verify.disabled}
          onClick={onVerify}
          title={actions.verify.reason ?? undefined}
          type="button"
        >
          {actions.verify.label}
        </button>
      </div>
      {missingBackupNote ? (
        <p className="repair-action-note" role="status">
          {missingBackupNote}
        </p>
      ) : null}
    </>
  );
}
