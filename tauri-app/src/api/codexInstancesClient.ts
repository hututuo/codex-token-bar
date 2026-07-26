import { callCommandStrict } from "./command";
import type {
  CodexInstanceActionResult,
  CodexInstanceCreateRequest,
  CodexInstanceImportRequest,
  CodexInstanceRegistrySnapshot,
  CodexInstanceRuntimeStatus,
  CodexInstanceSyncPreview,
  CodexInstanceSyncResult,
  CodexInstanceSyncTransactionSummary,
  CodexInstanceUpdateRequest,
} from "../types/codexInstances";

const INSTANCE_COMMAND_TIMEOUT_MS = 30_000;
const INSTANCE_SYNC_TIMEOUT_MS = 30 * 60_000;

export function listCodexInstances(): Promise<CodexInstanceRegistrySnapshot> {
  return callCommandStrict("list_codex_instances", undefined, INSTANCE_COMMAND_TIMEOUT_MS);
}

export function createCodexInstance(
  request: CodexInstanceCreateRequest,
): Promise<CodexInstanceActionResult> {
  return callCommandStrict("create_codex_instance", { request }, INSTANCE_COMMAND_TIMEOUT_MS);
}

export function importCodexInstance(
  request: CodexInstanceImportRequest,
): Promise<CodexInstanceActionResult> {
  return callCommandStrict("import_codex_instance", { request }, INSTANCE_COMMAND_TIMEOUT_MS);
}

export function updateCodexInstance(
  request: CodexInstanceUpdateRequest,
): Promise<CodexInstanceActionResult> {
  return callCommandStrict("update_codex_instance", { request }, INSTANCE_COMMAND_TIMEOUT_MS);
}

export function deleteCodexInstance(id: string): Promise<CodexInstanceActionResult> {
  return callCommandStrict("delete_codex_instance", { id }, INSTANCE_COMMAND_TIMEOUT_MS);
}

export function readCodexInstanceRuntimeStatus(id: string): Promise<CodexInstanceRuntimeStatus> {
  return callCommandStrict(
    "read_codex_instance_runtime_status",
    { id },
    INSTANCE_COMMAND_TIMEOUT_MS,
  );
}

export function listCodexInstanceRuntimeStatuses(): Promise<CodexInstanceRuntimeStatus[]> {
  return callCommandStrict(
    "list_codex_instance_runtime_statuses",
    undefined,
    INSTANCE_COMMAND_TIMEOUT_MS,
  );
}

export function launchCodexInstance(id: string): Promise<CodexInstanceActionResult> {
  return callCommandStrict("launch_codex_instance", { id }, INSTANCE_COMMAND_TIMEOUT_MS);
}

export function focusCodexInstance(id: string): Promise<CodexInstanceActionResult> {
  return callCommandStrict("focus_codex_instance", { id }, INSTANCE_COMMAND_TIMEOUT_MS);
}

export function stopCodexInstance(id: string): Promise<CodexInstanceActionResult> {
  return callCommandStrict("stop_codex_instance", { id }, INSTANCE_COMMAND_TIMEOUT_MS);
}

export function previewCodexInstanceSync(
  instanceIds: string[],
): Promise<CodexInstanceSyncPreview> {
  return callCommandStrict(
    "preview_codex_instance_sync",
    { instanceIds },
    INSTANCE_SYNC_TIMEOUT_MS,
  );
}

export function syncCodexInstances(instanceIds: string[]): Promise<CodexInstanceSyncResult> {
  return callCommandStrict(
    "sync_codex_instances",
    { instanceIds },
    INSTANCE_SYNC_TIMEOUT_MS,
  );
}

export function listCodexInstanceSyncTransactions(): Promise<CodexInstanceSyncTransactionSummary[]> {
  return callCommandStrict(
    "list_codex_instance_sync_transactions",
    undefined,
    INSTANCE_COMMAND_TIMEOUT_MS,
  );
}

export function rollbackCodexInstanceSync(
  transactionId: string,
): Promise<CodexInstanceSyncResult> {
  return callCommandStrict(
    "rollback_codex_instance_sync",
    { transactionId },
    INSTANCE_SYNC_TIMEOUT_MS,
  );
}
