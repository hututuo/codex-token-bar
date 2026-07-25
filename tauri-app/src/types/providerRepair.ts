export interface ProviderRepairStep {
  label: string;
  status: string;
  done: boolean;
  healthy: boolean;
}

export interface ProviderRepairSnapshot {
  detectedProvider: string;
  providerSource: string;
  sqliteHome: string;
  sessionFilesFound: number;
  inconsistentCount: number;
  migrationCandidateCount: number;
  invalidSessionFiles: number;
  ambiguousThreadCount: number;
  status: string;
  steps: ProviderRepairStep[];
}

export interface ProviderRepairBackupInfo {
  id: string;
  createdAt: string;
  path: string;
  codexHome: string;
  codexHomeFingerprint: string;
  sqliteHome: string;
  sqliteHomeFingerprint: string;
  targetProvider: string;
  sessionFiles: number;
  stateDatabase: boolean;
  sessionIndex: boolean;
  restoreStatus: "supported" | "legacyUnsupported";
  restoreUnsupportedReason: string | null;
}

export interface ProviderRepairActionResult {
  snapshot: ProviderRepairSnapshot;
  message: string;
  backup: ProviderRepairBackupInfo | null;
  backups: ProviderRepairBackupInfo[];
}
