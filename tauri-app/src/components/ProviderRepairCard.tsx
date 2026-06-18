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

      <div className="repair-steps">
        {snapshot.steps.map((step, index) => (
          <div className={step.done ? "repair-step repair-step--done" : "repair-step"} key={step.label}>
            <strong>{index + 1}</strong>
            <span>{step.label}</span>
            <em>{step.status}</em>
          </div>
        ))}
      </div>

      <div className="repair-actions">
        <button disabled={busyAction !== null} onClick={runScan} type="button">
          1 扫描
        </button>
        <button disabled={busyAction !== null} onClick={runBackup} type="button">
          2 创建备份
        </button>
        <button disabled={busyAction !== null || !activeBackupId} onClick={runSync} type="button">
          3 同步修复
        </button>
        <button disabled={busyAction !== null} onClick={runVerify} type="button">
          4 验证
        </button>
      </div>

      <div className="repair-backups">
        <div className="repair-backups-head">
          <strong>回滚备份</strong>
          <span>{backups.length === 0 ? "暂无备份" : `${backups.length} 个备份`}</span>
        </div>
        <div className="repair-backup-list">
          {backups.length === 0 ? (
            <p>创建备份后，会在这里显示可回滚的时间点。</p>
          ) : (
            backups.map((backup, index) => (
              <article
                className={
                  activeBackupId === backup.id ? "repair-backup repair-backup--active" : "repair-backup"
                }
                key={backup.id}
              >
                <button onClick={() => setActiveBackupId(backup.id)} type="button">
                  <strong>#{backups.length - index}</strong>
                  <span>{backup.createdAt}</span>
                  <em>{backup.targetProvider}</em>
                </button>
                <small>
                  JSONL {backup.sessionFiles} · SQLite {backup.stateDatabase ? "已备份" : "无"} · 索引{" "}
                  {backup.sessionIndex ? "已备份" : "无"}
                </small>
                <button
                  className="repair-rollback-button"
                  disabled={busyAction !== null}
                  onClick={() => runRollback(backup.id)}
                  type="button"
                >
                  回滚
                </button>
              </article>
            ))
          )}
        </div>
      </div>
    </section>
  );
}
