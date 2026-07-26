import { useEffect, useRef, useState } from "react";
import {
  createProviderBackup,
  discoverProviderOperationOwnership,
  listProviderBackups,
  migrateProviderHistory,
  readProviderOperationStatus,
  rebuildConversationVisibility,
  rollbackProviderBackup,
  scanProviderRepair,
  syncProviderHistory,
  verifyProviderRepair,
} from "../api/client";
import type {
  ConversationVisibilityRebuildResult,
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
  bootstrapProviderRepairSafetyLatch,
  deriveProviderRepairInteractionState,
  providerRepairSafetyLatch,
  reconcileProviderRepairOperation,
} from "../services/providerRepairOperationCoordinator";
import { ProviderRepairSteps } from "./providerRepair/ProviderRepairSteps";

interface ProviderRepairCardProps {
  autoScanOnMount?: boolean;
  id?: string;
  onCloseBlockedChange?: (blocked: boolean) => void;
  onSnapshotChange: (snapshot: ProviderRepairSnapshot) => void;
  snapshot: ProviderRepairSnapshot;
}

export function ProviderRepairCard({
  autoScanOnMount = false,
  id,
  onCloseBlockedChange,
  onSnapshotChange,
  snapshot,
}: ProviderRepairCardProps) {
  const [backups, setBackups] = useState<ProviderRepairBackupInfo[]>([]);
  const [activeBackupId, setActiveBackupId] = useState<string | null>(null);
  const [message, setMessage] = useState(snapshot.status);
  const [visibilityResult, setVisibilityResult] =
    useState<ConversationVisibilityRebuildResult | null>(null);
  const [busyAction, setBusyAction] = useState<string | null>(null);
  const [safetySnapshot, setSafetySnapshot] = useState(
    providerRepairSafetyLatch.getSnapshot,
  );
  const autoScanControllerRef = useRef(createProviderRepairAutoScanController());
  const operationControllerRef = useRef(createProviderRepairOperationController());
  const interactionState = deriveProviderRepairInteractionState(
    busyAction !== null,
    safetySnapshot.phase,
  );
  const busy = interactionState.controlsDisabled;
  const closeBlocked = interactionState.closeBlocked;

  useEffect(() => {
    setMessage(snapshot.status);
  }, [snapshot.status]);

  useEffect(() => {
    onCloseBlockedChange?.(closeBlocked);
  }, [closeBlocked, onCloseBlockedChange]);

  useEffect(() => providerRepairSafetyLatch.subscribe(setSafetySnapshot), []);

  useEffect(() => {
    if (providerRepairSafetyLatch.getSnapshot().phase === "statusUnavailable") {
      providerRepairSafetyLatch.beginBootstrap();
    }
  }, []);

  useEffect(() => {
    if (safetySnapshot.phase !== "bootstrapping") {
      return;
    }

    let cancelled = false;
    void bootstrapProviderRepairSafetyLatch({
      discoverOwnership: discoverProviderOperationOwnership,
      safetyLatch: providerRepairSafetyLatch,
    }).then((outcome) => {
      if (cancelled) {
        return;
      }
      if (outcome === "ownersDiscovered") {
        setMessage("检测到后端仍有 Provider 写操作，正在核对完成状态。");
      } else if (outcome === "statusUnavailable") {
        setMessage("暂时无法读取 Provider 后端状态；修复操作保持禁用，可关闭后重新打开面板核对。");
      }
    });

    return () => {
      cancelled = true;
    };
  }, [safetySnapshot.generation, safetySnapshot.phase]);

  useEffect(() => {
    if (safetySnapshot.phase !== "uncertain" || safetySnapshot.operationIds.length === 0) {
      return;
    }

    const controller = new AbortController();
    const reconciliationGeneration = safetySnapshot.generation;
    const operationIds = safetySnapshot.operationIds;
    void Promise.all(operationIds.map((operationId) => reconcileProviderRepairOperation({
      operationId,
      readStatus: readProviderOperationStatus,
      signal: controller.signal,
    }))).then((outcomes) => {
      if (controller.signal.aborted) {
        return;
      }
      if (outcomes.some((outcome) => outcome === "statusUnavailable")) {
        if (providerRepairSafetyLatch.markStatusUnavailable(reconciliationGeneration)) {
          setMessage("暂时无法确认 Provider 写操作状态；安全锁保持启用，可关闭后重新打开面板核对。");
        }
        return;
      }
      if (outcomes.every((outcome) => outcome === "finished")) {
        for (const operationId of operationIds) {
          providerRepairSafetyLatch.clearFinished(operationId);
        }
        setMessage("后端已确认 Provider 写操作结束，可以继续操作。");
      }
    });

    return () => {
      controller.abort();
    };
  }, [safetySnapshot.generation, safetySnapshot.operationIds, safetySnapshot.phase]);

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
    if (safetySnapshot.phase !== "ready") {
      return;
    }
    if (!autoScanControllerRef.current.shouldStart(autoScanOnMount)) {
      return;
    }
    void runScan();
  }, [autoScanOnMount, safetySnapshot.phase]);

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
    await run("sync", () => syncProviderHistory(markOperationUncertain), applyResult);
  }

  async function runMigration() {
    const confirmed = window.confirm(
      `将 ${snapshot.migrationCandidateCount} 个历史会话的 Provider 元数据迁移为 ${snapshot.detectedProvider}。\n\n只改会话首行和 SQLite Provider 字段，不改模型、消息、时间戳或会话名称；操作前会创建差量恢复点。\n\n重要：如果旧会话含 encrypted_content，跨 Provider 或跨账号后可能无法解密。恢复点可以撤销本次元数据迁移，但不能让另一账号解密原内容。请只在账号与 Provider 确认兼容时继续。`,
    );
    if (!confirmed) {
      return;
    }
    await run(
      "sync",
      () => migrateProviderHistory(snapshot.detectedProvider, markOperationUncertain),
      applyResult,
    );
  }

  async function runVerify() {
    await run("verify", verifyProviderRepair, applyResult);
  }

  async function runVisibilityRebuild() {
    await run(
      "sync",
      () => rebuildConversationVisibility(markOperationUncertain),
      (result) => {
        setVisibilityResult(result);
        setMessage(result.status);
      },
    );
  }

  async function runRollback(backupId: string) {
    const backup = backups.find((entry) => entry.id === backupId);
    if (!window.confirm(rollbackConfirmationMessage(backup))) {
      return;
    }
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
    if (providerRepairSafetyLatch.getSnapshot().phase !== "ready") {
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
      if (accepted && providerRepairSafetyLatch.getSnapshot().phase === "ready") {
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
          <span title={snapshot.sqliteHome}>SQLite {compactStoragePath(snapshot.sqliteHome)}</span>
        </div>
        <button className="toolbar-button" disabled={busy} onClick={runScan} type="button">
          重新扫描
        </button>
      </div>
      <p className={snapshot.inconsistentCount > 0 ? "repair-status repair-status--warn" : "repair-status"}>
        {message}
      </p>

      <ProviderRepairSteps steps={snapshot.steps} />

      <p className="repair-action-note">
        安全修复只校准 SQLite 元数据，不改历史文件；“迁移历史”才会显式改写候选会话的首行 Provider。
      </p>

      <div className="repair-visibility">
        <div>
          <strong>官方会话索引重建</strong>
          <p>
            完整扫描活动与归档会话，由 Codex app-server 重建官方列表元数据；Token Bar 不改写 JSONL、session_index 或私有索引。
          </p>
          {visibilityResult ? (
            <span>
              活动 {visibilityResult.activeThreads} · 归档 {visibilityResult.archivedThreads} · {visibilityResult.pagesScanned} 页
            </span>
          ) : null}
        </div>
        <button
          disabled={busy}
          onClick={runVisibilityRebuild}
          title={busy ? "正在执行修复操作，请等待当前步骤完成。" : "Codex Desktop 必须先退出；后端会在执行前再次确认。"}
          type="button"
        >
          官方重建
        </button>
      </div>

      <ProviderRepairActions
        busy={busy}
        migrationCandidateCount={snapshot.migrationCandidateCount}
        onBackup={runBackup}
        onMigrate={runMigration}
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

function compactStoragePath(path: string) {
  const parts = path.split(/[\\/]+/).filter(Boolean);
  return parts.length <= 2 ? path : `.../${parts.slice(-2).join("/")}`;
}

export function rollbackConfirmationMessage(backup: ProviderRepairBackupInfo | undefined): string {
  const createdAt = backup?.createdAt.trim() ?? "";
  const question = createdAt === ""
    ? "回滚到所选备份的差量恢复点吗？"
    : `回滚到 ${createdAt} 创建的差量恢复点吗？`;
  return `${question}\n\n只会恢复恢复点覆盖的会话首行与 SQLite 一致性快照，此后的修复改动会被撤销。`;
}
