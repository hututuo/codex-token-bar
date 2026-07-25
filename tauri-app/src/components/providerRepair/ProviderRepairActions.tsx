import { buildProviderRepairActionModel } from "./actionModel";

interface ProviderRepairActionsProps {
  busy: boolean;
  migrationCandidateCount: number;
  onBackup: () => void;
  onMigrate: () => void;
  onScan: () => void;
  onSync: () => void;
  onVerify: () => void;
}

export function ProviderRepairActions({
  busy,
  migrationCandidateCount,
  onBackup,
  onMigrate,
  onScan,
  onSync,
  onVerify,
}: ProviderRepairActionsProps) {
  const actions = buildProviderRepairActionModel({ busy, migrationCandidateCount });

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
          disabled={actions.migrate.disabled}
          onClick={onMigrate}
          title={actions.migrate.reason ?? undefined}
          type="button"
        >
          {actions.migrate.label}
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
    </>
  );
}
