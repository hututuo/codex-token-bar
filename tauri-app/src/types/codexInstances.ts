export interface CodexControlledProcess {
  pid: number;
  executablePath: string;
  userDataMarker: string;
  startedAt: number;
  processStartIdentity: string;
}

export interface CodexInstance {
  id: string;
  name: string;
  codexHome: string;
  electronDataDirectory: string;
  workingDirectory: string | null;
  arguments: string[];
  managed: boolean;
  isDefault: boolean;
  autoSyncEnabled: boolean;
  createdAt: number;
  updatedAt: number;
  controlledProcess: CodexControlledProcess | null;
}

export interface CodexInstanceConflict {
  id: string;
  threadId: string;
  instanceIds: string[];
  relativePaths: string[];
  hashes: string[];
  detectedAt: number;
  reason: string;
  resolved: boolean;
}

export interface CodexInstanceRegistrySnapshot {
  schemaVersion: number;
  updatedAt: number;
  instances: CodexInstance[];
  conflicts: CodexInstanceConflict[];
  registryPath: string;
}

export type CodexInstanceCreateMode = "empty" | "copyConfiguration";

export interface CodexInstanceCreateRequest {
  name: string;
  mode: CodexInstanceCreateMode;
  sourceHome: string | null;
  copyAuth: boolean;
  workingDirectory: string | null;
  arguments: string[];
  autoSyncEnabled: boolean;
}

export interface CodexInstanceImportRequest {
  name: string;
  codexHome: string;
  workingDirectory: string | null;
  arguments: string[];
  autoSyncEnabled: boolean;
}

export interface CodexInstanceUpdateRequest {
  id: string;
  name: string;
  workingDirectory: string | null;
  arguments: string[];
  autoSyncEnabled: boolean;
}

export interface CodexInstanceActionResult {
  instance: CodexInstance | null;
  message: string;
}

export interface CodexInstanceRuntimeStatus {
  id: string;
  running: boolean;
  controlled: boolean;
  pid: number | null;
  message: string;
}

export interface CodexInstanceSyncOperation {
  threadId: string;
  sourceInstanceId: string;
  destinationInstanceId: string;
  sourcePath: string;
  destinationPath: string;
  kind: "missing" | "fastForward";
  sourceHash: string;
  destinationHash: string | null;
  backupPath: string | null;
  installedHash: string | null;
}

export interface CodexInstanceSyncPreview {
  instanceIds: string[];
  operations: CodexInstanceSyncOperation[];
  conflicts: CodexInstanceConflict[];
  unchangedThreads: number;
}

export interface CodexInstanceSyncResult {
  transactionId: string | null;
  operationsApplied: number;
  conflicts: CodexInstanceConflict[];
  message: string;
}

export interface CodexInstanceSyncTransactionSummary {
  transactionId: string;
  createdAt: number;
  state: string;
  instanceIds: string[];
  operations: number;
  conflicts: number;
}
