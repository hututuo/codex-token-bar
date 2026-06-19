import { useEffect, useState } from "react";
import {
  createProviderBackup,
  listProviderBackups,
  rollbackProviderBackup,
  scanProviderRepair,
  syncProviderHistory,
  verifyProviderRepair,
} from "../api/client";
import type {
  ProviderRepairActionResult,
  ProviderRepairBackupInfo,
  ProviderRepairSnapshot,
} from "../types/dashboard";
import { ProviderRepairActions } from "./providerRepair/ProviderRepairActions";
import { ProviderRepairBackups } from "./providerRepair/ProviderRepairBackups";
import { ProviderRepairSteps } from "./providerRepair/ProviderRepairSteps";

interface ProviderRepairCardProps {
  id?: string;
  onSnapshotChange: (snapshot: ProviderRepairSnapshot) => void;
  snapshot: ProviderRepairSnapshot;
}

export function ProviderRepairCard({ id, onSnapshotChange, snapshot }: ProviderRepairCardProps) {
  const [backups, setBackups] = useState<ProviderRepairBackupInfo[]>([]);
  const [activeBackupId, setActiveBackupId] = useState<string | null>(null);
  const [message, setMessage] = useState(snapshot.status);
  const [busyAction, setBusyAction] = useState<string | null>(null);

  useEffect(() => {
    setMessage(snapshot.status);
  }, [snapshot.status]);

  useEffect(() => {
    let cancelled = false;
    void listProviderBackups().then((items) => {
      if (!cancelled) {
        setBackups(items);
        setActiveBackupId((current) => current ?? items[0]?.id ?? null);
      }
    });
    return () => {
      cancelled = true;
    };
  }, []);

  async function runScan() {
    await run("scan", async () => {
      const next = await scanProviderRepair();
      onSnapshotChange(next);
      setMessage(next.status);
      return null;
    });
  }

  async function runBackup() {
    await run("backup", async () => applyResult(await createProviderBackup()));
  }

  async function runSync() {
    const backupId = activeBackupId ?? backups[0]?.id;
    if (!backupId) {
      setMessage("请先创建备份，再进行修复。");
      return;
    }
    await run("sync", async () => applyResult(await syncProviderHistory(backupId)));
  }

  async function runVerify() {
    await run("verify", async () => applyResult(await verifyProviderRepair()));
  }

  async function runRollback(backupId: string) {
    await run(`rollback-${backupId}`, async () => applyResult(await rollbackProviderBackup(backupId)));
  }

  async function run(action: string, operation: () => Promise<null | void>) {
    setBusyAction(action);
    try {
      await operation();
    } catch (error) {
      setMessage(error instanceof Error ? error.message : String(error));
    } finally {
      setBusyAction(null);
    }
  }

  function applyResult(result: ProviderRepairActionResult) {
    onSnapshotChange(result.snapshot);
    setMessage(result.message);
    setBackups(result.backups);
    setActiveBackupId(result.backup?.id ?? result.backups[0]?.id ?? activeBackupId);
  }

  return (
    <section className="repair-card" id={id} aria-label="会话消失修复">
      <div className="section-title-row">
        <div>
          <h2>会话消失修复</h2>
          <span>
            provider {snapshot.detectedProvider} · {snapshot.providerSource} · {snapshot.sessionFilesFound} 个会话文件
          </span>
        </div>
        <button className="toolbar-button" disabled={busyAction !== null} onClick={runScan} type="button">
          重新扫描
        </button>
      </div>
      <p className={snapshot.inconsistentCount > 0 ? "repair-status repair-status--warn" : "repair-status"}>
        {message}
      </p>

      <ProviderRepairSteps steps={snapshot.steps} />

      <ProviderRepairActions
        activeBackupId={activeBackupId}
        busy={busyAction !== null}
        onBackup={runBackup}
        onScan={runScan}
        onSync={runSync}
        onVerify={runVerify}
      />

      <ProviderRepairBackups
        activeBackupId={activeBackupId}
        backups={backups}
        busy={busyAction !== null}
        onRollback={runRollback}
        onSelectBackup={setActiveBackupId}
      />
    </section>
  );
}
