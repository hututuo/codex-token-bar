import type {
  ProviderRepairActionResult,
  ProviderRepairBackupInfo,
  ProviderRepairSnapshot,
} from "../types/dashboard";
import { fallbackProviderRepairSnapshot } from "./fallback";
import { callCommand, callCommandStrict } from "./command";

export function scanProviderRepair(): Promise<ProviderRepairSnapshot> {
  return callCommand("scan_provider_repair", fallbackProviderRepairSnapshot, undefined, 20_000);
}

export function listProviderBackups(): Promise<ProviderRepairBackupInfo[]> {
  return callCommand("list_provider_backups", [], undefined, 20_000);
}

export function createProviderBackup(): Promise<ProviderRepairActionResult> {
  return callCommandStrict<ProviderRepairActionResult>("create_provider_backup", undefined, 60_000);
}

export function syncProviderHistory(backupId: string): Promise<ProviderRepairActionResult> {
  return callCommandStrict<ProviderRepairActionResult>("sync_provider_history", { backupId }, 60_000);
}

export function verifyProviderRepair(): Promise<ProviderRepairActionResult> {
  return callCommandStrict<ProviderRepairActionResult>("verify_provider_repair", undefined, 30_000);
}

export function rollbackProviderBackup(backupId: string): Promise<ProviderRepairActionResult> {
  return callCommandStrict<ProviderRepairActionResult>("rollback_provider_backup", { backupId }, 60_000);
}
