import type {
  ConversationVisibilityRebuildResult,
  ProviderRepairActionResult,
  ProviderRepairBackupInfo,
  ProviderRepairSnapshot,
} from "../types/dashboard";
import { fallbackProviderRepairSnapshot } from "./fallback";
import { callCommand, callCommandStrict } from "./command";
import {
  providerRepairSafetyLatch,
  type ProviderOperationOwnershipDiscovery,
  type ProviderOperationStatus,
  type ProviderRepairSafetyLatch,
} from "../services/providerRepairOperationCoordinator";

const PROVIDER_MUTATION_TIMEOUT_MS = 60_000;
const PROVIDER_STATUS_TIMEOUT_MS = 5_000;

export type {
  ProviderOperationOwnershipDiscovery,
  ProviderOperationStatus,
} from "../services/providerRepairOperationCoordinator";

interface ProviderOperationBackendError {
  kind: "busy" | "failed";
  activeOperationId?: string;
  message: string;
}

interface ExecuteProviderRepairMutationOptions<T> {
  mutation: () => Promise<T>;
  onUncertain?: (operationId: string) => void;
  operationId: string;
  safetyLatch?: ProviderRepairSafetyLatch;
}

export function scanProviderRepair(): Promise<ProviderRepairSnapshot> {
  return callCommand("scan_provider_repair", fallbackProviderRepairSnapshot, undefined, 20_000);
}

export function listProviderBackups(): Promise<ProviderRepairBackupInfo[]> {
  return callCommand("list_provider_backups", [], undefined, 20_000);
}

export function isProviderBackupRollbackSupported(
  backup: Pick<ProviderRepairBackupInfo, "restoreStatus">,
) {
  return backup.restoreStatus === "supported";
}

export function createProviderBackup(
  onUncertain?: (operationId: string) => void,
): Promise<ProviderRepairActionResult> {
  return callProviderMutation("create_provider_backup", undefined, onUncertain);
}

export function syncProviderHistory(
  onUncertain?: (operationId: string) => void,
): Promise<ProviderRepairActionResult> {
  return callProviderMutation("sync_provider_history", undefined, onUncertain);
}

export function migrateProviderHistory(
  targetProvider: string,
  onUncertain?: (operationId: string) => void,
): Promise<ProviderRepairActionResult> {
  return callProviderMutation(
    "migrate_provider_history",
    { targetProvider },
    onUncertain,
  );
}

export function verifyProviderRepair(): Promise<ProviderRepairActionResult> {
  return callCommandStrict<ProviderRepairActionResult>("verify_provider_repair", undefined, 30_000);
}

export function rollbackProviderBackup(
  backupId: string,
  onUncertain?: (operationId: string) => void,
): Promise<ProviderRepairActionResult> {
  return callProviderMutation("rollback_provider_backup", { backupId }, onUncertain);
}

export function rebuildConversationVisibility(
  onUncertain?: (operationId: string) => void,
): Promise<ConversationVisibilityRebuildResult> {
  const operationId = createProviderOperationId();
  return executeProviderRepairMutation({
    operationId,
    onUncertain,
    mutation: () => callCommandStrict<ConversationVisibilityRebuildResult>(
      "rebuild_conversation_visibility",
      { operationId },
      30 * 60_000,
    ),
  });
}

export function readProviderOperationStatus(operationId: string): Promise<ProviderOperationStatus> {
  return callCommandStrict<ProviderOperationStatus>(
    "read_provider_operation_status",
    { operationId },
    PROVIDER_STATUS_TIMEOUT_MS,
  );
}

export function discoverProviderOperationOwnership(): Promise<ProviderOperationOwnershipDiscovery> {
  return callCommandStrict<ProviderOperationOwnershipDiscovery>(
    "discover_provider_operation_ownership",
    undefined,
    PROVIDER_STATUS_TIMEOUT_MS,
  );
}

export async function executeProviderRepairMutation<T>({
  mutation,
  onUncertain,
  operationId,
  safetyLatch = providerRepairSafetyLatch,
}: ExecuteProviderRepairMutationOptions<T>): Promise<T> {
  safetyLatch.markInvokePending(operationId);
  try {
    const result = await mutation();
    safetyLatch.clearFinished(operationId);
    return result;
  } catch (error) {
    const backendError = parseProviderOperationBackendError(error);
    const reconciliationId = isCommandTimeout(error)
      ? operationId
      : backendError?.kind === "busy"
        ? backendError.activeOperationId
        : undefined;

    if (!reconciliationId) {
      safetyLatch.clearFinished(operationId);
      throw backendError ? new Error(backendError.message) : error;
    }

    safetyLatch.markUncertain(reconciliationId);
    onUncertain?.(reconciliationId);
    throw backendError ? new Error(backendError.message) : error;
  }
}

async function callProviderMutation(
  command: string,
  args: Record<string, unknown> | undefined,
  onUncertain: ((operationId: string) => void) | undefined,
) {
  const operationId = createProviderOperationId();
  return executeProviderRepairMutation({
    operationId,
    onUncertain,
    mutation: () => callCommandStrict<ProviderRepairActionResult>(
      command,
      { ...args, operationId },
      PROVIDER_MUTATION_TIMEOUT_MS,
    ),
  });
}

function createProviderOperationId() {
  if (typeof globalThis.crypto?.randomUUID === "function") {
    return globalThis.crypto.randomUUID();
  }
  return `provider-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function isCommandTimeout(error: unknown) {
  return error instanceof Error && /timed out|timeout/i.test(error.message);
}

function parseProviderOperationBackendError(error: unknown): ProviderOperationBackendError | null {
  if (!(error instanceof Error)) {
    return null;
  }
  try {
    const parsed = JSON.parse(error.message) as Partial<ProviderOperationBackendError>;
    if (parsed.kind === "busy"
      && typeof parsed.activeOperationId === "string"
      && typeof parsed.message === "string") {
      return parsed as ProviderOperationBackendError;
    }
    if (parsed.kind === "failed" && typeof parsed.message === "string") {
      return parsed as ProviderOperationBackendError;
    }
  } catch {
    return null;
  }
  return null;
}
