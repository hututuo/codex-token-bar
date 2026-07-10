import type {
  ProviderRepairActionResult,
  ProviderRepairBackupInfo,
  ProviderRepairSnapshot,
} from "../types/dashboard";
import { fallbackProviderRepairSnapshot } from "./fallback";
import { callCommand, callCommandStrict } from "./command";

const PROVIDER_MUTATION_TIMEOUT_MS = 60_000;
const PROVIDER_STATUS_TIMEOUT_MS = 5_000;
const PROVIDER_STATUS_POLL_MS = 500;

export interface ProviderOperationStatus {
  operationId: string;
  active: boolean;
}

interface ProviderOperationBackendError {
  kind: "busy" | "failed";
  activeOperationId?: string;
  message: string;
}

interface ExecuteProviderRepairMutationOptions<T> {
  mutation: () => Promise<T>;
  onUncertain?: (operationId: string) => void;
  operationId: string;
  readStatus?: (operationId: string) => Promise<ProviderOperationStatus>;
  waitForNextPoll?: () => Promise<void>;
}

export function scanProviderRepair(): Promise<ProviderRepairSnapshot> {
  return callCommand("scan_provider_repair", fallbackProviderRepairSnapshot, undefined, 20_000);
}

export function listProviderBackups(): Promise<ProviderRepairBackupInfo[]> {
  return callCommand("list_provider_backups", [], undefined, 20_000);
}

export function createProviderBackup(
  onUncertain?: (operationId: string) => void,
): Promise<ProviderRepairActionResult> {
  return callProviderMutation("create_provider_backup", undefined, onUncertain);
}

export function syncProviderHistory(
  backupId: string,
  onUncertain?: (operationId: string) => void,
): Promise<ProviderRepairActionResult> {
  return callProviderMutation("sync_provider_history", { backupId }, onUncertain);
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

export function readProviderOperationStatus(operationId: string): Promise<ProviderOperationStatus> {
  return callCommandStrict<ProviderOperationStatus>(
    "read_provider_operation_status",
    { operationId },
    PROVIDER_STATUS_TIMEOUT_MS,
  );
}

export async function executeProviderRepairMutation<T>({
  mutation,
  onUncertain,
  operationId,
  readStatus = readProviderOperationStatus,
  waitForNextPoll = waitForProviderStatusPoll,
}: ExecuteProviderRepairMutationOptions<T>): Promise<T> {
  try {
    return await mutation();
  } catch (error) {
    const backendError = parseProviderOperationBackendError(error);
    const reconciliationId = isCommandTimeout(error)
      ? operationId
      : backendError?.kind === "busy"
        ? backendError.activeOperationId
        : undefined;

    if (!reconciliationId) {
      throw backendError ? new Error(backendError.message) : error;
    }

    onUncertain?.(reconciliationId);
    await waitForProviderOperationEnd(reconciliationId, readStatus, waitForNextPoll);
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

async function waitForProviderOperationEnd(
  operationId: string,
  readStatus: (operationId: string) => Promise<ProviderOperationStatus>,
  waitForNextPoll: () => Promise<void>,
) {
  for (;;) {
    try {
      const status = await readStatus(operationId);
      if (!status.active) {
        return;
      }
    } catch {
      // Status uncertainty is safety-sensitive: keep controls busy and retry.
    }
    await waitForNextPoll();
  }
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
    if ((parsed.kind === "busy" || parsed.kind === "failed") && typeof parsed.message === "string") {
      return parsed as ProviderOperationBackendError;
    }
  } catch {
    return null;
  }
  return null;
}

function waitForProviderStatusPoll() {
  return new Promise<void>((resolve) => {
    window.setTimeout(resolve, PROVIDER_STATUS_POLL_MS);
  });
}
