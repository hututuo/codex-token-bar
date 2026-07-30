export interface SessionManagementCapability {
  available: boolean;
  reason?: string | null;
}

export interface SessionManagementCapabilities {
  officialArchive: SessionManagementCapability;
  officialUnarchive: SessionManagementCapability;
  officialDelete: SessionManagementCapability;
  recoveryArchive: SessionManagementCapability;
  recoveryRestore: SessionManagementCapability;
  recoveryReclaim: SessionManagementCapability;
}

export interface SessionManagementThread {
  id: string;
  title: string;
  preview: string;
  cwd: string;
  createdAt: number | null;
  updatedAt: number | null;
  recencyAt: number | null;
  archived: boolean;
  archivedAt: number | null;
  tokensUsed: number | null;
  fileBytes: number | null;
  fileModifiedAt: number | null;
  status: string;
  source: string | null;
  model: string | null;
  sessionId: string | null;
  forkedFromId: string | null;
  parentThreadId: string | null;
  isSubagent: boolean;
  spawnChildCount: number;
  forkChildCount: number;
  similarityGroupId: string | null;
  similarityReason: string | null;
  protectionReasons: string[];
  canArchive: boolean;
  canUnarchive: boolean;
  canDelete: boolean;
}

export interface SessionManagementCatalog {
  threads: SessionManagementThread[];
  generatedAt: number;
  codexHome: string;
  totalBytes: number | null;
  warnings: string[];
  capabilities: SessionManagementCapabilities;
}

export interface SessionContextMessage {
  id: string;
  role: string;
  content: string;
  timestamp: string | null;
  offset: number;
  kind: string;
}

export interface SessionContextPage {
  threadId: string;
  messages: SessionContextMessage[];
  nextBeforeOffset: number | null;
  hasMoreBefore: boolean;
  fileIdentity: string;
  warnings: string[];
}

export interface SessionMutationItemResult {
  threadId: string;
  ok: boolean;
  message?: string | null;
  recoveryArchivePath?: string | null;
}

export interface SessionMutationBatchResult {
  results: SessionMutationItemResult[];
  warnings: string[];
}

export type SessionManagementMutation =
  | "archive"
  | "unarchive"
  | "delete"
  | "recoveryArchive";

export interface SessionDeleteRolloutSnapshot {
  threadId: string;
  canonicalRelativePath: string;
  physicalIdentity: string;
  sizeBytes: string;
  modifiedNanos: string | null;
  sha256: string;
}

export interface SessionDeleteConfirmation {
  schemaVersion: number;
  preparedAt: number;
  physicalHomeKey: string;
  requestedIds: string[];
  effectiveRootIds: string[];
  affectedIds: string[];
  rollouts: SessionDeleteRolloutSnapshot[];
}
