import type {
  SessionContextMessage,
  SessionManagementMutation,
  SessionManagementThread,
} from "../types/sessionManagement";

export const SESSION_DISCLOSURE_PAGE_SIZE = 100;
export const DEFAULT_LARGE_SESSION_BYTES = 100 * 1024 * 1024;

export type SessionCollectionId =
  | "all"
  | "recent"
  | "archived"
  | "large"
  | "forks"
  | "similar"
  | "subagents"
  | `project:${string}`;

export type SessionSortId = "recent" | "size" | "leastRecent" | "tokens";
export type SessionNavigationStage = "projects" | "sessions" | "detail";
export type SessionNavigationAction = "chooseCollection" | "chooseThread" | "back";

export interface SessionCollection {
  id: SessionCollectionId;
  label: string;
  count: number;
  description: string;
}

export interface SessionProject {
  id: SessionCollectionId;
  cwd: string;
  label: string;
  count: number;
}

export interface SessionFilterOptions {
  collection: SessionCollectionId;
  query: string;
  sort: SessionSortId;
  minimumSizeBytes?: number;
  idleDays?: number | null;
  now?: Date;
}

export interface SessionActionEligibility {
  eligible: SessionManagementThread[];
  blocked: SessionManagementThread[];
  reason: string | null;
}

export interface SessionDeletionImpact {
  requested: SessionManagementThread[];
  effectiveRoots: SessionManagementThread[];
  affected: SessionManagementThread[];
  indirectDescendants: SessionManagementThread[];
  externalForkReferences: SessionManagementThread[];
  totalBytes: number | null;
  blockedAffected: SessionManagementThread[];
}

export function buildSessionCollections(
  threads: readonly SessionManagementThread[],
  now = new Date(),
): SessionCollection[] {
  const sevenDaysAgo = now.getTime() - 7 * 86_400_000;
  return [
    collection("all", "全部会话", threads.filter((thread) => !thread.isSubagent).length, "主会话，不混入 Subagent"),
    collection("recent", "最近使用", threads.filter((thread) => (
      !thread.isSubagent && timestamp(thread.recencyAt ?? thread.updatedAt) >= sevenDaysAgo
    )).length, "最近 7 天"),
    collection("archived", "官方归档", threads.filter((thread) => thread.archived).length, "Codex 官方归档"),
    collection("large", "大容量", threads.filter((thread) => (
      (thread.fileBytes ?? 0) >= DEFAULT_LARGE_SESSION_BYTES
    )).length, "按真实文件大小"),
    collection("forks", "Fork 分支", threads.filter((thread) => (
      !thread.isSubagent && (thread.forkedFromId !== null || thread.forkChildCount > 0)
    )).length, "用户 Fork 谱系"),
    collection("similar", "可能相似", threads.filter((thread) => (
      !thread.isSubagent && thread.similarityGroupId !== null
    )).length, "本地指纹候选"),
    collection("subagents", "Subagent", threads.filter((thread) => thread.isSubagent).length, "与 Fork 分开展示"),
  ];
}

export function buildSessionProjects(
  threads: readonly SessionManagementThread[],
): SessionProject[] {
  const counts = new Map<string, number>();
  for (const thread of threads) {
    if (thread.isSubagent) continue;
    const cwd = normalizedCwd(thread.cwd);
    counts.set(cwd, (counts.get(cwd) ?? 0) + 1);
  }
  return [...counts.entries()]
    .map(([cwd, count]) => ({
      id: `project:${encodeURIComponent(cwd)}` as SessionCollectionId,
      cwd,
      label: projectLabel(cwd),
      count,
    }))
    .sort((left, right) => (
      right.count - left.count || left.label.localeCompare(right.label, "zh-CN")
    ));
}

export function filterSessionThreads(
  threads: readonly SessionManagementThread[],
  options: SessionFilterOptions,
): SessionManagementThread[] {
  const now = options.now ?? new Date();
  const normalizedQuery = options.query.trim().toLocaleLowerCase();
  const minimumSizeBytes = options.minimumSizeBytes ?? DEFAULT_LARGE_SESSION_BYTES;
  const idleBefore = options.idleDays === null || options.idleDays === undefined
    ? null
    : now.getTime() - options.idleDays * 86_400_000;
  const projectCwd = options.collection.startsWith("project:")
    ? decodeURIComponent(options.collection.slice("project:".length))
    : null;

  return threads
    .filter((thread) => {
      if (projectCwd !== null) {
        return !thread.isSubagent && normalizedCwd(thread.cwd) === projectCwd;
      }
      switch (options.collection) {
      case "all":
        return !thread.isSubagent;
      case "recent":
        return !thread.isSubagent
          && timestamp(thread.recencyAt ?? thread.updatedAt) >= now.getTime() - 7 * 86_400_000;
      case "archived":
        return thread.archived;
      case "large":
        return (thread.fileBytes ?? 0) >= minimumSizeBytes;
      case "forks":
        return !thread.isSubagent && (thread.forkedFromId !== null || thread.forkChildCount > 0);
      case "similar":
        return !thread.isSubagent && thread.similarityGroupId !== null;
      case "subagents":
        return thread.isSubagent;
      default:
        return false;
      }
    })
    .filter((thread) => (
      idleBefore === null
      || (
        (thread.recencyAt ?? thread.updatedAt ?? thread.createdAt) !== null
        && timestamp(thread.recencyAt ?? thread.updatedAt ?? thread.createdAt) <= idleBefore
      )
    ))
    .filter((thread) => (
      normalizedQuery.length === 0
      || searchableThreadText(thread).includes(normalizedQuery)
    ))
    .sort(sorter(options.sort));
}

export function eligibilityForMutation(
  threads: readonly SessionManagementThread[],
  mutation: SessionManagementMutation,
): SessionActionEligibility {
  const eligible: SessionManagementThread[] = [];
  const blocked: SessionManagementThread[] = [];
  for (const thread of threads) {
    const safe = isUnloadedSessionStatus(thread.status)
      && thread.protectionReasons.length === 0;
    const allowed = mutation === "archive"
      ? thread.canArchive && !thread.archived
      : mutation === "unarchive"
        ? thread.canUnarchive && thread.archived
        : mutation === "delete"
          ? thread.canDelete
          : thread.canDelete;
    (safe && allowed ? eligible : blocked).push(thread);
  }
  const unsafeCount = blocked.filter((thread) => (
    !isUnloadedSessionStatus(thread.status) || thread.protectionReasons.length > 0
  )).length;
  const notApplicableCount = blocked.length - unsafeCount;
  const blockedReasons = [
    unsafeCount > 0 ? `${unsafeCount} 个仍在运行、加载或受保护` : null,
    notApplicableCount > 0 ? `${notApplicableCount} 个不适用于此操作` : null,
  ].filter((reason): reason is string => reason !== null);
  const reason = blocked.length === 0
    ? null
    : `已保留全部选择；${mutationLabel(mutation)}暂不可执行：${blockedReasons.join("，")}。`;
  return { eligible, blocked, reason };
}

export function nextSessionNavigationStage(
  current: SessionNavigationStage,
  action: SessionNavigationAction,
): SessionNavigationStage {
  if (action === "chooseCollection") return "sessions";
  if (action === "chooseThread") return "detail";
  if (current === "detail") return "sessions";
  if (current === "sessions") return "projects";
  return "projects";
}

export function sessionDeletionImpact(
  threads: readonly SessionManagementThread[],
  selected: readonly SessionManagementThread[],
): SessionDeletionImpact {
  const byId = new Map(threads.map((thread) => [thread.id, thread]));
  const requested = [...new Map(selected.map((thread) => [thread.id, thread])).values()]
    .filter((thread) => byId.has(thread.id));
  const children = new Map<string, string[]>();
  for (const thread of threads) {
    if (thread.parentThreadId === null || !byId.has(thread.parentThreadId)) continue;
    const ids = children.get(thread.parentThreadId) ?? [];
    ids.push(thread.id);
    children.set(thread.parentThreadId, ids);
  }
  for (const ids of children.values()) ids.sort((left, right) => left.localeCompare(right));
  const closure = (rootId: string) => {
    const ids = new Set<string>();
    const pending = [rootId];
    while (pending.length > 0) {
      const current = pending.pop();
      if (current === undefined || ids.has(current)) continue;
      ids.add(current);
      const descendants = children.get(current) ?? [];
      for (let index = descendants.length - 1; index >= 0; index -= 1) {
        pending.push(descendants[index]);
      }
    }
    return ids;
  };

  const effectiveRootIds: string[] = [];
  const closureByRoot = new Map<string, Set<string>>();
  for (const thread of requested) {
    if (effectiveRootIds.some((rootId) => closureByRoot.get(rootId)?.has(thread.id))) {
      continue;
    }
    const selectedClosure = closure(thread.id);
    for (const rootId of [...effectiveRootIds]) {
      if (!selectedClosure.has(rootId)) continue;
      effectiveRootIds.splice(effectiveRootIds.indexOf(rootId), 1);
      closureByRoot.delete(rootId);
    }
    effectiveRootIds.push(thread.id);
    closureByRoot.set(thread.id, selectedClosure);
  }
  const affectedIds = new Set<string>();
  const affected: SessionManagementThread[] = [];
  for (const rootId of effectiveRootIds) {
    const ids = [...(closureByRoot.get(rootId) ?? [])].sort((left, right) => {
      if (left === rootId) return -1;
      if (right === rootId) return 1;
      return left.localeCompare(right);
    });
    for (const id of ids) {
      const thread = byId.get(id);
      if (thread === undefined || affectedIds.has(id)) continue;
      affectedIds.add(id);
      affected.push(thread);
    }
  }
  const requestedIds = new Set(requested.map((thread) => thread.id));
  const externalForkReferences = threads.filter((thread) => (
    !affectedIds.has(thread.id)
    && thread.forkedFromId !== null
    && affectedIds.has(thread.forkedFromId)
  ));
  const totalBytes = affected.every((thread) => thread.fileBytes !== null)
    ? affected.reduce((sum, thread) => sum + (thread.fileBytes ?? 0), 0)
    : null;
  return {
    requested,
    effectiveRoots: effectiveRootIds
      .map((id) => byId.get(id))
      .filter((thread): thread is SessionManagementThread => thread !== undefined),
    affected,
    indirectDescendants: affected.filter((thread) => !requestedIds.has(thread.id)),
    externalForkReferences,
    totalBytes,
    blockedAffected: affected.filter((thread) => (
      !isUnloadedSessionStatus(thread.status)
      || thread.protectionReasons.length > 0
      || !thread.canDelete
    )),
  };
}

export function mergeContextMessages(
  current: readonly SessionContextMessage[],
  incoming: readonly SessionContextMessage[],
): SessionContextMessage[] {
  const byIdentity = new Map<string, SessionContextMessage>();
  for (const message of [...current, ...incoming]) {
    byIdentity.set(`${message.offset}:${message.id}`, message);
  }
  return [...byIdentity.values()].sort((left, right) => (
    left.offset - right.offset || left.id.localeCompare(right.id)
  ));
}

export function relatedThreads(
  selected: SessionManagementThread,
  threads: readonly SessionManagementThread[],
): {
  forkParent: SessionManagementThread | null;
  forkChildren: SessionManagementThread[];
  subagentParent: SessionManagementThread | null;
  subagents: SessionManagementThread[];
  similar: SessionManagementThread[];
} {
  return {
    forkParent: selected.forkedFromId
      ? threads.find((thread) => thread.id === selected.forkedFromId) ?? null
      : null,
    forkChildren: threads.filter((thread) => thread.forkedFromId === selected.id),
    subagentParent: selected.parentThreadId
      ? threads.find((thread) => thread.id === selected.parentThreadId) ?? null
      : null,
    subagents: threads.filter((thread) => thread.parentThreadId === selected.id),
    similar: selected.similarityGroupId
      ? threads.filter((thread) => (
        thread.id !== selected.id && thread.similarityGroupId === selected.similarityGroupId
      ))
      : [],
  };
}

export function formatSessionBytes(bytes: number | null): string {
  if (bytes === null || !Number.isFinite(bytes) || bytes < 0) return "—";
  if (bytes < 1024) return `${Math.round(bytes)} B`;
  const units = ["KiB", "MiB", "GiB", "TiB"];
  let value = bytes / 1024;
  let unit = units[0];
  for (let index = 1; index < units.length && value >= 1024; index += 1) {
    value /= 1024;
    unit = units[index];
  }
  return `${value >= 100 ? value.toFixed(0) : value >= 10 ? value.toFixed(1) : value.toFixed(2)} ${unit}`;
}

export function formatSessionTimestamp(value: number | string | null): string {
  if (value === null) return "未知";
  const date = typeof value === "number"
    ? new Date(value < 1_000_000_000_000 ? value * 1_000 : value)
    : new Date(value);
  if (Number.isNaN(date.getTime())) return "未知";
  return new Intl.DateTimeFormat("zh-CN", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  }).format(date);
}

export function projectLabel(cwd: string): string {
  if (!cwd || cwd === "/") return cwd || "未知项目";
  const segments = cwd.replace(/[\\/]+$/, "").split(/[\\/]/).filter(Boolean);
  return segments.at(-1) ?? cwd;
}

function collection(
  id: Exclude<SessionCollectionId, `project:${string}`>,
  label: string,
  count: number,
  description: string,
): SessionCollection {
  return { id, label, count, description };
}

function mutationLabel(mutation: SessionManagementMutation): string {
  switch (mutation) {
  case "archive":
    return "官方归档";
  case "unarchive":
    return "恢复到 Codex";
  case "delete":
    return "永久删除";
  case "recoveryArchive":
    return "创建恢复包";
  }
}

function normalizedCwd(cwd: string): string {
  const normalized = cwd.trim().replace(/[\\/]+$/, "");
  return normalized || "/";
}

function searchableThreadText(thread: SessionManagementThread): string {
  return [
    thread.title,
    thread.preview,
    thread.cwd,
    thread.id,
    thread.model ?? "",
    thread.source ?? "",
    thread.similarityReason ?? "",
  ].join("\n").toLocaleLowerCase();
}

function timestamp(value: number | null): number {
  if (value === null || !Number.isFinite(value)) return 0;
  return value < 1_000_000_000_000 ? value * 1_000 : value;
}

function sorter(sort: SessionSortId) {
  return (left: SessionManagementThread, right: SessionManagementThread): number => {
    if (sort === "size") {
      return (right.fileBytes ?? -1) - (left.fileBytes ?? -1)
        || timestamp(right.recencyAt ?? right.updatedAt) - timestamp(left.recencyAt ?? left.updatedAt);
    }
    if (sort === "leastRecent") {
      return timestamp(left.recencyAt ?? left.updatedAt) - timestamp(right.recencyAt ?? right.updatedAt)
        || (right.fileBytes ?? -1) - (left.fileBytes ?? -1);
    }
    if (sort === "tokens") {
      return (right.tokensUsed ?? -1) - (left.tokensUsed ?? -1)
        || timestamp(right.recencyAt ?? right.updatedAt) - timestamp(left.recencyAt ?? left.updatedAt);
    }
    return timestamp(right.recencyAt ?? right.updatedAt) - timestamp(left.recencyAt ?? left.updatedAt)
      || (right.fileBytes ?? -1) - (left.fileBytes ?? -1);
  };
}

function isUnloadedSessionStatus(status: string): boolean {
  const normalized = status.trim().toLocaleLowerCase().replace(/[^a-z]/g, "");
  return normalized === "notloaded";
}
