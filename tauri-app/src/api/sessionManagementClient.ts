import { callCommandStrict } from "./command";
import type { CodexHomeSourceToken } from "../types/dashboard";
import type {
  SessionContextPage,
  SessionDeleteConfirmation,
  SessionManagementCatalog,
  SessionMutationBatchResult,
} from "../types/sessionManagement";

export function listSessionManagementCatalog(
  sourceToken: CodexHomeSourceToken,
): Promise<SessionManagementCatalog> {
  return callCommandStrict<SessionManagementCatalog>(
    "list_session_management_catalog",
    { sourceToken },
    null,
  );
}

export function readSessionContextPage(
  sourceToken: CodexHomeSourceToken,
  threadId: string,
  beforeOffset: number | null = null,
  pageSize = 40,
): Promise<SessionContextPage> {
  return callCommandStrict<SessionContextPage>(
    "read_session_context_page",
    { sourceToken, threadId, beforeOffset, pageSize },
    null,
  );
}

export function archiveSessionThreads(
  sourceToken: CodexHomeSourceToken,
  threadIds: string[],
): Promise<SessionMutationBatchResult> {
  return callCommandStrict<SessionMutationBatchResult>(
    "archive_session_threads",
    { sourceToken, threadIds },
    null,
  );
}

export function unarchiveSessionThreads(
  sourceToken: CodexHomeSourceToken,
  threadIds: string[],
): Promise<SessionMutationBatchResult> {
  return callCommandStrict<SessionMutationBatchResult>(
    "unarchive_session_threads",
    { sourceToken, threadIds },
    null,
  );
}

export function prepareSessionDeleteConfirmation(
  sourceToken: CodexHomeSourceToken,
  threadIds: string[],
): Promise<SessionDeleteConfirmation> {
  return callCommandStrict<SessionDeleteConfirmation>(
    "prepare_session_delete_confirmation",
    { sourceToken, threadIds },
    null,
  );
}

export function deleteSessionThreads(
  sourceToken: CodexHomeSourceToken,
  threadIds: string[],
  confirmation: SessionDeleteConfirmation,
): Promise<SessionMutationBatchResult> {
  return callCommandStrict<SessionMutationBatchResult>(
    "delete_session_threads",
    {
      sourceToken,
      threadIds,
      createRecoveryArchive: true,
      confirmation,
    },
    null,
  );
}

export function createSessionRecoveryArchives(
  sourceToken: CodexHomeSourceToken,
  threadIds: string[],
): Promise<SessionMutationBatchResult> {
  return callCommandStrict<SessionMutationBatchResult>(
    "create_session_recovery_archives",
    { sourceToken, threadIds },
    null,
  );
}
