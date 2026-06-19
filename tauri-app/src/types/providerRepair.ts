export interface ProviderRepairStep {
  label: string;
  status: string;
  done: boolean;
  healthy: boolean;
}

export interface ProviderRepairSnapshot {
  detectedProvider: string;
  providerSource: string;
  sessionFilesFound: number;
  inconsistentCount: number;
  status: string;
  steps: ProviderRepairStep[];
}

export interface ProviderRepairBackupInfo {
  id: string;
  createdAt: string;
  path: string;
  codexHome: string;
  codexHomeFingerprint: string;
  targetProvider: string;
  sessionFiles: number;
  stateDatabase: boolean;
  sessionIndex: boolean;
}

export interface ProviderRepairActionResult {
  snapshot: ProviderRepairSnapshot;
  message: string;
  backup: ProviderRepairBackupInfo | null;
  backups: ProviderRepairBackupInfo[];
}
