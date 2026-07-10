import { useEffect, useRef, useState } from "react";
import {
  createProviderBackup,
  listProviderBackups,
  readProviderOperationStatus,
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
import { createProviderRepairAutoScanController } from "./providerRepair/autoScanController";
import {
  createProviderRepairOperationController,
  type ProviderRepairOperationKind,
} from "./providerRepair/operationController";
import {
  providerRepairSafetyLatch,
  reconcileProviderRepairOperation,
} from "./providerRepair/providerOperationCoordinator";
import { ProviderRepairSteps } from "./providerRepair/ProviderRepairSteps";

interface ProviderRepairCardProps {
  autoScanOnMount?: boolean;
  id?: string;
  onBusyChange?: (busy: boolean) => void;
  onSnapshotChange: (snapshot: ProviderRepairSnapshot) => void;
  snapshot: ProviderRepairSnapshot;
}

export function ProviderRepairCard({
  autoScanOnMount = false,
  id,
  onBusyChange,
  onSnapshotChange,
  snapshot,
}: ProviderRepairCardProps) {
  const [backups, setBackups] = useState<ProviderRepairBackupInfo[]>([]);
  const [activeBackupId, setActiveBackupId] = useState<string | null>(null);
  const [message, setMessage] = useState(snapshot.status);
  const [busyAction, setBusyAction] = useState<string | null>(null);
  const [outstandingOperationId, setOutstandingOperationId] = useState(
    providerRepairSafetyLatch.getSnapshot,
  );
  const autoScanControllerRef = useRef(createProviderRepairAutoScanController());
  const operationControllerRef = useRef(createProviderRepairOperationController());
  const busy = busyAction !== null || outstandingOperationId !== null;

  useEffect(() => {
    setMessage(snapshot.status);
  }, [snapshot.status]);

  useEffect(() => {
    onBusyChange?.(busy);
  }, [busy, onBusyChange]);

  useEffect(() => providerRepairSafetyLatch.subscribe(setOutstandingOperationId), []);

  useEffect(() => {
    if (outstandingOperationId === null) {
      return;
    }

    const controller = new AbortController();
    void reconcileProviderRepairOperation({
      operationId: outstandingOperationId,
      readStatus: readProviderOperationStatus,
      signal: controller.signal,
    }).then((outcome) => {
      if (controller.signal.aborted) {
        return;
      }
      if (outcome === "finished") {
        if (providerRepairSafetyLatch.clearFinished(outstandingOperationId)) {
          setMessage("后端已确认 Provider 写操作结束，可以继续操作。");
        }
      } else if (outcome === "statusUnavailable") {
        setMessage("暂时无法确认 Provider 写操作状态；安全锁保持启用，重新打开面板后会再次核对。");
      }
    });

    return () => {
      controller.abort();
    };
  }, [outstandingOperationId]);

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

  useEffect(() => {
    if (outstandingOperationId !== null) {
      return;
    }
    if (!autoScanControllerRef.current.shouldStart(autoScanOnMount)) {
      return;
    }
    void runScan();
  }, [autoScanOnMount, outstandingOperationId]);

  async function runScan() {
    await run("scan", scanProviderRepair, (next) => {
      onSnapshotChange(next);
      setMessage(next.status);
    });
  }

  async function runBackup() {
    await run("backup", () => createProviderBackup(markOperationUncertain), applyResult);
  }

  async function runSync() {
    const backupId = activeBackupId ?? backups[0]?.id;
    if (!backupId) {
      setMessage("请先创建备份，再进行修复。");
      return;
    }
    await run("sync", () => syncProviderHistory(backupId, markOperationUncertain), applyResult);
  }

  async function runVerify() {
    await run("verify", verifyProviderRepair, applyResult);
  }

  async function runRollback(backupId: string) {
    await run("rollback", () => rollbackProviderBackup(backupId, markOperationUncertain), applyResult);
  }

  function markOperationUncertain() {
    setMessage("操作响应超时，正在等待后端确认写操作已结束。期间修复操作保持禁用。");
  }

  async function run<T>(
    action: ProviderRepairOperationKind,
    operation: () => Promise<T>,
    publishResult: (result: T) => void,
  ) {
    if (providerRepairSafetyLatch.getSnapshot() !== null) {
      setMessage("Provider 写操作状态尚未确认，修复操作保持禁用。");
      return;
    }
    const started = operationControllerRef.current.start(action);
    if (!started.started) {
      setMessage(started.message);
      return;
    }

    setBusyAction(action);
    let accepted = false;
    try {
      const result = await operation();
      accepted = operationControllerRef.current.finish(started.operation);
      if (accepted) {
        publishResult(result);
      }
    } catch (error) {
      accepted = operationControllerRef.current.finish(started.operation);
      if (accepted && providerRepairSafetyLatch.getSnapshot() === null) {
        setMessage(error instanceof Error ? error.message : String(error));
      }
    } finally {
      if (accepted) {
        setBusyAction(null);
      }
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
        <button className="toolbar-button" disabled={busy} onClick={runScan} type="button">
          重新扫描
        </button>
      </div>
      <p className={snapshot.inconsistentCount > 0 ? "repair-status repair-status--warn" : "repair-status"}>
        {message}
      </p>

      <ProviderRepairSteps steps={snapshot.steps} />

      <ProviderRepairActions
        activeBackupId={activeBackupId}
        busy={busy}
        onBackup={runBackup}
        onScan={runScan}
        onSync={runSync}
        onVerify={runVerify}
      />

      <ProviderRepairBackups
        activeBackupId={activeBackupId}
        backups={backups}
        busy={busy}
        onRollback={runRollback}
        onSelectBackup={setActiveBackupId}
      />
    </section>
  );
}
